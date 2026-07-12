import Testing
@testable import Ears

struct TranscriptStoreTests {
    private func result(_ text: String, isFinal: Bool, speechFinal: Bool, participant: Int? = nil) -> DeepgramStream.Result {
        DeepgramStream.Result(text: text, isFinal: isFinal, speechFinal: speechFinal, participant: participant)
    }

    @Test func interimResultsReplaceInsteadOfAppend() {
        let store = TranscriptStore()
        store.ingest(result("hello", isFinal: false, speechFinal: false), from: .them)
        store.ingest(result("hello wor", isFinal: false, speechFinal: false), from: .them)
        store.ingest(result("hello world", isFinal: false, speechFinal: false), from: .them)

        #expect(store.entries.count == 1)
        #expect(store.entries[0].text == "hello world")
        #expect(!store.entries[0].isFinal)
    }

    @Test func finalFragmentsAccumulateUntilSpeechFinal() {
        let store = TranscriptStore()
        store.ingest(result("hello world", isFinal: true, speechFinal: false), from: .them)
        store.ingest(result("how are you", isFinal: true, speechFinal: true), from: .them)

        #expect(store.entries.count == 1)
        #expect(store.entries[0].text == "hello world how are you")
        #expect(store.entries[0].isFinal)
    }

    @Test func consecutiveUtterancesWithinWindowMergeIntoOneBlock() {
        let store = TranscriptStore()
        let t0 = Date()
        store.ingest(result("first thought", isFinal: true, speechFinal: true), from: .them, at: t0)
        store.ingest(result("and it continues", isFinal: true, speechFinal: true), from: .them, at: t0.addingTimeInterval(3))

        #expect(store.entries.count == 1)
        #expect(store.entries[0].text == "first thought and it continues")
        #expect(store.entries[0].isFinal)
    }

    @Test func utterancesBeyondMergeWindowStaySeparate() {
        let store = TranscriptStore()
        let t0 = Date()
        store.ingest(result("first topic", isFinal: true, speechFinal: true), from: .them, at: t0)
        store.ingest(
            result("new topic", isFinal: true, speechFinal: true),
            from: .them,
            at: t0.addingTimeInterval(TranscriptStore.mergeWindow + 1)
        )

        #expect(store.entries.count == 2)
    }

    @Test func backchannelDoesNotBreakTheBlock() {
        let store = TranscriptStore()
        let t0 = Date()
        store.ingest(result("let me introduce myself I lead the data team", isFinal: true, speechFinal: true), from: .you, at: t0)
        store.ingest(result("Okay. Cool. Sounds good.", isFinal: true, speechFinal: true), from: .them, at: t0.addingTimeInterval(2))
        store.ingest(result("and I have been doing this for six years", isFinal: true, speechFinal: true), from: .you, at: t0.addingTimeInterval(4))

        #expect(store.entries.count == 2)
        #expect(store.entries[0].speaker == .you)
        #expect(store.entries[0].text == "let me introduce myself I lead the data team and I have been doing this for six years")
        #expect(store.entries[1].speaker == .them)
        #expect(store.entries[1].text == "Okay. Cool. Sounds good.")
    }

    @Test func substantiveInterjectionStillBreaksTheBlock() {
        let store = TranscriptStore()
        let t0 = Date()
        store.ingest(result("our pricing should have a floor", isFinal: true, speechFinal: true), from: .you, at: t0)
        store.ingest(result("wait I disagree with that number", isFinal: true, speechFinal: true), from: .them, at: t0.addingTimeInterval(2))
        store.ingest(result("let me finish the thought", isFinal: true, speechFinal: true), from: .you, at: t0.addingTimeInterval(4))

        #expect(store.entries.count == 3)
    }

