import SwiftUI

/// First-run welcome: keys, permissions, and the three things worth knowing.
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @State private var deepgramKey = Secrets.key(.deepgram)
    @State private var anthropicKey = Secrets.key(.anthropic)

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "ear.badge.waveform")
                    .font(.system(size: 30))
                    .foregroundStyle(.primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to Ears")
                        .font(.title3.weight(.semibold))
                    Text("Live meeting transcription with an AI copilot.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            step(number: "1", title: "Add your API keys") {
                VStack(alignment: .leading, spacing: 6) {
                    SecureField("Deepgram API key (transcription)", text: $deepgramKey)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: deepgramKey) { Secrets.set($0, for: .deepgram) }
                    SecureField("Anthropic API key (Ask AI) — optional", text: $anthropicKey)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: anthropicKey) { Secrets.set($0, for: .anthropic) }
                    Text("Stored in a private file only your account can read — never sent anywhere except the transcription service itself.")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }

            step(number: "2", title: "Allow two permissions on first Start") {
                Text("macOS will ask for **Microphone** (your voice) and **System Audio Recording** (the meeting). Click Allow for both — one time only.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            step(number: "3", title: "Good to know") {
                VStack(alignment: .leading, spacing: 4) {
                    Label("⌘⇧E hides and shows this window from anywhere", systemImage: "keyboard")
                    Label("Invisible in screen shares — only you see it", systemImage: "eye.slash")
                    Label("Transcripts + AI summaries save to Documents/Ears", systemImage: "folder")
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Get Started") {
                    hasOnboarded = true
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func step<Content: View>(number: String, title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.white.opacity(0.12)))
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
