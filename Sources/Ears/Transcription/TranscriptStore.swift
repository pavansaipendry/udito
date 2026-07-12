import Foundation

enum Speaker: String {
    case you = "You"
    case them = "Them"
}

struct TranscriptEntry: Identifiable, Equatable {
    let id: UUID
    let speaker: Speaker
    var text: String
    var isFinal: Bool
    let startedAt: Date
    var updatedAt: Date
    var participant: Int?

    /// Display label — diarization splits "Them" into numbered speakers.
    var label: String {
        switch speaker {
        case .you: return "You"
        case .them: return participant.map { "Them \($0 + 1)" } ?? "Them"
        }
    }
}

/// Ordered transcript. Deepgram sends interim results (replace), finalized
/// fragments (accumulate), and speech_final (utterance complete) — this store
/// folds them into one growing entry per speaker turn. Main thread only.
final class TranscriptStore: ObservableObject {
    @Published private(set) var entries: [TranscriptEntry] = []

    /// Fired with the entry each `ingest` touched — feeds the live share
    /// publisher without duplicating any folding logic. Main thread.
    var onChange: ((TranscriptEntry) -> Void)?
    var onClear: (() -> Void)?

    private var liveEntryIDs: [Speaker: UUID] = [:]
    private var committedText: [Speaker: String] = [:]

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// A same-speaker utterance that starts within this window of the
    /// previous block (with nothing in between) continues that block —
    /// "talk, pause to think, keep talking" stays one block.
    static let mergeWindow: TimeInterval = 15
    /// Listener acknowledgments ("okay", "sounds good") that don't count as
    /// taking the floor — they don't break the speaker's block. In real audio
    /// these overlap the speaker anyway; transcription just serializes them.
    private static let backchannelVocabulary: Set<String> = [
        "okay", "ok", "kay", "yeah", "yes", "yep", "yup", "ya", "sure",
        "right", "correct", "exactly", "true", "fine", "nice", "great",
        "awesome", "perfect", "cool", "understood", "agreed", "agree",
        "mhm", "mm", "hmm", "mmhmm", "uh", "huh", "oh", "ah", "wow",
        "interesting", "good", "sounds", "makes", "sense", "i", "see",
        "got", "it", "gotcha", "thanks", "thank", "you", "alright", "all",
        "no", "worries", "totally", "definitely", "absolutely", "indeed",
        "really", "noted",
    ]

    /// True for short pure-acknowledgment interjections.
    static func isBackchannel(_ text: String) -> Bool {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty, words.count <= 5 else { return false }
        return words.allSatisfy { backchannelVocabulary.contains($0) }
    }
    /// Long monologues still break into readable blocks (industry-standard
    /// paragraphing: speaker + gap + size caps).
    static let mergeMaxBlockChars = 700
    static let mergeMaxBlockAge: TimeInterval = 120

    func ingest(_ result: DeepgramStream.Result, from speaker: Speaker, at now: Date = Date()) {
        var touchedID: UUID?
        defer {
            if let touchedID, let entry = entries.first(where: { $0.id == touchedID }) {
                onChange?(entry)
            }
        }
        let fragment = result.text.trimmingCharacters(in: .whitespaces)
        var base = committedText[speaker] ?? ""

        // No open block for this speaker: continue their previous block if
        // it's still recent, they weren't genuinely interrupted, and (for
        // diarized meeting audio) it's the same participant. Up to two
        // other-speaker backchannels ("okay", "sounds good") in between
        // don't count as interruptions.
        if liveEntryIDs[speaker] == nil, !fragment.isEmpty {
            var scan = entries.count - 1
            var skipped = 0
            while scan >= 0, skipped < 2,
                  entries[scan].speaker != speaker,
                  Self.isBackchannel(entries[scan].text) {
                scan -= 1
                skipped += 1
            }
            if scan >= 0 {
                let candidate = entries[scan]
                if candidate.speaker == speaker,
                   result.participant == nil || candidate.participant == nil || result.participant == candidate.participant,
                   now.timeIntervalSince(candidate.updatedAt) <= Self.mergeWindow,
                   candidate.text.count < Self.mergeMaxBlockChars,
                   now.timeIntervalSince(candidate.startedAt) < Self.mergeMaxBlockAge {
                    liveEntryIDs[speaker] = candidate.id
                    committedText[speaker] = candidate.text
                    base = candidate.text
                    entries[scan].isFinal = false
                }
            }
        }

        if result.isFinal, !fragment.isEmpty {
            base = base.isEmpty ? fragment : base + " " + fragment
            committedText[speaker] = base
        }
        let display: String
        if result.isFinal {
            display = base
        } else {
            display = base.isEmpty ? fragment : base + " " + fragment
        }

        if !display.isEmpty {
            if let id = liveEntryIDs[speaker],
               let index = entries.firstIndex(where: { $0.id == id }) {
                entries[index].text = display
                entries[index].updatedAt = now
                if let participant = result.participant {
                    entries[index].participant = participant
                }
                touchedID = id
            } else {
                let entry = TranscriptEntry(
                    id: UUID(),
                    speaker: speaker,
                    text: display,
                    isFinal: false,
                    startedAt: now,
                    updatedAt: now,
                    participant: result.participant
                )
                liveEntryIDs[speaker] = entry.id
                entries.append(entry)
                touchedID = entry.id
            }
        }

        if result.isFinal, result.speechFinal {
            if let id = liveEntryIDs[speaker],
               let index = entries.firstIndex(where: { $0.id == id }) {
                entries[index].isFinal = true
                touchedID = id
            }
            liveEntryIDs[speaker] = nil
            committedText[speaker] = nil
        }
    }

    func clear() {
        entries.removeAll()
        liveEntryIDs.removeAll()
        committedText.removeAll()
        onClear?()
    }

    func markdown() -> String {
        entries
            .map { "**\($0.label)** (\(Self.timeFormatter.string(from: $0.startedAt))): \($0.text)" }
            .joined(separator: "\n\n")
    }
}
