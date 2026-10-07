import Engine
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// C1 — re-dictation as a correction: the three examples from the 10-06 session learn an alias,
/// unrelated or late or other-app landings do not, the alias is visible through the learned-lexicon
/// query (`PersonalLexicon.variants` / `alias(forHeard:)` / `LearnedLexiconSource`), and the undo
/// hook stores a negative alias that blocks the pair everywhere.
@Suite("C1 re-dictation learner")
struct RedictationLearnerTests {
    private static let app = "com.openai.chat"
    private static let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    private static func service() throws -> AdaptationService {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("c1-redictation-\(UUID())")
        return try AdaptationService(root: root, werFile: root.appendingPathComponent("wer.json"),
                                     toastFile: root.appendingPathComponent("toasts.json"))
    }

    private static func pair(_ first: String, _ second: String, gap: TimeInterval = 8, secondApp: String = app,
                             fieldText: String? = nil) throws -> (AdaptationService, [RedictationLearner.Alias]) {
        let service = try service()
        let learner = RedictationLearner(adaptation: service)
        #expect(learner.observe(landing: first, app: app, at: t0).isEmpty)
        let learned = learner.observe(landing: second, app: secondApp, at: t0.addingTimeInterval(gap), fieldText: fieldText)
        return (service, learned)
    }

    // MARK: Learns

    @Test func subVarianceBecomesSubagents() throws {
        let (service, learned) = try Self.pair("fan out sub variance", "fan out subagents")
        #expect(learned == [.init(heard: "sub variance", written: "subagents")])
        #expect(service.loop.lexicon.alias(forHeard: "sub variance") == "subagents")
    }

    @Test func aSixteenZBecomesA16zWhenTheSecondAttemptWasTyped() throws {
        let (service, learned) = try Self.pair("a sixteen z", "a16z", gap: 12)
        #expect(learned == [.init(heard: "a sixteen z", written: "a16z")])
        #expect(service.loop.lexicon.variants["a sixteen z"]?.corrected == "a16z")
        #expect(service.loop.lexicon.terms["a16z"] != nil)
    }

    @Test func faceTwoBecomesPhaseTwo() throws {
        let (service, learned) = try Self.pair("we are starting face two next week", "we are starting phase two next week")
        #expect(learned == [.init(heard: "face", written: "phase")])
        #expect(service.loop.lexicon.variants["face"]?.corrected == "phase")
    }

    // MARK: Does not learn

    @Test func unrelatedConsecutiveDictationsLearnNothing() throws {
        let (service, learned) = try Self.pair("please send me the report by friday", "the meeting moved to noon tomorrow")
        #expect(learned.isEmpty)
        #expect(service.loop.lexicon.variants.isEmpty && service.store.count == 0)
    }

    @Test func fortySecondGapLearnsNothing() throws {
        let (service, learned) = try Self.pair("fan out sub variance", "fan out subagents", gap: 40)
        #expect(learned.isEmpty)
        #expect(service.store.count == 0)
    }

    @Test func anotherAppLearnsNothing() throws {
        let (_, learned) = try Self.pair("fan out sub variance", "fan out subagents", secondApp: "com.apple.Notes")
        #expect(learned.isEmpty)
    }

    @Test func earlierTextStillInTheFieldIsAnAdditionNotARedictation() throws {
        let (_, learned) = try Self.pair("fan out sub variance", "fan out subagents",
                                         fieldText: "Fan out sub variance. Fan out subagents")
        #expect(learned.isEmpty)
        // The readback showing only the new text confirms the replacement.
        let (_, replaced) = try Self.pair("fan out sub variance", "fan out subagents", fieldText: "Fan out subagents")
        #expect(replaced.count == 1)
    }

    @Test func pronounSwapAndIdenticalRepeatAreNotRespellings() throws {
        let (_, swapped) = try Self.pair("send it to him", "send it to them")
        #expect(swapped.isEmpty)
        let (_, same) = try Self.pair("phase two", "Phase two.")
        #expect(same.isEmpty)
    }

    @Test func fieldReadbackClosureIsConsultedWhenNoFieldTextIsPassed() throws {
        let service = try Self.service()
        let learner = RedictationLearner(adaptation: service, fieldReadback: { "fan out sub variance fan out subagents" })
        learner.observe(landing: "fan out sub variance", app: Self.app, at: Self.t0)
        #expect(learner.observe(landing: "fan out subagents", app: Self.app, at: Self.t0.addingTimeInterval(5)).isEmpty)
        #expect(learner.lastLanding?.text == "fan out subagents")
        learner.reset()
        #expect(learner.lastLanding == nil)
    }

    // MARK: Visible where the matcher reads

