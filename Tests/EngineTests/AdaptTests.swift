import Foundation
import Testing
import Shared
@testable import Engine

private func tempDir() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("adapt-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}
private func span(_ t: String, _ lo: Double, _ hi: Double, conf: Float = 0.8) -> TranscriptSpan {
    TranscriptSpan(text: t, confidence: conf, audioRange: lo...hi, provenance: [.asr])
}
private func day(_ n: Int) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + Double(n) * 86_400) }

@Suite("P6.1 — TrainingPairStore")
struct AdaptStoreTests {
    @Test func accumulatesPairsFromCorrectionRecords() throws {
        let s = try TrainingPairStore(root: tempDir())
        for i in 0..<5 {
            try s.ingest(CorrectionRecord(utteranceID: "u\(i)", original: "cotari", corrected: "Kothari", audioRange: 0.1...0.5, source: "voiceRepair"))
        }
        #expect(s.count == 5)
        #expect(s.all().allSatisfy { $0.corrected == "Kothari" && $0.source == "voiceRepair" })
    }

    @Test func persistsAcrossReopen() throws {
        let root = tempDir()
        let s = try TrainingPairStore(root: root)
        try s.ingest(CorrectionRecord(utteranceID: "u", original: "a", corrected: "b", audioRange: 0...1, source: "dualPath"))
        let s2 = try TrainingPairStore(root: root)
        #expect(s2.count == 1)
        #expect(s2.all().first?.corrected == "b")
    }

    @Test func extractsAudioClipFromUtteranceBuffer() throws {
        let audio = InMemoryUtteranceAudio(sampleRate: 16_000, utterances: ["u1": (0..<32_000).map { Float($0 % 100) / 100 }])
        let s = try TrainingPairStore(root: tempDir(), audio: audio)
        let p = try s.ingest(CorrectionRecord(utteranceID: "u1", original: "x", corrected: "y", audioRange: 0.5...1.0, source: "voiceRepair"))
        let url = try #require(s.clipURL(for: p))
        let wav = try WAVFile.read(url: url)
        #expect(wav.frameCount == 8_000)
        #expect(wav.sampleRate == 16_000)
    }

    @Test func noClipWhenBufferUnavailable() throws {
        let s = try TrainingPairStore(root: tempDir(), audio: InMemoryUtteranceAudio())
        let p = try s.ingest(CorrectionRecord(utteranceID: "gone", original: "x", corrected: "y", audioRange: 0...1, source: "voiceRepair"))
        #expect(p.clipFile == nil)
        #expect(s.count == 1)
    }

    @Test func ignoresNoOpCorrections() throws {
        let s = try TrainingPairStore(root: tempDir())
        try s.ingest(CorrectionRecord(utteranceID: "u", original: "Same", corrected: "same", audioRange: 0...1, source: "voiceRepair"))
        try s.ingest(CorrectionRecord(utteranceID: "u", original: "x", corrected: "   ", audioRange: 0...1, source: "voiceRepair"))
        #expect(s.count == 0)
    }

    @Test func postDictationEditProducesPairWithAudioRange() throws {
        let s = try TrainingPairStore(root: tempDir())
        let spans = [span("send", 0, 0.2), span("it", 0.2, 0.3), span("to", 0.3, 0.4), span("cotari", 0.4, 0.9), span("today", 0.9, 1.2)]
        let pairs = try s.ingestEdit(utteranceID: "u", spans: spans, editedText: "send it to Kothari today")
        #expect(pairs.count == 1)
        #expect(pairs.first?.original == "cotari")
        #expect(pairs.first?.corrected == "Kothari")
        #expect(pairs.first?.audioRange == 0.4...0.9)
        #expect(pairs.first?.source == "postDictationEdit")
    }

    @Test func postDictationEditHandlesMultiWordRuns() throws {
        let s = try TrainingPairStore(root: tempDir())
        let spans = [span("meet", 0, 0.2), span("an", 0.2, 0.3), span("eat", 0.3, 0.5), span("tomorrow", 0.5, 0.9)]
        let pairs = try s.ingestEdit(utteranceID: "u", spans: spans, editedText: "meet Anita tomorrow")
        #expect(pairs.count == 1)
        #expect(pairs.first?.original == "an eat")
        #expect(pairs.first?.corrected == "Anita")
        #expect(pairs.first?.audioRange == 0.2...0.5)
    }

