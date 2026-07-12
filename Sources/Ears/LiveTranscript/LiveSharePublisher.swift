import Foundation

/// Publishes the meeting transcript to the relay so anyone with the view
/// link watches it live in a browser.
///
/// Protocol is deliberately self-healing: every message is a full upsert of
/// one entry keyed by its UUID, and on every (re)connect the complete
/// snapshot is re-sent — duplicates are harmless overwrites, so no state can
/// desynchronize no matter what drops.
final class LiveSharePublisher: NSObject {
    private let baseURL: URL
    private let token: String
    private let publishKey: String
    private let queue = DispatchQueue(label: "ears.liveshare")
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var active = false
    private var open = false
    private var backoff: TimeInterval = 0.5

    /// Called on an internal queue — hop to main before touching UI state.
    var onViewers: ((Int) -> Void)?
    var onStateChange: ((Bool) -> Void)?
    /// Supplies the full entry list for snapshot-on-connect.
    var snapshotProvider: (() -> [TranscriptEntry])?

    init(baseURL: URL, token: String, publishKey: String) {
        self.baseURL = baseURL
        self.token = token
        self.publishKey = publishKey
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
            self.task?.send(.string(#"{"type":"end"}"#)) { _ in }
            let task = self.task
            self.queue.asyncAfter(deadline: .now() + 1) {
                task?.cancel(with: .normalClosure, reason: nil)
                self.session.finishTasksAndInvalidate()
            }
            self.task = nil
            self.setOpen(false)
        }
    }

    func publish(_ entry: TranscriptEntry) {
        send(["type": "upsert", "entry": Self.payload(entry)])
    }

    func publishClear() {
        send(["type": "clear"])
    }

    // MARK: - Wire format

    private static func payload(_ entry: TranscriptEntry) -> [String: Any] {
        [
            "id": entry.id.uuidString,
            "label": entry.label,
            "text": entry.text,
            "isFinal": entry.isFinal,
            "ts": entry.startedAt.timeIntervalSince1970,
        ]
    }

    private func send(_ object: [String: Any]) {
        queue.async {
            guard self.open, let task = self.task,
                  let data = try? JSONSerialization.data(withJSONObject: object),
                  let text = String(data: data, encoding: .utf8) else { return }
            task.send(.string(text)) { _ in }
        }
    }

    private func sendSnapshot() {
        let entries = (snapshotProvider?() ?? []).map(Self.payload)
        guard let data = try? JSONSerialization.data(
            withJSONObject: ["type": "snapshot", "entries": entries]),
            let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { _ in }
    }

    // MARK: - Connection

    private var socketURL: URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.path = "/publish"
        components.queryItems = [
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "key", value: publishKey),
        ]
        return components.url!
    }

    private func connect() {
        guard active, task == nil else { return }
        let task = session.webSocketTask(with: socketURL)
        self.task = task
        task.resume()
        receiveLoop(task)
    }

    private func disconnected() {
        guard task != nil || open else { return }
        setOpen(false)
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        guard active else { return }
        let delay = backoff
        backoff = min(backoff * 2, 8)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.connect()
        }
    }

    private func setOpen(_ value: Bool) {
        guard open != value else { return }
        open = value
        onStateChange?(value)
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard self.task === task else { return }
                switch result {
                case .success(let message):
                    if case .string(let text) = message,
                       let data = text.data(using: .utf8),
                       let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        switch object["type"] as? String {
                        case "viewers":
                            self.onViewers?(object["count"] as? Int ?? 0)
                        case "ping":
                            task.send(.string(#"{"type":"pong"}"#)) { _ in }
                        default:
                            break
                        }
                    }
                    self.receiveLoop(task)
                case .failure:
                    self.disconnected()
                }
            }
        }
    }
}

extension LiveSharePublisher: URLSessionWebSocketDelegate {
    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        queue.async {
            guard webSocketTask === self.task else { return }
            self.backoff = 0.5
            self.setOpen(true)
            self.sendSnapshot()
            EarsLog.info("[share] publishing live transcript")
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
            self.disconnected()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        queue.async {
            guard task === self.task else { return }
            self.disconnected()
        }
    }
}