    @Test func aliasIsVisibleThroughTheLearnedLexiconQuery() throws {
        let (service, _) = try Self.pair("we are starting face two", "we are starting phase two")
        let lexicon = service.loop.lexicon
        #expect(lexicon.alias(forHeard: "Face") == "phase")
        #expect(lexicon.variants["face"]?.corrected == "phase" && lexicon.variants["face"]?.count == 1)
        let entries = LearnedLexiconSource(loop: service.loop).harvest(now: Self.t0)
        #expect(entries.contains { $0.text == "phase" && $0.source == .corrections })
        #expect(RegressionGuard(lexicon: lexicon).correction(for: "face") == "phase")
        // Persisted: a fresh loop over the same store sees the same alias.
        let reopened = AdaptationLoop(store: service.store)
        #expect(reopened.lexicon.alias(forHeard: "face") == "phase")
    }

    @Test func storedPairCarriesTheRedictationSource() throws {
        let (service, _) = try Self.pair("fan out sub variance", "fan out subagents")
        let stored = try #require(service.store.all().first)
        #expect(stored.source == TrainingPair.redictationSource)
        #expect(stored.original == "sub variance" && stored.corrected == "subagents")
    }

    // MARK: Undo

    @Test func undoCorrectionStoresANegativeAliasThatBlocksThePair() throws {
        let (service, _) = try Self.pair("we are starting face two", "we are starting phase two")
        let learner = RedictationLearner(adaptation: service)
        #expect(learner.undoCorrection(heard: "face", written: "phase", app: Self.app, at: Self.t0.addingTimeInterval(20)))
        let lexicon = service.loop.lexicon
        #expect(lexicon.isBlocked(heard: "Face", written: "PHASE"))
        #expect(lexicon.variants["face"] == nil)
        #expect(lexicon.alias(forHeard: "face") == nil)
        #expect(RegressionGuard(lexicon: lexicon).correction(for: "face") == nil)
        #expect(service.store.all().contains { $0.isNegativeAlias && $0.original == "face" && $0.corrected == "phase" })
        // A later re-dictation of the same pair is refused; the negative survives a retrain.
        learner.observe(landing: "we are starting face two", app: Self.app, at: Self.t0.addingTimeInterval(60))
        #expect(learner.observe(landing: "we are starting phase two", app: Self.app, at: Self.t0.addingTimeInterval(65)).isEmpty)
        #expect(service.retrain().variants["face"] == nil)
    }

    @Test func undoRefusesEmptyOrIdenticalInput() throws {
        let learner = RedictationLearner(adaptation: try Self.service())
        #expect(!learner.undoCorrection(heard: "", written: "phase"))
        #expect(!learner.undoCorrection(heard: "phase", written: "Phase"))
    }

    @Test func negativeBlocksAPhoneticCollisionFromAnotherHeardForm() throws {
        let positive = (0..<2).map {
            TrainingPair(utteranceID: "u\($0)", original: "fase", corrected: "phase", audioRange: 0...1, source: "voiceRepair")
        }
        let without = BiasListLearner().train(pairs: positive, previous: nil).lexicon
        #expect(RegressionGuard(lexicon: without).correction(for: "face") == "phase")
        let negative = TrainingPair(utteranceID: "n", original: "face", corrected: "phase", audioRange: 0...0,
                                    source: TrainingPair.negativeAliasSource)
        let with = BiasListLearner().train(pairs: positive + [negative], previous: nil).lexicon
        #expect(with.isBlocked(heard: "face", written: "phase"))
        #expect(with.negatives == ["face": ["phase"]])
        #expect(RegressionGuard(lexicon: with).correction(for: "face") == nil)
        #expect(RegressionGuard(lexicon: with).correction(for: "fase") == "phase")
    }

    @Test func lexiconJSONWithoutNegativesStillDecodes() throws {
        let json = #"{"terms":{},"variants":{},"trainedAt":0,"pairCount":0}"#
        let lexicon = try JSONDecoder().decode(PersonalLexicon.self, from: Data(json.utf8))
        #expect(lexicon.negatives.isEmpty)
    }

    // MARK: Alignment helper

    @Test func digitsAreSpelledOutForThePhoneticKey() {
        #expect(RedictationAlignment.spellOutDigits("a16z") == ["a", "sixteen", "z"])
        #expect(RedictationAlignment.numberWords(205) == "two hundred five")
        #expect(RedictationAlignment.numberWords(2024) == "two zero two four")
        #expect(RedictationAlignment.phoneticKey("a16z") == RedictationAlignment.phoneticKey(words: ["a", "sixteen", "z"]))
        #expect(RedictationAlignment.phoneticKey("face") == RedictationAlignment.phoneticKey("phase"))
        #expect(RedictationAlignment.words("Fan out, \u{201C}a16z\u{201D}!") == ["Fan", "out", "a16z"])
    }

    @Test func regionsAreTheReplacedRunsBetweenAnchors() {
        let regions = RedictationAlignment.regions(heard: ["fan", "out", "sub", "variance"], written: ["fan", "out", "subagents"])
        #expect(regions.count == 1)
        #expect(regions.first?.heard == "sub variance" && regions.first?.written == "subagents")
        #expect((regions.first?.similarity ?? 0) >= 0.45)
        #expect(RedictationAlignment.regions(heard: ["phase", "two"], written: ["phase", "two", "starts"]).isEmpty)
    }
}