    @Test func unchangedEditProducesNothing() throws {
        let s = try TrainingPairStore(root: tempDir())
        let pairs = try s.ingestEdit(utteranceID: "u", spans: [span("hello", 0, 1), span("world", 1, 2)], editedText: "Hello world")
        #expect(pairs.isEmpty)
    }

    @Test func wordDiffFindsSubstitutionsAndInsertions() {
        let runs = WordDiff.replacedRuns(original: ["a", "b", "c"], edited: ["a", "x", "y", "c"])
        #expect(runs == [WordDiff.Run(originalRange: 1..<2, replacement: "x y")])
        #expect(WordDiff.replacedRuns(original: ["a", "b"], edited: ["a", "b"]).isEmpty)
    }

    @Test func eraseAllClearsPairsAndClips() throws {
        let audio = InMemoryUtteranceAudio(utterances: ["u": [Float](repeating: 0.1, count: 16_000)])
        let s = try TrainingPairStore(root: tempDir(), audio: audio)
        try s.ingest(CorrectionRecord(utteranceID: "u", original: "a", corrected: "b", audioRange: 0...0.5, source: "voiceRepair"))
        try s.eraseAll()
        #expect(s.count == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: s.clipsDirectory.path).isEmpty)
    }
}

@Suite("P6.1 — Learner + LoRA decision")
struct AdaptLearnerTests {
    @Test func biasListLearnsWeightedTermsAndVariants() throws {
        let pairs = (0..<3).map { TrainingPair(utteranceID: "u\($0)", createdAt: day($0), original: "cotari", corrected: "Kothari", audioRange: 0...1, source: "voiceRepair") }
            + [TrainingPair(utteranceID: "z", original: "cube control", corrected: "kubectl", audioRange: 0...1, source: "keyboardEdit")]
        let r = BiasListLearner().train(pairs: pairs, previous: nil)
        #expect(r.feasibility == .trained)
        #expect(r.lexicon.weight(of: "kothari") > r.lexicon.weight(of: "kubectl"))
        #expect(r.lexicon.weight(of: "kothari") > 0.7)
        #expect(r.lexicon.variants["cotari"]?.corrected == "Kothari")
        #expect(r.lexicon.variants["cotari"]?.count == 3)
        #expect(r.lexicon.variants["cube control"]?.corrected == "kubectl")
    }

    @Test func weightSaturatesBelowOne() {
        let pairs = (0..<50).map { TrainingPair(utteranceID: "u\($0)", original: "x", corrected: "Zed", audioRange: 0...1, source: "voiceRepair") }
        let w = BiasListLearner().train(pairs: pairs, previous: nil).lexicon.weight(of: "zed")
        #expect(w > 0.99 && w <= 1)
    }

    @Test func lexiconFeedsBiasingRanker() {
        let lex = BiasListLearner().train(pairs: [TrainingPair(utteranceID: "u", original: "a", corrected: "Kothari", audioRange: 0...1, source: "voiceRepair")], previous: nil).lexicon
        let ranked = Ranker().rank(lex.contextEntries() + [ContextEntry(text: "whatever", source: .recentWords, observedAt: Date(timeIntervalSinceNow: -3600))])
        #expect(ranked.first?.text == "Kothari")
        #expect(ranked.first?.sources == [.corrections])
    }

    @Test func loraStubRecordsInfeasibleDecisionForLab() {
        let r = LoRAAdapterStub().train(pairs: [], previous: nil)
        #expect(r.feasibility == .infeasible)
        let rec = r.labRunRecord(hardware: "test")
        #expect(rec.name == "adapt.train.lora")
        #expect(rec.metricsJSON.contains("infeasible"))
        #expect(rec.metricsJSON.contains("fallback = biasList"))
    }

