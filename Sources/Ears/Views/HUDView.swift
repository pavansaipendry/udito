import AppKit
import SwiftUI

struct HUDView: View {
    @EnvironmentObject var session: SessionController
    @StateObject private var copilot = Copilot()
    @StateObject private var documents = MeetingDocuments()
    @ObservedObject private var liveTranscript = LiveTranscriptController.shared
    @ObservedObject private var liveShare = LiveShareController.shared
    @State private var showLiveTranscript = false
    @State private var emailClient: ClaudeClient?
    @State private var emailDone = false
    @State private var showSettings = false
    @State private var showLibrary = false
    @State private var showOnboarding = false
    @State private var draft = ""
    @AppStorage("starMode") private var starMode = false
    @AppStorage("askHistory") private var askHistory = false
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @AppStorage("transcriptFraction") private var transcriptFraction = 0.2

    @State private var compact = false

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                header(compact: compact)
                    .padding(.horizontal, 12)
                    .padding(.leading, 22)
                    .padding(.vertical, compact ? 7 : 10)
                banner
                if session.state == .idle, let app = session.detectedMeetingApp {
                    meetingDetectedBanner(app)
                }
                Divider().opacity(0.25)
                if compact {
                    if showLiveTranscript {
                        LiveTranscriptPanel()
                    } else {
                        TranscriptListView(store: session.transcript)
                    }
                } else {
                    GeometryReader { inner in
                        HStack(spacing: 0) {
                            TranscriptListView(store: session.transcript)
                                .frame(width: inner.size.width * transcriptFraction)
                            SplitHandle(fraction: $transcriptFraction, totalWidth: inner.size.width)
                            if showLiveTranscript {
                                LiveTranscriptPanel()
                                    .frame(maxWidth: .infinity)
                            } else {
                                copilotColumn
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }
                    Divider().opacity(0.25)
                    footer
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(GlassBackground().ignoresSafeArea())
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            )
            .onAppear { updateCompact(geo.size) }
            .onChange(of: geo.size) { updateCompact($0) }
        }
        .frame(minWidth: 180, idealWidth: 740, maxWidth: .infinity,
               minHeight: 180, idealHeight: 540, maxHeight: .infinity)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showOnboarding) {
            OnboardingView()
        }
        .onAppear {
            if !hasOnboarded {
                showOnboarding = true
            }
        }
    }

    /// Hysteresis: enter compact below 480×340, leave only above 520×380.
    /// A single threshold lets a mode change nudge layout back across the
    /// line and re-render forever — the freeze this replaces. The dead band
    /// makes oscillation impossible.
    private func updateCompact(_ size: CGSize) {
        if compact {
            if size.width > 520, size.height > 380 { compact = false }
        } else if size.width < 480 || size.height < 340 {
            compact = true
        }
    }

    private func header(compact: Bool) -> some View {
        HStack(spacing: 9) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .shadow(color: statusColor.opacity(0.9), radius: 4)
            if !compact {
                Text(statusText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                if let startedAt = session.startedAt {
                    ElapsedText(since: startedAt)
                }
            }
            Spacer()
            Button {
                showLiveTranscript.toggle()
            } label: {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 12))
                    .foregroundStyle(
                        liveTranscript.isActive || showLiveTranscript
                            ? AnyShapeStyle(Color.orange)
                            : AnyShapeStyle(.secondary)
                    )
            }
            .buttonStyle(.plain)
            .help("Live Transcript — a remote person's speech, live (click again for Ask AI)")
            if !compact {
                Button {
                    showLibrary = true
                } label: {
                    Image(systemName: "books.vertical")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Meeting library")
                .sheet(isPresented: $showLibrary) {
                    LibraryView()
                }
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Settings")
                .sheet(isPresented: $showSettings) {
                    SettingsView()
                }
            }
            startStopButton
        }
    }

    private var startStopButton: some View {
        Button {
            session.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: session.state == .idle ? "play.fill" : "stop.fill")
                    .font(.system(size: 9, weight: .bold))
                Text(session.state == .idle ? "Start" : "Stop")
                    .font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .foregroundStyle(session.state == .idle ? Color.green : Color.red)
            .background(
                Capsule().fill((session.state == .idle ? Color.green : Color.red).opacity(0.18))
            )
            .overlay(
                Capsule().strokeBorder(
                    (session.state == .idle ? Color.green : Color.red).opacity(0.45),
                    lineWidth: 1
                )
            )
        }
        .buttonStyle(.plain)
        .disabled(session.state == .starting)
    }

    private func meetingDetectedBanner(_ app: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "video.fill")
                .font(.system(size: 10))
            Text("Meeting detected — \(app)")
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            Spacer()
            Button {
                session.start()
            } label: {
                Text("Start listening")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.green)
            }
            .buttonStyle(.plain)
            Button {
                session.dismissMeetingPrompt()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Not this call")
        }
        .foregroundStyle(Color.green)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.green.opacity(0.10))
    }

    private var copilotColumn: some View {
        VStack(spacing: 0) {
            copilotTopBar
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
            Divider().opacity(0.25)
            if copilot.exchanges.isEmpty {
                copilotEmptyState
            } else {
                CopilotPanel(copilot: copilot)
            }
            Divider().opacity(0.25)
            if !documents.documents.isEmpty || documents.warning != nil {
                documentChips
            }
            askRow
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        }
    }

    private var copilotTopBar: some View {
        HStack(spacing: 8) {
            Button {
                copilot.answerLastMessage(
                    transcript: session.transcript,
                    documents: documents,
                    starFormat: starMode
                )
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 9))
                    Text("Last message")
                        .font(.system(size: 10, weight: .semibold))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.12)))
                .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .help("Answer the last thing they said")
            Spacer()
            Button {
                askHistory.toggle()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 8, weight: .bold))
                    Text("History")
                        .font(.system(size: 9, weight: .bold))
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(askHistory ? 0.22 : 0.08)))
                .overlay(Capsule().strokeBorder(askHistory ? Color.white.opacity(0.5) : .clear, lineWidth: 1))
                .foregroundStyle(askHistory ? Color.primary : Color.secondary)
            }
            .buttonStyle(.plain)
            .help("Answer using past meeting transcripts too")
            Button {
                starMode.toggle()
            } label: {
                Text("STAR")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(starMode ? 0.22 : 0.08)))
                    .overlay(Capsule().strokeBorder(starMode ? Color.white.opacity(0.5) : .clear, lineWidth: 1))
                    .foregroundStyle(starMode ? Color.primary : Color.secondary)
            }
            .buttonStyle(.plain)
            .help("STAR mode — answers formatted as Situation, Task, Action, Result")
        }
    }

    private var copilotEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text("Ask AI about the meeting")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Attach documents with the paperclip.\nAnswers appear here.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(0.03))
    }

    private var askRow: some View {
        HStack(spacing: 8) {
            Button(action: attachDocuments) {
                Image(systemName: "paperclip")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Attach meeting documents (PDF, Word, text, markdown)")
            Image(systemName: "sparkles")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Ask AI about the meeting…", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit(submitQuestion)
            if copilot.isBusy {
                ProgressView()
                    .controlSize(.small)
            } else if !copilot.exchanges.isEmpty {
                Button {
                    copilot.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear AI answers")
            }
        }
    }

    private var documentChips: some View {
        VStack(alignment: .leading, spacing: 3) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(documents.documents) { document in
                        HStack(spacing: 4) {
                            Image(systemName: "doc.fill")
                                .font(.system(size: 9))
                            Text(document.name)
                                .font(.system(size: 10, weight: .medium))
                                .lineLimit(1)
                            Button {
                                documents.remove(document.id)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 7, weight: .bold))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                        .foregroundStyle(.primary)
                    }
                }
                .padding(.horizontal, 12)
            }
            if let warning = documents.warning {
                Text(warning)
                    .font(.system(size: 10))
                    .foregroundStyle(.yellow)
                    .lineLimit(2)
                    .padding(.horizontal, 12)
            }
        }
        .padding(.top, 7)
    }

    private func attachDocuments() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Attach meeting documents — PDF, Word, text, or markdown"
        if panel.runModal() == .OK {
            documents.attach(urls: panel.urls)
        }
    }

    private func submitQuestion() {
        let question = draft
        draft = ""
        let useHistory = askHistory
        // History scoring reads every saved transcript — never on the main
        // thread. Scan + score in the background, then ask on main.
        DispatchQueue.global(qos: .userInitiated).async {
            var past: [Copilot.PastMeeting] = []
            if useHistory {
                let meetings = TranscriptLibrary.scan()
                past = Copilot.relevantMeetings(for: question, in: meetings) {
                    (try? String(contentsOf: $0.id, encoding: .utf8)) ?? ""
                }
            }
            DispatchQueue.main.async {
                copilot.ask(
                    question,
                    transcript: session.transcript,
                    documents: documents,
                    starFormat: starMode,
                    pastMeetings: past
                )
            }
        }
    }

    @ViewBuilder
    private var banner: some View {
        if let message = session.errorMessage ?? session.warning {
            let isError = session.errorMessage != nil
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                Text(message)
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isError ? Color.red : Color.yellow)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background((isError ? Color.red : Color.yellow).opacity(0.1))
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            LevelMeter(
                label: "You",
                level: session.micLevel,
                connected: session.micConnected,
                active: session.isListening,
                color: .cyan
            )
            LevelMeter(
                label: "Them",
                level: session.systemLevel,
                connected: session.systemConnected,
                active: session.isListening,
                color: .orange
            )
            Spacer()
            shareButton
            followUpButton
            Button {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(session.transcript.markdown(), forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Copy transcript")
            .disabled(session.transcript.entries.isEmpty)
        }
    }

    /// One-click live share: viewers with the link watch the transcript in
    /// their browser, live. Click again to end the share.
    private var shareButton: some View {
        Button {
            if liveShare.isSharing {
                liveShare.stop()
            } else {
                liveShare.start(transcript: session.transcript)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "dot.radiowaves.up.forward")
                    .font(.system(size: 11))
                if liveShare.isSharing {
                    Text("\(liveShare.viewers) watching")
                        .font(.system(size: 10, weight: .semibold))
                }
            }
            .foregroundStyle(liveShare.isSharing ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.plain)
        .help(liveShare.isSharing
              ? "Sharing live — link is in your clipboard. Click to stop."
              : "Share a live view link — anyone with it watches this transcript in their browser")
    }

    /// Drafts a ready-to-send follow-up email from the meeting so far and
    /// puts it in the clipboard.
    private var followUpButton: some View {
        Button(action: draftFollowUpEmail) {
            if emailClient != nil {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: emailDone ? "checkmark.circle.fill" : "envelope")
                    .font(.system(size: 11))
                    .foregroundStyle(emailDone ? AnyShapeStyle(Color.green) : AnyShapeStyle(.secondary))
            }
        }
        .buttonStyle(.plain)
        .help("Draft a follow-up email from this meeting (copied to clipboard)")
        // No Secrets read here: this runs on every render, and key lookup
        // can hit the keychain migration path — the action guards instead.
        .disabled(session.transcript.entries.isEmpty || emailClient != nil)
    }

    private func draftFollowUpEmail() {
        let key = Secrets.key(.anthropic)
        var transcriptText = session.transcript.markdown()
        guard !key.isEmpty, !transcriptText.isEmpty else { return }
        if transcriptText.count > 150_000 {
            transcriptText = String(transcriptText.suffix(150_000))
        }
        let client = ClaudeClient()
        emailClient = client
        var answer = ""
        client.ask(
            apiKey: key,
            system: "You draft crisp, friendly, professional follow-up emails.",
            messages: [[
                "role": "user",
                "content": "Meeting transcript (\"You\" is me — write from my perspective):\n\n\(transcriptText)\n\nDraft the follow-up email I should send to the other participants: brief thanks, a summary of what was decided, action items with owners, and any open questions. Subject line first. No preamble, no placeholders like [Name] unless truly unknowable.",
            ]],
            onDelta: { answer += $0 },
            onComplete: { error in
                DispatchQueue.main.async {
                    emailClient = nil
                    guard error == nil, !answer.isEmpty else { return }
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(answer, forType: .string)
                    emailDone = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { emailDone = false }
                }
            }
        )
    }

    private var statusColor: Color {
        switch session.state {
        case .idle: return session.errorMessage == nil ? .gray : .red
        case .starting: return .orange
        case .listening:
            return (session.micConnected && session.systemConnected) ? .green : .orange
        }
    }

    private var statusText: String {
        switch session.state {
        case .idle: return "Ready"
        case .starting: return "Starting…"
        case .listening:
            return (session.micConnected && session.systemConnected) ? "Listening" : "Reconnecting…"
        }
    }
}