    @Test func backchannelClassifier() {
        #expect(TranscriptStore.isBackchannel("Okay, cool."))
        #expect(TranscriptStore.isBackchannel("Sounds good!"))
        #expect(TranscriptStore.isBackchannel("mhm"))
        #expect(TranscriptStore.isBackchannel("Yeah yeah, got it."))
        #expect(!TranscriptStore.isBackchannel("What about the price?"))
        #expect(!TranscriptStore.isBackchannel("Five million"))
        #expect(!TranscriptStore.isBackchannel("okay but why is that"))
        #expect(!TranscriptStore.isBackchannel(""))
    }

    @Test func otherSpeakerInBetweenPreventsMerge() {
        let store = TranscriptStore()
        let t0 = Date()
        store.ingest(result("question", isFinal: true, speechFinal: true), from: .them, at: t0)
        store.ingest(result("answer", isFinal: true, speechFinal: true), from: .you, at: t0.addingTimeInterval(1))
        store.ingest(result("follow up", isFinal: true, speechFinal: true), from: .them, at: t0.addingTimeInterval(2))

        #expect(store.entries.count == 3)
    }

    @Test func differentParticipantsDoNotMerge() {
        let store = TranscriptStore()
        let t0 = Date()
        store.ingest(result("speaker zero", isFinal: true, speechFinal: true, participant: 0), from: .them, at: t0)
        store.ingest(result("speaker one", isFinal: true, speechFinal: true, participant: 1), from: .them, at: t0.addingTimeInterval(1))

        #expect(store.entries.count == 2)
    }

    @Test func oversizedBlocksStopMerging() {
        let store = TranscriptStore()
        let t0 = Date()
        let long = String(repeating: "word ", count: 200)
        store.ingest(result(long, isFinal: true, speechFinal: true), from: .them, at: t0)
        store.ingest(result("next block", isFinal: true, speechFinal: true), from: .them, at: t0.addingTimeInterval(1))

        #expect(store.entries.count == 2)
    }

    @Test func speakersDoNotMergeEntries() {
        let store = TranscriptStore()
        store.ingest(result("mic speech", isFinal: false, speechFinal: false), from: .you)
        store.ingest(result("meeting speech", isFinal: false, speechFinal: false), from: .them)
        store.ingest(result("mic speech done", isFinal: true, speechFinal: true), from: .you)

        #expect(store.entries.count == 2)
        #expect(store.entries[0].speaker == .you)
        #expect(store.entries[0].text == "mic speech done")
        #expect(store.entries[1].speaker == .them)
        #expect(store.entries[1].text == "meeting speech")
    }

    @Test func emptySpeechFinalClosesUtteranceWithoutNewEntry() {
        let store = TranscriptStore()
        store.ingest(result("closing words", isFinal: true, speechFinal: false), from: .you)
        store.ingest(result("", isFinal: true, speechFinal: true), from: .you)

        #expect(store.entries.count == 1)
        #expect(store.entries[0].text == "closing words")
        #expect(store.entries[0].isFinal)
    }

    @Test func emptyInterimCreatesNoEntry() {
        let store = TranscriptStore()
        store.ingest(result("", isFinal: false, speechFinal: false), from: .them)
        #expect(store.entries.isEmpty)
    }

    @Test func clearResetsUtteranceState() {
        let store = TranscriptStore()
        store.ingest(result("before clear", isFinal: true, speechFinal: false), from: .them)
        store.clear()
        store.ingest(result("after clear", isFinal: true, speechFinal: true), from: .them)

        #expect(store.entries.count == 1)
        #expect(store.entries[0].text == "after clear")
    }

    @Test func markdownContainsSpeakersAndText() {
        let store = TranscriptStore()
        store.ingest(result("question", isFinal: true, speechFinal: true), from: .them)
        store.ingest(result("answer", isFinal: true, speechFinal: true), from: .you)

        let markdown = store.markdown()
        #expect(markdown.contains("**Them**"))
        #expect(markdown.contains("**You**"))
        #expect(markdown.contains("question"))
        #expect(markdown.contains("answer"))
    }
}