    @Test func adaptationLoopFallsBackToBiasListAndPersists() throws {
        let root = tempDir()
        let store = try TrainingPairStore(root: root)
        try store.ingest(CorrectionRecord(utteranceID: "u", original: "cotari", corrected: "Kothari", audioRange: 0...1, source: "voiceRepair"))
        let loop = AdaptationLoop(store: store)
        let results = loop.retrain()
        #expect(results.map(\.backend) == ["lora", "biasList"])
        #expect(loop.lexicon.weight(of: "kothari") > 0)
        let reopened = AdaptationLoop(store: store)
        #expect(reopened.lexicon.terms.keys.sorted() == loop.lexicon.terms.keys.sorted() && reopened.lexicon.variants == loop.lexicon.variants)
        #expect(LearnedLexiconSource(loop: reopened).harvest(now: Date()).map(\.text) == ["Kothari"])
    }
}

@Suite("P6.1 — Personal WER")
struct AdaptWERTests {
    @Test func wordErrorsCountsSubInsDel() {
        #expect(PersonalWERTracker.wordErrors(hypothesis: "send to cotari", reference: "send to Kothari").errors == 1)
        #expect(PersonalWERTracker.wordErrors(hypothesis: "a b c", reference: "a c").errors == 1)
        #expect(PersonalWERTracker.wordErrors(hypothesis: "a c", reference: "a b c").errors == 1)
        #expect(PersonalWERTracker.wordErrors(hypothesis: "Hello, world!", reference: "hello world").errors == 0)
    }

    @Test func perDayAggregationAndLabRecord() throws {
        let file = tempDir().appendingPathComponent("wer.json")
        let t = PersonalWERTracker(file: file)
        t.record(hypothesis: "send to cotari", finalText: "send to Kothari", at: day(0))
        t.record(hypothesis: "ok", finalText: "ok", at: day(0))
        t.record(hypothesis: "x y", finalText: "x y", at: day(1))
        #expect(t.wer(on: day(0)) == 0.25)
        #expect(t.wer(on: day(1)) == 0)
        #expect(t.report().count == 2)
        let rec = t.labRunRecord(hardware: "test")
        #expect(rec.name == "personalWER")
        #expect(rec.configJSON.contains("you"))
        #expect(PersonalWERTracker(file: file).report() == t.report())
    }
}

/// Synthetic decoder: mis-hears a fixed set of names unless the regression guard fixes them.
private struct SyntheticReplay {
    let names: [(heard: String, truth: String)] = [("cotari", "Kothari"), ("an eat", "Anita"), ("cube control", "kubectl"), ("sharma", "Sharmaa"), ("rowan", "Rohan")]
    func sentence(_ i: Int) -> (spans: [TranscriptSpan], truth: String) {
        let n = names[i % names.count]
        let hyp = ["please", "ping", n.heard, "now"]
        return (hyp.enumerated().map { span($0.element, Double($0.offset), Double($0.offset + 1), conf: 0.6) }, "please ping \(n.truth) now")
    }
}

@Suite("P6.1/P6.2 — Convergence + regression guard")
struct AdaptConvergenceTests {
    @Test func day30WERBelowDay1OnSyntheticReplay() throws {
        let store = try TrainingPairStore(root: tempDir())
        let loop = AdaptationLoop(store: store, trainers: [BiasListLearner()])
        let wer = PersonalWERTracker()
        let replay = SyntheticReplay()
        for d in 0..<30 {
            let guardStage = RegressionGuard(lexicon: loop.lexicon)
            for u in 0..<4 {
                let (spans, truth) = replay.sentence(d * 4 + u)
                let out = guardStage.apply(spans)
                wer.record(hypothesis: out.map(\.text).joined(separator: " "), finalText: truth, at: day(d))
                try store.ingestEdit(utteranceID: "d\(d)u\(u)", spans: out, editedText: truth, at: day(d))
            }
            loop.retrain()
        }
        let w1 = try #require(wer.wer(on: day(0)))
        let w30 = try #require(wer.wer(on: day(29)))
        #expect(w1 > 0)
        #expect(w30 == 0)
        #expect(w30 < w1)
    }