// MARK: - Transcript list

struct TranscriptListView: View {
    @ObservedObject var store: TranscriptStore

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if store.entries.isEmpty {
                        emptyHint
                    }
                    ForEach(store.entries) { entry in
                        EntryRow(entry: entry).id(entry.id)
                    }
                }
                .padding(12)
            }
            .onChange(of: store.entries.last?.text) { _ in
                guard let id = store.entries.last?.id else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
        }
    }

    private var emptyHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "ear.badge.waveform")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text("Press Start before your meeting.\nYour voice and the meeting audio\nare transcribed live.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }
}

struct EntryRow: View {
    let entry: TranscriptEntry

    private var color: Color {
        entry.speaker == .you ? .cyan : .orange
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(entry.label)
                .font(.system(size: 10, weight: .bold))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(color.opacity(0.18)))
                .foregroundStyle(color)
            Text(entry.text)
                .font(.system(size: 13))
                .foregroundStyle(entry.isFinal ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Split handle

struct SplitHandle: View {
    @Binding var fraction: Double
    let totalWidth: CGFloat
    @State private var hovering = false
    @State private var dragging = false
    @State private var startFraction: Double?

    private static let minFraction = 0.2
    private static let maxFraction = 0.8

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.white.opacity(dragging || hovering ? 0.22 : 0.1))
                .frame(width: 1)
            // Grab affordance.
            Capsule()
                .fill(Color.white.opacity(dragging || hovering ? 0.5 : 0.28))
                .frame(width: 4, height: 34)
        }
        .frame(width: 12)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    dragging = true
                    guard totalWidth > 0 else { return }
                    let base = startFraction ?? fraction
                    if startFraction == nil { startFraction = base }
                    let proposed = (base * totalWidth + value.translation.width) / totalWidth
                    fraction = min(max(proposed, Self.minFraction), Self.maxFraction)
                }
                .onEnded { _ in
                    dragging = false
                    startFraction = nil
                }
        )
    }
}

