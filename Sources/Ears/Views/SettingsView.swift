import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var deepgramKey = Secrets.key(.deepgram)
    @State private var anthropicKey = Secrets.key(.anthropic)
    @AppStorage("smartTapTargeting") private var smartTapTargeting = true
    @AppStorage("echoCancellation") private var echoCancellation = false
    @AppStorage("autoStartOnMeeting") private var autoStartOnMeeting = false
    @AppStorage(LiveTranscriptController.serverURLDefaultsKey) private var liveServerURL = ""

    private var blackHoleFound: Bool {
        AudioDevices.findDevice(named: "BlackHole", needsInput: true) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings")
                .font(.headline)

            VStack(alignment: .leading, spacing: 5) {
                Text("Deepgram API key (transcription)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                SecureField("dg_…", text: $deepgramKey)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Anthropic API key (Ask AI)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                SecureField("sk-ant-…", text: $anthropicKey)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Live Transcript relay URL (blank = default relay)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField(LiveTranscriptController.defaultServerURL, text: $liveServerURL)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }

            if #available(macOS 14.4, *) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.green)
                    Text("System audio: native capture — no driver, volume keys unaffected")
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle(isOn: $smartTapTargeting) {
                    Text("Capture only the app that's in a call (recommended) — keeps notification sounds and music out of the transcript")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.checkbox)
                Toggle(isOn: $echoCancellation) {
                    Text("Echo cancellation (experimental) — meet on speakers without the mic re-hearing the meeting. Applies on the next session.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.checkbox)
                Toggle(isOn: $autoStartOnMeeting) {
                    Text("Auto-start listening when a meeting is detected (otherwise Ears shows a one-click prompt)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.checkbox)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: blackHoleFound ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(blackHoleFound ? Color.green : Color.yellow)
                    Text(blackHoleFound
                         ? "BlackHole 2ch detected"
                         : "BlackHole 2ch not found — install from existential.audio/blackhole")
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Keys are stored in a private file only your account can read. Transcripts and AI summaries are saved to Documents/Ears when you stop a session.")
                Text("⌘⇧E hides and shows the HUD, and so does clicking the ear icon in the menu bar. The HUD is invisible in screen shares and recordings.")
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Button("Open transcripts folder") {
                let dir = SessionController.transcriptsDirectory
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                NSWorkspace.shared.open(dir)
            }
            .font(.system(size: 11))

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        // Keys save when the sheet closes (Done, Esc, or click-away) — not
        // per keystroke.
        .onDisappear(perform: saveKeys)
    }

    private func saveKeys() {
        Secrets.set(deepgramKey, for: .deepgram)
        Secrets.set(anthropicKey, for: .anthropic)
    }
}