    @Test func regressionFixtureCorrectedWordNeverReMisheard() {
        let lex = BiasListLearner().train(pairs: [TrainingPair(utteranceID: "u", original: "cotari", corrected: "Kothari", audioRange: 0...1, source: "voiceRepair")], previous: nil).lexicon
        let g = RegressionGuard(lexicon: lex)
        for heard in ["cotari", "Cotari", "kothari", "Kuthary", "cotari,"] {
            let out = g.apply([span(heard, 0, 1)])
            #expect(out.first?.text.hasPrefix("Kothari") == true, "\(heard) should become Kothari")
        }
        #expect(g.apply([span("cotari,", 0, 1)]).first?.text == "Kothari,")
    }

    @Test func guardCarriesConfidenceProvenanceAndAlternate() {
        let lex = BiasListLearner().train(pairs: [TrainingPair(utteranceID: "u", original: "cotari", corrected: "Kothari", audioRange: 0...1, source: "voiceRepair")], previous: nil).lexicon
        let out = RegressionGuard(lexicon: lex).apply([span("cotari", 0.4, 0.9, conf: 0.37)])
        let s = out[0]
        #expect(s.confidence == 0.37)
        #expect(s.audioRange == 0.4...0.9)
        #expect(s.provenance == [.asr, RegressionGuard.stageID])
        #expect(s.alternates.first == Alternate(text: "cotari", score: 0.37, source: .repair))
    }

    @Test func guardLeavesUnrelatedAndCorrectSpansAlone() {
        let lex = BiasListLearner().train(pairs: [TrainingPair(utteranceID: "u", original: "cotari", corrected: "Kothari", audioRange: 0...1, source: "voiceRepair")], previous: nil).lexicon
        let spans = [span("Kothari", 0, 1), span("banana", 1, 2), span("", 2, 2)]
        let out = RegressionGuard(lexicon: lex).apply(spans)
        #expect(out == spans)
    }

    @Test func guardIsEmptyWithoutLexicon() {
        let spans = [span("cotari", 0, 1)]
        #expect(RegressionGuard(lexicon: PersonalLexicon()).apply(spans) == spans)
    }

    @Test func multiWordVariantMatchesExactlyOnly() {
        let lex = BiasListLearner().train(pairs: [TrainingPair(utteranceID: "u", original: "cube control", corrected: "kubectl", audioRange: 0...1, source: "voiceRepair")], previous: nil).lexicon
        let g = RegressionGuard(lexicon: lex)
        #expect(g.correction(for: "Cube control") == "kubectl")
        #expect(g.correction(for: "cube") == nil)
    }
}

@Suite("P6.2 — Learned lexicon")
struct AdaptLexiconTests {
    @Test func pronunciationCaptureStoresAudioAndPair() throws {
        let root = tempDir()
        let store = try TrainingPairStore(root: root)
        let cap = try PronunciationCapture(directory: root.appendingPathComponent("pron"), store: store)
        let e = try cap.capture(word: "Kothari", samples: [Float](repeating: 0.2, count: 8_000), heard: "cotari")
        #expect(e.durationSec == 0.5)
        #expect(try WAVFile.read(url: cap.directory.appendingPathComponent(e.clipFile)).frameCount == 8_000)
        #expect(cap.entries(for: "kothari").count == 1)
        #expect(store.all().first?.source == "trainByVoice")
        #expect(store.all().first?.corrected == "Kothari")
        #expect(try PronunciationCapture(directory: cap.directory).entries.count == 1)
    }

    @Test func pronunciationCaptureRejectsEmpty() throws {
        let cap = try PronunciationCapture(directory: tempDir())
        #expect(throws: PronunciationCapture.CaptureError.self) { try cap.capture(word: " ", samples: [0.1]) }
        #expect(throws: PronunciationCapture.CaptureError.self) { try cap.capture(word: "x", samples: []) }
    }

    @Test func toastShownOncePerWordAndPersisted() throws {
        let file = tempDir().appendingPathComponent("toasts.json")
        let m = RememberToastModel(file: file)
        let t = try #require(m.toast(forLearned: "Kothari"))
        #expect(t.message == "I'll remember \u{201C}Kothari\u{201D}")
        #expect(m.toast(forLearned: "Kothari") == nil)
        #expect(m.toast(forLearned: "kothari ") == nil)
        #expect(m.toast(forLearned: "Anita") != nil)
        #expect(RememberToastModel(file: file).toast(forLearned: "KOTHARI") == nil)
        #expect(m.toast(forLearned: "") == nil)
    }

