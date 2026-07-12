import AppKit
import SwiftUI

/// Live Transcript panel, embedded in the HUD where the copilot column
/// normally sits: pair with a remote person by code, then watch everything
/// they say stream in live. One-way — nothing on this Mac is captured.
struct LiveTranscriptPanel: View {
    @ObservedObject var controller: LiveTranscriptController = .shared

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
            Divider().opacity(0.25)
            banner
            content
            Divider().opacity(0.25)
            footer
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        }
        .background(Color.white.opacity(0.02))
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .shadow(color: statusColor.opacity(0.9), radius: 3)
            Text("Live Transcript")
                .font(.system(size: 11, weight: .semibold))
            if let startedAt = controller.startedAt {
                ElapsedText(since: startedAt)
            }
            Spacer()
            actionButton
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch controller.phase {
        case .idle:
            EmptyView()
        case .creating:
            ProgressView().controlSize(.small)
        case .waiting, .live:
            Button {
                controller.end()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 8, weight: .bold))
                    Text("End")
                        .font(.system(size: 11, weight: .semibold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .foregroundStyle(Color.red)
                .background(Capsule().fill(Color.red.opacity(0.18)))
                .overlay(Capsule().strokeBorder(Color.red.opacity(0.45), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var banner: some View {
        if let message = controller.errorMessage ?? controller.infoMessage {
            let isError = controller.errorMessage != nil
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .font(.system(size: 10))
                Text(message)
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isError ? Color.red : Color.yellow)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background((isError ? Color.red : Color.yellow).opacity(0.1))
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch controller.phase {
        case .idle, .creating:
            idleState
        case .waiting(let code):
            waitingState(code: code)
        case .live:
            liveTranscript
        }
    }

    private var idleState: some View {
        VStack(spacing: 12) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text("Hear someone who isn't in the room.")
                .font(.system(size: 12, weight: .medium))
            Text("Create a code and share it. When they enter it on the\njoin page, everything they say appears here — live.\nNothing on this Mac is recorded.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                controller.start()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                    Text("Create code")
                        .font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 6)
                .foregroundStyle(Color.green)
                .background(Capsule().fill(Color.green.opacity(0.18)))
                .overlay(Capsule().strokeBorder(Color.green.opacity(0.45), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(controller.phase == .creating)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func waitingState(code: String) -> some View {
        VStack(spacing: 13) {
            Text("Share this code")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(formattedCode(code))
                .font(.system(size: 38, weight: .bold).monospacedDigit())
                .kerning(5)
                .textSelection(.enabled)
            if let server = LiveTranscriptController.serverURL {
                Text("They open \(displayHost(server))/join and enter it.\nTheir phone browser is enough — nothing to install.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button {
                copyInvite(code: code)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                    Text("Copy invite")
                        .font(.system(size: 11, weight: .semibold))
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.white.opacity(0.12)))
                .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Waiting for them to join… (code expires in 10 minutes)")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var liveTranscript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if controller.transcript.entries.isEmpty {
                        Text("Connected — waiting for them to speak…")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 50)
                    }
                    ForEach(controller.transcript.entries) { entry in
                        liveEntryRow(entry).id(entry.id)
                    }
                }
                .padding(10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: controller.transcript.entries.last?.text) { _ in
                guard let id = controller.transcript.entries.last?.id else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
        }
    }

    private func liveEntryRow(_ entry: TranscriptEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(controller.guestName ?? "Guest")
                .font(.system(size: 10, weight: .bold))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.orange.opacity(0.18)))
                .foregroundStyle(Color.orange)
            Text(entry.text)
                .font(.system(size: 13))
                .foregroundStyle(entry.isFinal ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if controller.phase == .live {
                LevelMeter(
                    label: controller.guestName ?? "Guest",
                    level: controller.guestLevel,
                    connected: controller.guestConnected && controller.relayConnected,
                    active: true,
                    color: .orange
                )
                if !controller.guestConnected {
                    Text("They dropped — waiting for them to reconnect…")
                        .font(.system(size: 9))
                        .foregroundStyle(.yellow)
                }
            } else {
                Text("One-way: only their voice is transcribed.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(controller.transcript.markdown(), forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Copy transcript")
            .disabled(controller.transcript.entries.isEmpty)
        }
    }

    // MARK: - Helpers

    private var statusColor: Color {
        switch controller.phase {
        case .idle: return controller.errorMessage == nil ? .gray : .red
        case .creating: return .orange
        case .waiting: return .orange
        case .live:
            return (controller.relayConnected && controller.guestConnected) ? .green : .orange
        }
    }

    private func formattedCode(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return code.prefix(3) + " " + code.suffix(3)
    }

    private func displayHost(_ url: URL) -> String {
        url.host ?? url.absoluteString
    }

    private func copyInvite(code: String) {
        guard let server = LiveTranscriptController.serverURL else { return }
        let invite = "Open \(server.absoluteString)/join and enter code \(code) — I'll see what you say, live."
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(invite, forType: .string)
    }
}
