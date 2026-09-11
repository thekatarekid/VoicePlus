import Engine
import Foundation
import Pipeline
import Shared
import Testing
@testable import VoicePlusApp

/// R4.3 — Dictionary and learning UI.
///
/// The item's whole point is that a bad learned correction can be undone and *actually* stop
/// influencing recognition, not just disappear from a list. `removalStopsInfluenceOnTheNextUtterance`
/// proves that end to end: train a mishearing, run it through the real `RegressionGuardStage` and
/// see it get corrected, forget the entry through `LearnedDictionaryViewModel`, then run the exact
/// same utterance through the exact same stage again and see the correction gone — no restart, no
/// retrain, no cache to clear.
@Suite("R4.3 — Dictionary and learning UI")
@MainActor
struct DictionaryLearningUITests {
    static func adaptationService() throws -> AdaptationService {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("r43-adapt-\(UUID())")
        return try AdaptationService(root: root,
                                     werFile: root.appendingPathComponent("wer.json"),
                                     toastFile: root.appendingPathComponent("toasts.json"))
    }

    /// A hypothetical "next utterance": the decoder mis-hears the same word again.
    static func mishearingSpans(_ heard: String) -> [TranscriptSpan] {
        [
            TranscriptSpan(text: "email", confidence: 0.9, audioRange: 0...0.3),
            TranscriptSpan(text: heard, confidence: 0.6, audioRange: 0.3...0.7),
            TranscriptSpan(text: "about", confidence: 0.9, audioRange: 0.7...1.0),
        ]
    }

    // MARK: 1 — removal takes effect on the very next utterance

    @Test func removalStopsInfluenceOnTheNextUtterance() async throws {
        let service = try Self.adaptationService()
        let day1 = Date(timeIntervalSince1970: 1_700_000_000)

        // Train: the engine keeps mis-hearing "Kothari" as "kotari"; every repair is a correction.
        for i in 0..<4 {
            service.ingest(CorrectionRecord(utteranceID: "u\(i)", createdAt: day1,
                                            original: "email kotari about the deck",
                                            corrected: "email Kothari about the deck",
                                            audioRange: 0...1.2, source: "voiceRepair"))
        }
        service.retrain()
        #expect(service.loop.lexicon.weight(of: "kothari") > 0, "the correction was learned")

        // Prove influence: the exact pipeline stage `AppContainer` wires as `adapt.lexicon`
        // (`RegressionGuardStage`, re-reading `service.loop.lexicon` fresh every call — the same
        // live property the Dictionary tab's forget button mutates) rewrites the mishearing.
        let guardStage = RegressionGuardStage(lexicon: { service.loop.lexicon })
        let before = try await guardStage.process(Self.mishearingSpans("kotari"), context: StageContext())
        #expect(before.map(\.text).contains("Kothari"), "learned correction influences recognition before removal")

        // Removal, through the exact surface the Dictionary tab uses.
        let dictionary = LearnedDictionaryViewModel(loop: service.loop, store: service.store)
        let entry = try #require(dictionary.entries.first { $0.spelling.caseInsensitiveCompare("Kothari") == .orderedSame })
        #expect(entry.heardAs.map { $0.lowercased() }.contains("kotari"))
        dictionary.forget(entry)
        #expect(dictionary.entries.contains { $0.spelling.caseInsensitiveCompare("Kothari") == .orderedSame } == false,
                "the row disappears immediately")

        // Prove the influence is gone on the very next utterance: same stage, same construction,
        // no retrain, no relaunch — it re-reads `service.loop.lexicon`, which forget() mutated.
        let after = try await guardStage.process(Self.mishearingSpans("kotari"), context: StageContext())
        #expect(after.map(\.text) == ["email", "kotari", "about"],
                "the next utterance is no longer rewritten: \(after.map(\.text))")
        #expect(service.loop.lexicon.weight(of: "kothari") == 0, "the term itself is gone from the live lexicon")

        // And it stays gone: a later retrain must not resurrect it from surviving training pairs.
        service.ingest(CorrectionRecord(utteranceID: "unrelated", createdAt: day1, original: "hello", corrected: "hello",
                                        audioRange: 0...0.5, source: "voiceRepair")) // no-op correction, just triggers dirty
        service.retrain()
        #expect(service.loop.lexicon.weight(of: "kothari") == 0, "retrain does not relearn a forgotten entry")
    }

    // MARK: 2 — the list shows spelling, heard-as and origin

    @Test func listShowsSpellingHeardAsAndOrigin() throws {
        let service = try Self.adaptationService()
        service.ingest(CorrectionRecord(utteranceID: "u0", createdAt: Date(), original: "musely build",
                                        corrected: "Muesli build", audioRange: 0...1, source: "postDictationEdit"))
        service.retrain()

        let dictionary = LearnedDictionaryViewModel(loop: service.loop, store: service.store)
        let entry = try #require(dictionary.entries.first { $0.spelling.caseInsensitiveCompare("Muesli") == .orderedSame })
        #expect(entry.heardAs.map { $0.lowercased() } == ["musely"])
        #expect(entry.origin == "post-dictation edit")
        #expect(entry.corrections >= 1)
    }

    @Test func emptyLexiconRendersAnEmptyList() {
        let dictionary = LearnedDictionaryViewModel(loop: nil, store: nil)
        #expect(dictionary.entries.isEmpty)
        #expect(dictionary.filtered.isEmpty)
    }

    // MARK: 3 — Benchmark tab counters, including the empty state

    @Test func benchmarkRendersR41bCounters() throws {
        let benchmark = BenchmarkViewModel(report: BenchmarkViewModel.lastMeasured)
        #expect(benchmark.hasData)
        #expect(benchmark.rows.count == 2)
        let without = try #require(benchmark.rows.first { $0.arm.contains("without") })
        #expect(without.recallText == "0.600 (6/10)")
        #expect(without.falseInsertions == 2)
        let with = try #require(benchmark.rows.first { $0.arm.contains("with the ranked list") })
        #expect(with.recallText == "0.800 (8/10)")
        #expect(with.falseInsertions == 6)
        #expect(benchmark.recallGainText?.contains("+20.0") == true)
        #expect(benchmark.passLabel != nil)
    }

    @Test func benchmarkRendersTheEmptyState() {
        let benchmark = BenchmarkViewModel(report: nil)
        #expect(!benchmark.hasData)
        #expect(benchmark.rows.isEmpty)
        #expect(benchmark.corpusLabel == nil)
        #expect(benchmark.recallGainText == nil)
        #expect(benchmark.passLabel == nil)
    }
}