// MARK: - Copilot panel

struct CopilotPanel: View {
    @ObservedObject var copilot: Copilot

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(copilot.exchanges) { exchange in
                        ExchangeRow(exchange: exchange).id(exchange.id)
                    }
                }
                .padding(10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: copilot.exchanges.last?.answer) { _ in
                guard let id = copilot.exchanges.last?.id else { return }
                proxy.scrollTo(id, anchor: .bottom)
            }
            .onChange(of: copilot.exchanges.count) { _ in
                guard let id = copilot.exchanges.last?.id else { return }
                proxy.scrollTo(id, anchor: .bottom)
            }
        }
        .background(Color.white.opacity(0.03))
    }
}

struct ExchangeRow: View {
    let exchange: Copilot.Exchange

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text(exchange.question)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let error = exchange.errorMessage {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(exchange.answer + (exchange.isStreaming ? " ▍" : ""))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Small pieces

struct LevelMeter: View {
    let label: String
    let level: Float
    let connected: Bool
    let active: Bool
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(active ? (connected ? Color.green : Color.red) : Color.gray.opacity(0.4))
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.1))
                Capsule()
                    .fill(color.opacity(0.9))
                    .frame(width: 52 * CGFloat(min(max(level, 0), 1)))
            }
            .frame(width: 52, height: 4)
            .animation(.linear(duration: 0.08), value: level)
        }
    }
}

struct ElapsedText: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Self.format(context.date.timeIntervalSince(since)))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    static func format(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
