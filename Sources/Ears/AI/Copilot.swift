import Foundation

/// On-demand meeting copilot: the user asks a question, the live transcript
/// rides along as context, and Claude's answer streams into the HUD.
final class Copilot: ObservableObject {
    struct Exchange: Identifiable, Equatable {
        let id = UUID()
        let question: String
        var answer: String = ""
        var isStreaming: Bool = true
        var errorMessage: String?
    }

    @Published private(set) var exchanges: [Exchange] = []
    @Published private(set) var isBusy = false

    private let client = ClaudeClient()

    private static let systemPrompt = """
    You are a discreet meeting copilot inside a live-transcription app. The user is in a meeting right now. In the transcript, "You" is the user speaking and "Them" is the other meeting participants ("Them 1", "Them 2" when there are several).
    Answer the user's questions using the live transcript, any past meeting transcripts provided, and any reference documents the user attached. When citing a past meeting, name it and its date. When asked what to say or how to respond, draft it in the user's voice, ready to say out loud. Be direct and brief — a few sentences unless more is clearly needed. No preamble and no headers.
    """

    /// Keep prompts bounded on hours-long meetings: newest ~100k chars of transcript.
    private static let transcriptCap = 100_000

    private var apiKey: String {
        Secrets.key(.anthropic)
    }

    var hasKey: Bool { !apiKey.isEmpty }

    /// One-click: respond to the most recent thing the other side said.
    func answerLastMessage(transcript: TranscriptStore, documents: MeetingDocuments, starFormat: Bool = false) {
        let entry = transcript.entries.last(where: { $0.speaker == .them }) ?? transcript.entries.last
        guard let entry else {
            exchanges.append(Exchange(
                question: "Last message",
                answer: "",
                isStreaming: false,
                errorMessage: "No transcript yet — nothing to answer."
            ))
            return
        }
        let question = "They just said: “\(entry.text)” — respond to it. If it's a question for me, answer it directly in my voice, ready to say aloud."
        ask(question, transcript: transcript, documents: documents, starFormat: starFormat)
    }

    /// Saved meetings most relevant to a question — term-frequency ranked.
    static func relevantMeetings(
        for question: String,
        in meetings: [TranscriptLibrary.Meeting],
        limit: Int = 3
    ) -> [TranscriptLibrary.Meeting] {
        let terms = question.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count > 2 }
        guard !terms.isEmpty else { return Array(meetings.prefix(limit)) }
        let scored = meetings.map { meeting -> (TranscriptLibrary.Meeting, Int) in
            let content = meeting.content.lowercased()
            let score = terms.reduce(0) { sum, term in
                sum + min(content.components(separatedBy: term).count - 1, 20)
            }
            return (meeting, score)
        }
        return scored
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { $0.0 }
    }

    func ask(_ question: String, transcript: TranscriptStore, documents: MeetingDocuments, starFormat: Bool = false, pastMeetings: [TranscriptLibrary.Meeting] = []) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let key = apiKey
        guard !key.isEmpty else {
            exchanges.append(Exchange(
                question: trimmed,
                answer: "",
                isStreaming: false,
                errorMessage: "Add your Anthropic API key via the gear icon."
            ))
            return
        }

        // A new question supersedes any answer still streaming.
        client.cancel()
        if let index = exchanges.lastIndex(where: { $0.isStreaming }) {
            exchanges[index].isStreaming = false
        }

        var messages: [[String: Any]] = []

        // Attached documents lead the conversation as a stable, cacheable
        // prefix (the cache breakpoint sits on the last document block).
        let documentBlocks = documents.contentBlocks()
        if !documentBlocks.isEmpty {
            var blocks = documentBlocks
            blocks.append([
                "type": "text",
                "text": "These are reference documents for this meeting. Use them when answering.",
            ])
            messages.append(["role": "user", "content": blocks])
            messages.append(["role": "assistant", "content": "Understood — I'll use these documents as reference."])
        }

        // Recent Q&A history so follow-ups work; the fresh transcript rides
        // only with the newest question.
        for prior in exchanges.suffix(6) where prior.errorMessage == nil && !prior.answer.isEmpty {
            messages.append(["role": "user", "content": prior.question])
            messages.append(["role": "assistant", "content": prior.answer])
        }

        var transcriptText = transcript.markdown()
        if transcriptText.count > Self.transcriptCap {
            transcriptText = String(transcriptText.suffix(Self.transcriptCap))
        }
        var content = "Today is \(DateFormatter.localizedString(from: Date(), dateStyle: .full, timeStyle: .short)).\n\n"
        if !pastMeetings.isEmpty {
            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .medium
            dateFormatter.timeStyle = .short
            let blocks = pastMeetings.map { meeting -> String in
                var text = meeting.content
                if text.count > 20_000 { text = String(text.prefix(20_000)) }
                return "### \(meeting.name) — \(dateFormatter.string(from: meeting.date))\n\n\(text)"
            }
            content += "Past meeting transcripts that may be relevant:\n\n\(blocks.joined(separator: "\n\n---\n\n"))\n\n"
        }
        content += transcriptText.isEmpty
            ? "The live meeting transcript is empty so far."
            : "Live meeting transcript so far:\n\n\(transcriptText)"
        content += "\n\nQuestion: \(trimmed)"
        if starFormat {
            content += "\n\nFormat the answer with the STAR method, as four short labeled sections — Situation, Task, Action, Result — written in the user's voice, ready to say out loud. Use real specifics from the transcript and any attached documents; if a detail is missing, keep it plausible and generic rather than inventing specifics."
        }
        messages.append(["role": "user", "content": content])

        let exchange = Exchange(question: trimmed)
        let id = exchange.id
        exchanges.append(exchange)
        isBusy = true

        client.ask(apiKey: key, system: Self.systemPrompt, messages: messages) { [weak self] delta in
            DispatchQueue.main.async {
                guard let self, let index = self.exchanges.firstIndex(where: { $0.id == id }) else { return }
                self.exchanges[index].answer += delta
            }
        } onComplete: { [weak self] error in
            DispatchQueue.main.async {
                guard let self, let index = self.exchanges.firstIndex(where: { $0.id == id }) else { return }
                self.exchanges[index].isStreaming = false
                self.isBusy = false
                if let error {
                    self.exchanges[index].errorMessage = error.localizedDescription
                    EarsLog.error("Copilot: \(error.localizedDescription)")
                } else {
                    EarsLog.info("Copilot answered (\(self.exchanges[index].answer.count) chars)")
                }
            }
        }
    }

    func clear() {
        client.cancel()
        exchanges.removeAll()
        isBusy = false
    }
}
