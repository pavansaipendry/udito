import AppKit
import Foundation

/// Drives the standalone Live Transcript feature: a code-paired, one-way
/// channel where a remote person's speech (their phone/laptop mic → relay →
/// Deepgram) streams into a window on this Mac, live.
///
/// Fully independent of the main listening session — this never captures the
/// local mic or system audio, and it can run with or without a meeting
/// session going. Main thread only.
final class LiveTranscriptController: ObservableObject {
    static let shared = LiveTranscriptController()

    enum Phase: Equatable {
        case idle
        case creating
        case waiting(code: String)
        case live
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var guestName: String?
    @Published private(set) var guestConnected = false
    @Published private(set) var relayConnected = false
    @Published private(set) var guestLevel: Float = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var infoMessage: String?
    @Published private(set) var startedAt: Date?

    /// Fresh store instance — reuses the tested interim/final folding without
    /// sharing anything with the meeting transcript.
    let transcript = TranscriptStore()

    private var stream: LiveTranscriptStream?

    static let serverURLDefaultsKey = "liveTranscriptServerURL"
    /// The deployed relay (LiveServer/). A Settings override wins if set.
    static let defaultServerURL = "https://ears-live.pavansaipendry.workers.dev"

    static var serverURL: URL? {
        var raw = (UserDefaults.standard.string(forKey: serverURLDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { raw = defaultServerURL }
        guard let url = URL(string: raw), url.host != nil else { return nil }
        return url
    }

    var isActive: Bool { phase != .idle }

    // MARK: - Start

    func start() {
        guard phase == .idle else { return }
        errorMessage = nil
        infoMessage = nil

        let key = Secrets.key(.deepgram)
        guard !key.isEmpty else {
            errorMessage = "Add your Deepgram API key via the gear icon first."
            return
        }
        guard let server = Self.serverURL else {
            errorMessage = "Set the Live Transcript server URL in Settings (the deployed relay address)."
            return
        }
        phase = .creating
        transcript.clear()

        var request = URLRequest(url: server.appendingPathComponent("sessions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["deepgramKey": key])
        request.timeoutInterval = 10
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self, self.phase == .creating else { return }
                if let error {
                    self.fail("Could not reach the relay: \(error.localizedDescription)")
                    return
                }
                guard let data,
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self.fail("Unexpected reply from the relay.")
                    return
                }
                if let message = object["error"] as? String {
                    self.fail(message)
                    return
                }
                guard let code = object["code"] as? String,
                      let token = object["appToken"] as? String else {
                    self.fail("Unexpected reply from the relay.")
                    return
                }
                self.open(server: server, code: code, token: token)
            }
        }.resume()
    }

    private func open(server: URL, code: String, token: String) {
        let stream = LiveTranscriptStream(baseURL: server, code: code, token: token)
        stream.onEvent = { [weak self] event in
            DispatchQueue.main.async { self?.handle(event) }
        }
        stream.onStateChange = { [weak self] connected in
            DispatchQueue.main.async { self?.relayConnected = connected }
        }
        self.stream = stream
        phase = .waiting(code: code)
        stream.start()
        EarsLog.info("[live] session created — code \(code)")
    }

    private func fail(_ message: String) {
        phase = .idle
        errorMessage = message
        EarsLog.error("[live] \(message)")
    }

    // MARK: - Events

    private func handle(_ event: LiveTranscriptStream.Event) {
        switch event {
        case .status(let state, let guest, let connected):
            guestName = guest ?? guestName
            guestConnected = connected
            if state == "live", phase != .live {
                goLive()
            }
        case .guest(let joined, let name):
            guestName = name ?? guestName
            guestConnected = joined
            if joined, phase != .live {
                goLive()
            }
        case .result(let result):
            transcript.ingest(result, from: .them)
        case .level(let value):
            guestLevel = value
        case .warning(let message):
            infoMessage = message
        case .ended(let reason):
            let message: String?
            switch reason {
            case "host": message = nil
            case "expired": message = "The session expired — create a new code."
            case "lost": message = "Lost the connection to the relay."
            default: message = "The session ended."
            }
            finish(message: message)
        }
    }

    private func goLive() {
        phase = .live
        if startedAt == nil { startedAt = Date() }
        infoMessage = nil
        EarsLog.info("[live] guest joined — session live")
    }

    // MARK: - End

    func end() {
        guard phase != .idle else { return }
        stream?.sendEnd()
        finish(message: nil)
    }

    private func finish(message: String?) {
        stream?.stop()
        stream = nil
        saveTranscriptIfNeeded()
        phase = .idle
        guestName = nil
        guestConnected = false
        relayConnected = false
        guestLevel = 0
        startedAt = nil
        infoMessage = message
        EarsLog.info("[live] session ended")
    }

    /// Same home as meeting transcripts, distinct name.
    private func saveTranscriptIfNeeded() {
        let markdown = transcript.markdown()
        guard !markdown.isEmpty else { return }
        let dir = SessionController.transcriptsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let stamp = formatter.string(from: startedAt ?? Date())
        let named = guestName.map { " — \($0)" } ?? ""
        let url = dir.appendingPathComponent("Live Transcript \(stamp)\(named).md")
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            EarsLog.info("[live] transcript saved to \(url.path)")
        } catch {
            EarsLog.error("[live] failed to save transcript: \(error.localizedDescription)")
        }
    }
}
