import Foundation

/// One live transcription stream to Deepgram (nova-3, linear16 @ 16 kHz mono).
///
/// Built to survive hours-long meetings:
/// - KeepAlive frames every 5 s so silence never idles out the socket.
/// - Automatic reconnect with backoff; audio captured while the socket is
///   down is ring-buffered (~2 min) and flushed on reconnect.
/// - CloseStream on stop so trailing final results still arrive.
final class DeepgramStream: NSObject {
    struct Result {
        let text: String
        let isFinal: Bool
        let speechFinal: Bool
        let participant: Int?

        init(text: String, isFinal: Bool, speechFinal: Bool, participant: Int? = nil) {
            self.text = text
            self.isFinal = isFinal
            self.speechFinal = speechFinal
            self.participant = participant
        }
    }

    private let apiKey: String
    private let label: String
    private let diarize: Bool
    private let queue: DispatchQueue
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var active = false
    private var open = false
    private var backoff: TimeInterval = 0.5
    private var openedAt: Date?
    private var pending = Data()
    private var keepAlive: DispatchSourceTimer?

    private static let pendingCap = 4 << 20  // ~2 min of 16 kHz mono s16
    private static let flushChunk = 32_768

    /// Called on an internal queue — hop to main before touching UI state.
    var onResult: ((Result) -> Void)?
    var onStateChange: ((Bool) -> Void)?

    init(apiKey: String, label: String, diarize: Bool = false) {
        self.apiKey = apiKey
        self.label = label
        self.diarize = diarize
        self.queue = DispatchQueue(label: "ears.deepgram.\(label)")
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func start() {
        queue.async {
            self.active = true
            self.connect()
        }
    }

    func send(_ data: Data) {
        queue.async {
            guard self.active else { return }
            if self.open, let task = self.task {
                task.send(.data(data)) { [weak self] error in
                    guard error != nil, let self else { return }
                    self.queue.async { self.stash(data) }
                }
            } else {
                self.stash(data)
            }
        }
    }

    func stop() {
        queue.async {
            self.active = false
            self.stopKeepAlive()
            guard let task = self.task else {
                self.session.finishTasksAndInvalidate()
                return
            }
            task.send(.string(#"{"type":"CloseStream"}"#)) { _ in }
            // Leave the socket up briefly so trailing finals still arrive.
            self.queue.asyncAfter(deadline: .now() + 2) {
                task.cancel(with: .normalClosure, reason: nil)
                self.task = nil
                self.setOpen(false)
                self.session.finishTasksAndInvalidate()
            }
        }
    }

    // MARK: - Connection

    private func connect() {
        guard active, task == nil else { return }
        var components = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        var queryItems = [
            URLQueryItem(name: "model", value: "nova-3"),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "endpointing", value: "300"),
        ]
        if diarize {
            queryItems.append(URLQueryItem(name: "diarize", value: "true"))
        }
        components.queryItems = queryItems
        var request = URLRequest(url: components.url!)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")

        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
        receiveLoop(task)
        EarsLog.info("[\(label)] Deepgram connecting…")
    }

    private func disconnected(_ error: Error) {
        guard task != nil || open else { return }
        let wasOpen = open
        setOpen(false)
        stopKeepAlive()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        guard active else { return }

        // A connection that held for 30 s counts as stable — reset backoff.
        if wasOpen, let openedAt, Date().timeIntervalSince(openedAt) > 30 {
            backoff = 0.5
        }
        let delay = backoff
        backoff = min(backoff * 2, 8)
        EarsLog.error("[\(label)] Deepgram disconnected (\(error.localizedDescription)) — retrying in \(String(format: "%.1f", delay))s")
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.connect()
        }
    }

    private func setOpen(_ value: Bool) {
        guard open != value else { return }
        open = value
        onStateChange?(value)
    }

    // MARK: - Buffering

    private func stash(_ data: Data) {
        pending.append(data)
        if pending.count > Self.pendingCap {
            pending.removeFirst(pending.count - Self.pendingCap)
        }
    }

    private func flushPending() {
        guard !pending.isEmpty, let task else { return }
        var offset = 0
        while offset < pending.count {
            let end = min(offset + Self.flushChunk, pending.count)
            task.send(.data(pending.subdata(in: offset..<end))) { _ in }
            offset = end
        }
        EarsLog.info("[\(label)] flushed \(pending.count) buffered bytes after reconnect")
        pending.removeAll()
    }

    private func startKeepAlive() {
        stopKeepAlive()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            self?.task?.send(.string(#"{"type":"KeepAlive"}"#)) { _ in }
        }
        timer.resume()
        keepAlive = timer
    }

    private func stopKeepAlive() {
        keepAlive?.cancel()
        keepAlive = nil
    }

    // MARK: - Receiving

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard self.task === task else { return }
                switch result {
                case .success(let message):
                    if case .string(let text) = message {
                        self.handle(text)
                    }
                    self.receiveLoop(task)
                case .failure(let error):
                    self.disconnected(error)
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let response = try? JSONDecoder().decode(DGResponse.self, from: data),
              response.type == "Results",
              let alternative = response.channel?.alternatives?.first else { return }
        let transcript = alternative.transcript ?? ""
        let speechFinal = response.speech_final ?? false
        guard !transcript.isEmpty || speechFinal else { return }

        // Majority speaker across the fragment's words (diarization).
        var participant: Int?
        if let words = alternative.words {
            let counts = words.compactMap(\.speaker).reduce(into: [Int: Int]()) {
                $0[$1, default: 0] += 1
            }
            participant = counts.max { $0.value < $1.value }?.key
        }

        onResult?(Result(
            text: transcript,
            isFinal: response.is_final ?? false,
            speechFinal: speechFinal,
            participant: participant
        ))
    }

    private struct DGResponse: Decodable {
        let type: String?
        let is_final: Bool?
        let speech_final: Bool?
        let channel: Channel?

        struct Channel: Decodable { let alternatives: [Alternative]? }
        struct Alternative: Decodable {
            let transcript: String?
            let words: [Word]?
        }
        struct Word: Decodable { let speaker: Int? }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension DeepgramStream: URLSessionWebSocketDelegate {
    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        queue.async {
            guard webSocketTask === self.task else { return }
            self.openedAt = Date()
            self.setOpen(true)
            self.flushPending()
            self.startKeepAlive()
            EarsLog.info("[\(self.label)] Deepgram connected")
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        queue.async {
            guard webSocketTask === self.task else { return }
            self.disconnected(EarsError("socket closed (code \(closeCode.rawValue))"))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        queue.async {
            guard task === self.task else { return }
            self.disconnected(error ?? EarsError("connection ended"))
        }
    }
}