    @Test func toastNotRepeatedAcrossRetrains() throws {
        let store = try TrainingPairStore(root: tempDir())
        let loop = AdaptationLoop(store: store, trainers: [BiasListLearner()])
        let toasts = RememberToastModel()
        var shown: [String] = []
        for i in 0..<5 {
            try store.ingest(CorrectionRecord(utteranceID: "u\(i)", original: "cotari", corrected: "Kothari", audioRange: 0...1, source: "voiceRepair"))
            loop.retrain()
            for term in loop.lexicon.terms.values { if let t = toasts.toast(forLearned: term.text) { shown.append(t.word) } }
        }
        #expect(shown == ["Kothari"])
    }
}

/// The text-corruption bug: the zero-edit tracker reads the *whole focused field* back, so the
/// "edited" side of a post-dictation edit can be an entire document. Learning from that taught the
/// lexicon `heard -> <document>`, and `RegressionGuard` then substituted the document for a real
/// word on a later utterance — dictation that came out completely unrelated to the audio.
@Suite("Lexicon sanity — a correction is a respelling, never a document")
struct LexiconSanityTests {
    private let document = """
    Dear Bob, thanks for the note about the quarterly numbers. I have attached the deck and the \
    revised forecast, and I will follow up on Thursday once the finance team has signed off on it.
    """

    @Test func wholeFieldReadbackTeachesNothing() throws {
        let store = try TrainingPairStore(root: tempDir())
        let spans = [span("the", 0, 0.2), span("quick", 0.2, 0.4), span("brown", 0.4, 0.6), span("fox", 0.6, 0.8)]
        let pairs = try store.ingestEdit(utteranceID: "u", spans: spans, editedText: document + " the quick brown fox")
        #expect(pairs.isEmpty)
        #expect(store.count == 0)
    }

    @Test func realWordLevelEditIsStillLearned() throws {
        let store = try TrainingPairStore(root: tempDir())
        let spans = [span("send", 0, 0.2), span("it", 0.2, 0.3), span("to", 0.3, 0.4), span("cotari", 0.4, 0.9)]
        let pairs = try store.ingestEdit(utteranceID: "u", spans: spans, editedText: "send it to Kothari")
        #expect(pairs.map(\.corrected) == ["Kothari"])
    }

    @Test func implausiblePairIsRefusedByTheStore() throws {
        let store = try TrainingPairStore(root: tempDir())
        try store.add(TrainingPair(utteranceID: "u", original: "the", corrected: document, audioRange: 0...1, source: "postDictationEdit"))
        #expect(store.count == 0)
    }

    @Test func guardPassesThroughAnAlreadyPoisonedLexicon() {
        var lex = PersonalLexicon()
        lex.variants["the"] = .init(heard: "the", corrected: document, count: 3)
        let spans = [span("The", 0, 0.2), span("quick", 0.2, 0.4), span("fox", 0.4, 0.6)]
        // Neither the exact variant nor the phonetic list may substitute a paragraph for "The".
        #expect(RegressionGuard(lexicon: lex).correction(for: "The") == nil)
        #expect(RegressionGuard(lexicon: lex).apply(spans) == spans)
        #expect(RegressionGuard(lexicon: lex).apply([span("thee", 0, 0.2)]).first?.text == "thee")
    }

    @Test func plausibilityRulesAreShaped() {
        #expect(LexiconSanity.isPlausibleCorrection(heard: "cotari", corrected: "Kothari"))
        #expect(LexiconSanity.isPlausibleCorrection(heard: "an eat", corrected: "Anita"))
        #expect(LexiconSanity.isPlausibleCorrection(heard: "cube control", corrected: "kubectl"))
        #expect(!LexiconSanity.isPlausibleCorrection(heard: "the", corrected: document))
        #expect(!LexiconSanity.isPlausibleCorrection(heard: "fox", corrected: ""))
        #expect(LexiconSanity.isPlausibleEdit(of: "the quick brown fox", edited: "the quick brown fix"))
        #expect(!LexiconSanity.isPlausibleEdit(of: "the quick brown fox", edited: document))
    }
}
