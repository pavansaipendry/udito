import AppKit
import Foundation

/// One-click "share a live view of my transcript": creates a share on the
/// relay, copies the view link, and mirrors every transcript change out to
/// whoever opens it. Main thread only.
final class LiveShareController: ObservableObject {
    static let shared = LiveShareController()

    @Published private(set) var isSharing = false
    @Published private(set) var viewers = 0
    @Published private(set) var viewURL: URL?

    private var publisher: LiveSharePublisher?
    private weak var transcript: TranscriptStore?

    func start(transcript: TranscriptStore) {
        guard !isSharing, let server = LiveTranscriptController.serverURL else { return }
        self.transcript = transcript

        var request = URLRequest(url: server.appendingPathComponent("shares"))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self, error == nil, let data,
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let token = object["token"] as? String,
                      let publishKey = object["publishKey"] as? String,
                      let view = (object["viewURL"] as? String).flatMap(URL.init) else {
                    EarsLog.error("[share] could not create a share")
                    return
                }
                self.open(server: server, token: token, publishKey: publishKey, view: view)
            }
        }.resume()
    }

    private func open(server: URL, token: String, publishKey: String, view: URL) {
        guard let transcript else { return }
        let publisher = LiveSharePublisher(baseURL: server, token: token, publishKey: publishKey)
        publisher.snapshotProvider = { [weak transcript] in transcript?.entries ?? [] }
        publisher.onViewers = { [weak self] count in
            DispatchQueue.main.async { self?.viewers = count }
        }
        self.publisher = publisher

        transcript.onChange = { [weak publisher] entry in publisher?.publish(entry) }
        transcript.onClear = { [weak publisher] in publisher?.publishClear() }

        publisher.start()
        isSharing = true
        viewURL = view
        viewers = 0

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(view.absoluteString, forType: .string)
        EarsLog.info("[share] live view link copied")
    }

    func stop() {
        guard isSharing else { return }
        transcript?.onChange = nil
        transcript?.onClear = nil
        publisher?.stop()
        publisher = nil
        isSharing = false
        viewers = 0
        viewURL = nil
        EarsLog.info("[share] stopped")
    }
}
