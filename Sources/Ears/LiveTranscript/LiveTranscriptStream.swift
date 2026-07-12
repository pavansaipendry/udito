import Foundation

/// WebSocket to the Live Transcript relay's /app endpoint — carries the
/// remote guest's transcript events down to this Mac.
///
/// Hardened like DeepgramStream: automatic reconnect with backoff, JSON
/// ping/pong, and on reconnect `since=<last seq>` makes the relay replay any
/// finalized results this side missed, so a dropped connection delays words
/// instead of losing them.
final class LiveTranscriptStream: NSObject {
    enum Event {
        case status(state: String, guest: String?, guestConnected: Bool)
        case guest(joined: Bool, name: String?)
        case result(DeepgramStream.Result)
        case level(Float)
        case warning(String)
        case ended(reason: String?)
    }

    private let baseURL: URL
    private let code: String
    private let token: String
    private let queue = DispatchQueue(label: "ears.livetranscript.app")
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var active = false
    private var open = false
    private var paused = false
    private var backoff: TimeInterval = 0.5
    private var openedAt: Date?
    private var lastSeq = 0
    private var failuresSinceOpen = 0

    /// Called on an internal queue — hop to main before touching UI state.
    var onEvent: ((Event) -> Void)?
    var onStateChange: ((Bool) -> Void)?

    private static let maxFailuresBeforeGivingUp = 12

    init(baseURL: URL, code: String, token: String) {
        self.baseURL = baseURL
        self.code = code
        self.token = token
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

    func stop() {
        queue.async {
            self.active = false
            self.task?.cancel(with: .normalClosure, reason: nil)
            self.task = nil
            self.setOpen(false)
            self.session.finishTasksAndInvalidate()
        }
    }

    /// Tell the relay to end the session for everyone (guest included).
    func sendEnd() {
        queue.async {
            self.task?.send(.string(#"{"type":"end"}"#)) { _ in }
        }
    }

    /// Mac is going to sleep: stop reconnect attempts so sleep doesn't burn
    /// through the give-up counter and kill an otherwise healthy session.
    func pause() {
        queue.async {
            guard self.active, !self.paused else { return }
            self.paused = true
            self.task?.cancel(with: .goingAway, reason: nil)
            self.task = nil
            self.setOpen(false)
            EarsLog.info("[live] paused for sleep")
        }
    }

    /// Mac woke up: reconnect fresh; missed finals replay via ?since=.
    func resume() {
        queue.async {
            guard self.active, self.paused else { return }
            self.paused = false
            self.failuresSinceOpen = 0
            self.backoff = 0.5
            EarsLog.info("[live] resuming after wake")
            self.connect()
        }
    }

    // MARK: - Connection

    private var socketURL: URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.path = "/app"
        components.queryItems = [
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "since", value: String(lastSeq)),
        ]
        return components.url!
    }

    private func connect() {
        guard active, !paused, task == nil else { return }
        let task = session.webSocketTask(with: socketURL)
        self.task = task
        task.resume()
        receiveLoop(task)
    }

    private func disconnected(_ error: Error) {
        guard task != nil || open else { return }
        let wasOpen = open
        setOpen(false)
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        guard active, !paused else { return }

        failuresSinceOpen += 1
        if failuresSinceOpen >= Self.maxFailuresBeforeGivingUp {
            EarsLog.error("[live] relay unreachable after \(failuresSinceOpen) attempts — giving up")
            active = false
            onEvent?(.ended(reason: "lost"))
            return
        }
        if wasOpen, let openedAt, Date().timeIntervalSince(openedAt) > 30 {
            backoff = 0.5
        }
        let delay = backoff
        backoff = min(backoff * 2, 8)
        EarsLog.error("[live] relay disconnected (\(error.localizedDescription)) — retrying in \(String(format: "%.1f", delay))s")
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.connect()
        }
    }

    private func setOpen(_ value: Bool) {
        guard open != value else { return }
        open = value
        onStateChange?(value)
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
              let message = try? JSONDecoder().decode(Message.self, from: data) else { return }
        switch message.type {
        case "ping":
            task?.send(.string(#"{"type":"pong"}"#)) { _ in }
        case "status":
            onEvent?(.status(
                state: message.state ?? "waiting",
                guest: message.guest,
                guestConnected: message.guestConnected ?? false
            ))
        case "guest":
            onEvent?(.guest(joined: message.event == "joined", name: message.name))
        case "result":
            if let seq = message.seq { lastSeq = max(lastSeq, seq) }
            onEvent?(.result(DeepgramStream.Result(
                text: message.text ?? "",
                isFinal: message.isFinal ?? false,
                speechFinal: message.speechFinal ?? false
            )))
        case "level":
            onEvent?(.level(message.value ?? 0))
        case "warning":
            onEvent?(.warning(message.message ?? "The relay reported a problem."))
        case "ended":
            active = false
            onEvent?(.ended(reason: message.reason))
        default:
            break
        }
    }

    private struct Message: Decodable {
        let type: String
        let state: String?
        let guest: String?
        let guestConnected: Bool?
        let event: String?
        let name: String?
        let seq: Int?
        let text: String?
        let isFinal: Bool?
        let speechFinal: Bool?
        let value: Float?
        let message: String?
        let reason: String?
    }
}

// MARK: - URLSessionWebSocketDelegate

extension LiveTranscriptStream: URLSessionWebSocketDelegate {
    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        queue.async {
            guard webSocketTask === self.task else { return }
            self.openedAt = Date()
            self.backoff = 0.5
            self.failuresSinceOpen = 0
            self.setOpen(true)
            EarsLog.info("[live] relay connected")
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
