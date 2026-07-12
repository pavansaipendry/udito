import AVFoundation
import AppKit
import Combine
import CoreAudio
import Foundation

/// Orchestrates a listening session: output routing, two captures (mic +
/// BlackHole), two Deepgram streams, and a watchdog that keeps everything
/// alive through hours-long meetings. All state mutation happens on the
/// main thread.
final class SessionController: ObservableObject {
    static let shared = SessionController()

    enum State: Equatable {
        case idle
        case starting
        case listening
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var errorMessage: String?
    @Published private(set) var warning: String?
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var systemLevel: Float = 0
    @Published private(set) var micConnected = false
    @Published private(set) var systemConnected = false
    @Published private(set) var startedAt: Date?
    @Published private(set) var detectedMeetingApp: String?

    let transcript = TranscriptStore()

    private var micCapture: SystemAudioSource?
    private var systemCapture: SystemAudioSource?
    private var micStream: DeepgramStream?
    private var systemStream: DeepgramStream?
    private let router = OutputRouter()
    private var watchdog: Timer?
    private var blackHoleID: AudioDeviceID?
    private var summaryClient: ClaudeClient?
    private var idleWatch: Timer?
    private var detectionStreak = 0
    private var dismissedRosterKey: String?
    private var micStallTicks = 0
    private var systemStallTicks = 0

    init() {
        startIdleWatch()
    }

    var isListening: Bool { state == .listening }

    static var transcriptsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ears", isDirectory: true)
    }

    func toggle() {
        state == .idle ? start() : stop()
    }

    // MARK: - Meeting auto-detection (idle only)

    private func startIdleWatch() {
        idleWatch = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.idleTick() }
        }
    }

    private func idleTick() {
        guard state == .idle, #available(macOS 14.4, *) else { return }
        guard let key = Self.currentRosterKey() else {
            // Call ended — reset so the next call can prompt again.
            detectionStreak = 0
            detectedMeetingApp = nil
            dismissedRosterKey = nil
            return
        }
        guard key != dismissedRosterKey else { return }
        detectionStreak += 1
        // Two consecutive sightings (~6 s) — mic use flickers on app launch.
        guard detectionStreak >= 2 else { return }
        let display = key.replacingOccurrences(of: "+", with: ", ")
        if UserDefaults.standard.bool(forKey: "autoStartOnMeeting"), !resolveAPIKey().isEmpty {
            EarsLog.info("Meeting detected (\(display)) — auto-starting")
            suppressCurrentRoster()
            start()
        } else if detectedMeetingApp != display {
            detectedMeetingApp = display
            EarsLog.info("Meeting detected: \(display)")
        }
    }

    func dismissMeetingPrompt() {
        suppressCurrentRoster()
    }

    /// Stop prompting for the call that's happening right now; a future call
    /// (different roster, or after this one ends) prompts again.
    private func suppressCurrentRoster() {
        if #available(macOS 14.4, *) {
            dismissedRosterKey = Self.currentRosterKey()
        }
        detectedMeetingApp = nil
        detectionStreak = 0
    }

    @available(macOS 14.4, *)
    private static func currentRosterKey() -> String? {
        let roster = AudioProcesses.inCallProcessObjects(
            excludingPID: ProcessInfo.processInfo.processIdentifier
        )
        guard !roster.isEmpty else { return nil }
        let names = roster.compactMap { object -> String? in
            guard let pid = AudioProcesses.pid(of: object) else { return nil }
            return NSRunningApplication(processIdentifier: pid)?.localizedName
        }
        guard !names.isEmpty else { return "call" }
        return Set(names).sorted().joined(separator: "+")
    }

    // MARK: - Start

    func start() {
        guard state == .idle else { return }
        errorMessage = nil
        warning = nil
        detectedMeetingApp = nil
        detectionStreak = 0

        let key = resolveAPIKey()
        guard !key.isEmpty else {
            errorMessage = "Add your Deepgram API key via the gear icon."
            return
        }
        state = .starting

        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else {
                    self.fail("Microphone access denied. Enable Ears in System Settings → Privacy & Security → Microphone.")
                    return
                }
                self.validateKey(key) { keyError in
                    if let keyError {
                        self.fail(keyError)
                    } else {
                        self.beginSession(key: key)
                    }
                }
            }
        }
    }

    private func resolveAPIKey() -> String {
        Secrets.key(.deepgram)
    }

    /// Catches a bad key up front with a clear message instead of an endless
    /// reconnect loop. Network hiccups do NOT block starting — the streams
    /// retry on their own.
    private func validateKey(_ key: String, completion: @escaping (String?) -> Void) {
        var request = URLRequest(url: URL(string: "https://api.deepgram.com/v1/auth/token")!)
        request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 6
        URLSession.shared.dataTask(with: request) { _, response, _ in
            DispatchQueue.main.async {
                if let http = response as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
                    completion("Deepgram rejected the API key — check it via the gear icon.")
                } else {
                    completion(nil)
                }
            }
        }.resume()
    }

    private func beginSession(key: String) {
        do {
            blackHoleID = nil
            transcript.clear()

            micStream = makeStream(key: key, speaker: .you) { [weak self] connected in
                self?.micConnected = connected
            }
            systemStream = makeStream(key: key, speaker: .them) { [weak self] connected in
                self?.systemConnected = connected
            }

            guard let micDevice = AudioDevices.bestMicrophoneID() else {
                throw EarsError("No microphone found.")
            }
            let micAudioHandler: (Data) -> Void = { [weak self] data in self?.micStream?.send(data) }
            let micLevelHandler: (Float) -> Void = { [weak self] level in
                DispatchQueue.main.async { self?.micLevel = level }
            }
            let mic: SystemAudioSource
            if UserDefaults.standard.bool(forKey: "echoCancellation") {
                mic = VoiceProcessedMicCapture()
                EarsLog.info("Echo cancellation requested for the mic")
            } else {
                mic = HALCapture(deviceID: micDevice, name: "mic")
            }
            mic.onAudio = micAudioHandler
            mic.onLevel = micLevelHandler
            micCapture = mic

            let system = try makeSystemSource()
            system.onAudio = { [weak self] data in self?.systemStream?.send(data) }
            system.onLevel = { [weak self] level in
                DispatchQueue.main.async { self?.systemLevel = level }
            }
            systemCapture = system

            micStream?.start()
            systemStream?.start()
            do {
                try mic.start()
            } catch {
                // Echo-cancelled mic is experimental — never let it block a
                // session. Standard mic path is the guaranteed fallback.
                guard !(mic is HALCapture) else { throw error }
                EarsLog.error("Echo-cancelled mic failed (\(error.localizedDescription)) — using the standard mic")
                let fallback = HALCapture(deviceID: micDevice, name: "mic")
                fallback.onAudio = micAudioHandler
                fallback.onLevel = micLevelHandler
                micCapture = fallback
                try fallback.start()
            }

            startedAt = Date()
            state = .listening
            startWatchdog()
            EarsLog.info("Session started")
        } catch {
            teardown()
            fail(error.localizedDescription)
        }
    }

    /// Prefer the driverless Core Audio process tap (macOS 14.4+); fall back
    /// to BlackHole + output routing on older systems or if the tap is
    /// refused. The tap path leaves the user's output device untouched.
    private func makeSystemSource() throws -> SystemAudioSource {
        if #available(macOS 14.4, *) {
            let tap = ProcessTapCapture()
            do {
                try tap.start()
                EarsLog.info("System audio via process tap — driverless")
                return tap
            } catch {
                EarsLog.error("Process tap unavailable (\(error.localizedDescription)) — trying BlackHole fallback")
            }
        }
        guard let blackHole = AudioDevices.findDevice(named: "BlackHole", needsInput: true) else {
            throw EarsError("System audio capture unavailable. Allow Ears under System Settings → Privacy & Security → Screen & System Audio Recording, then try again.")
        }
        blackHoleID = blackHole
        OutputRouter.cleanUpStale()
        try router.engage(blackHole: blackHole)
        let capture = HALCapture(deviceID: blackHole, name: "system")
        try capture.start()
        return capture
    }

    private func makeStream(
        key: String,
        speaker: Speaker,
        connected: @escaping (Bool) -> Void
    ) -> DeepgramStream {
        // Diarize the meeting side so multiple participants get split into
        // "Them 1" / "Them 2"; the mic side is always just the user.
        let stream = DeepgramStream(apiKey: key, label: speaker.rawValue, diarize: speaker == .them)
        stream.onResult = { [weak self] result in
            DispatchQueue.main.async { self?.transcript.ingest(result, from: speaker) }
        }
        stream.onStateChange = { value in
            DispatchQueue.main.async { connected(value) }
        }
        return stream
    }

    private func fail(_ message: String) {
        state = .idle
        errorMessage = message
        EarsLog.error("Session failed to start: \(message)")
    }

    // MARK: - Stop

    func stop() {
        guard state != .idle else { return }
        let began = startedAt ?? Date()
        teardown()
        state = .idle
        startedAt = nil
        micLevel = 0
        systemLevel = 0
        micConnected = false
        systemConnected = false
        warning = nil
        micStallTicks = 0
        systemStallTicks = 0
        // Don't immediately re-prompt for the call we just left.
        suppressCurrentRoster()
        EarsLog.info("Session stopped")

        // Streams got CloseStream — give trailing finals 2 s to land
        // in the transcript before writing the file.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.saveTranscript(startedAt: began)
        }
    }

    private func teardown() {
        watchdog?.invalidate()
        watchdog = nil
        micStream?.stop()
        systemStream?.stop()
        micCapture?.stop()
        systemCapture?.stop()
        micCapture = nil
        systemCapture = nil
        router.disengage()
    }

    /// Synchronous cleanup for app quit: restore audio routing no matter what.
    func emergencyTeardown() {
        micCapture?.stop()
        systemCapture?.stop()
        micStream?.stop()
        systemStream?.stop()
        router.disengage()
    }

    private func saveTranscript(startedAt: Date) {
        let markdown = transcript.markdown()
        guard !markdown.isEmpty else { return }
        // Name the file after the calendar event when there is one.
        MeetingCalendar.eventTitle(around: startedAt) { [weak self] eventTitle in
            self?.writeTranscript(markdown, startedAt: startedAt, eventTitle: eventTitle)
        }
    }

    private func writeTranscript(_ markdown: String, startedAt: Date, eventTitle: String?) {
        let dir = Self.transcriptsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let stamp = formatter.string(from: startedAt)
        let name = eventTitle.map { "\($0) — \(stamp)" } ?? "Meeting \(stamp)"
        let url = dir.appendingPathComponent("\(name).md")
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            EarsLog.info("Transcript saved to \(url.lastPathComponent)")
            generateSummary(into: url, transcript: markdown)
        } catch {
            EarsLog.error("Failed to save transcript: \(error.localizedDescription)")
        }
    }

    /// Post-meeting: prepend an AI summary + action items to the saved file.
    private func generateSummary(into url: URL, transcript markdown: String) {
        let key = Secrets.key(.anthropic)
        guard !key.isEmpty, markdown.count > 400 else { return }
        var capped = markdown
        if capped.count > 150_000 {
            capped = String(capped.suffix(150_000))
        }
        let client = ClaudeClient()
        summaryClient = client
        var answer = ""
        client.ask(
            apiKey: key,
            system: "You write accurate, concise meeting summaries.",
            messages: [[
                "role": "user",
                "content": "Meeting transcript:\n\n\(capped)\n\nSummarize this meeting: 3-6 bullets covering the key points and decisions, then an \"Action items\" list naming who owns each item (write \"None\" if there are none). No preamble.",
            ]],
            onDelta: { answer += $0 },
            onComplete: { [weak self] error in
                DispatchQueue.main.async {
                    self?.summaryClient = nil
                    guard error == nil, !answer.isEmpty else {
                        if let error {
                            EarsLog.error("Meeting summary failed: \(error.localizedDescription)")
                        }
                        return
                    }
                    guard let existing = try? String(contentsOf: url, encoding: .utf8) else { return }
                    let combined = "# Summary\n\n\(answer)\n\n---\n\n\(existing)"
                    try? combined.write(to: url, atomically: true, encoding: .utf8)
                    EarsLog.info("Meeting summary added to \(url.lastPathComponent)")
                }
            }
        )
    }

    // MARK: - Watchdog

    private func startWatchdog() {
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.watchdogTick() }
        }
    }

    private func watchdogTick() {
        guard state == .listening else { return }

        // The user switched output devices mid-meeting (e.g. to AirPods):
        // rebuild the multi-output on top of whatever they picked so meeting
        // audio keeps flowing into BlackHole.
        if !router.isDefaultOutput, let blackHole = blackHoleID {
            EarsLog.info("Default output changed — rebuilding multi-output on the new device")
            router.disengage(restore: false)
            do {
                try router.engage(blackHole: blackHole)
                warning = nil
            } catch {
                warning = "Meeting audio re-route failed: \(error.localizedDescription)"
            }
        }

        // The user's mic changed (AirPods connected, default input switched):
        // follow it, skipping virtual loopback devices. Only the pinned HAL
        // mic needs this; the voice-processed mic follows the default itself.
        if let mic = micCapture as? HALCapture,
           let desired = AudioDevices.bestMicrophoneID(),
           desired != mic.deviceID {
            mic.retarget(to: desired)
        }

        // Restart stalled captures — and if one stays dead, say so loudly.
        // The alternative is the worst failure this product can have: the
        // user records silence for an hour believing it worked.
        if let mic = micCapture, mic.isStalled {
            micStallTicks += 1
            mic.tryRestart()
        } else {
            micStallTicks = 0
        }
        if let system = systemCapture, system.isStalled {
            systemStallTicks += 1
            system.tryRestart()
        } else {
            systemStallTicks = 0
        }
        let stalledSource = micStallTicks >= 5 ? "your microphone"
            : (systemStallTicks >= 5 ? "meeting audio" : nil)
        if let stalledSource {
            warning = "No audio from \(stalledSource) for 10+ seconds — check the device and the Microphone / System Audio permissions in System Settings."
        } else if warning?.hasPrefix("No audio from") == true {
            warning = nil
        }
    }
}
