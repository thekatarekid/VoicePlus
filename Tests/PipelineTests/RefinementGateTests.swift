import Foundation
import Shared
import Testing
@testable import Pipeline

/// R5.3 — the gate policy: four conditions, each on its own and in combination, plus the three
/// modes and the one thing a mode may not do (promise a pass that is not installed).
///
/// No model, no weights, no audio: the two conditions that need the ranked context list take it as
/// a count (`ContextGate` in `Engine/Biasing` produces it; `PipelineTests` cannot see `Engine`).
/// The corpus measurement of this same policy — gate recall and precision against real Parakeet and
/// real Qwen output — is `Tests/AppTests/GateRecallCorpusTests.swift`.
@Suite("Refinement gate policy (R5.3)")
struct RefinementGateTests {

    /// A confident, English, short, near-miss-free segment: nothing fires. Every test below is this
    /// baseline plus exactly one changed signal, so a firing gate can only be the condition under
    /// test.
    static func quiet(_ text: String = "the quick brown fox jumps over the lazy dog") -> RefinementGateSignals {
        RefinementGateSignals(hypothesis: text, confidence: 0.92, nearMisses: 0, promptTerms: 40,
                              segmentSeconds: 5.6, languageHint: "en-IN")
    }

    // MARK: Baseline

    @Test func autoDoesNothingWhenNoConditionFires() {
        let decision = RefinementGate().decide(Self.quiet())
        #expect(decision.shouldRefine == false)
        #expect(decision.reason == .noConditionMet)
        #expect(decision.conditions.isEmpty)
        #expect(decision.mode == .auto)
    }

    // MARK: Condition 1 — streaming uncertainty

    @Test func lowConfidenceAloneOpensTheGate() {
        var signals = Self.quiet()
        signals.confidence = 0.41
        let decision = RefinementGate().decide(signals)
        #expect(decision.shouldRefine)
        #expect(decision.reason == .lowConfidence)
        #expect(decision.conditions == [.lowConfidence])
    }

    @Test func confidenceExactlyAtTheThresholdCounts() {
        var signals = Self.quiet()
        signals.confidence = RefinementGateSettings.default.lowConfidence
        #expect(RefinementGate().decide(signals).shouldRefine)
        signals.confidence = RefinementGateSettings.default.lowConfidence + 0.01
        #expect(RefinementGate().decide(signals).shouldRefine == false)
    }

    @Test func theConfidenceThresholdIsTheOneTheRestOfThePipelineUses() {
        // Not a magic number: the same line stages use to mean "flag, do not rewrite".
        #expect(RefinementGateSettings.default.lowConfidence == TranscriptSpan.lowConfidenceThreshold)
    }

    /// Absent confidence is *marked*, not assumed (V3 §5.3). By default it does not open the gate:
    /// a signal nobody reported cannot be evidence of uncertainty.
    @Test func unknownConfidenceIsMarkedAndDoesNotFireByDefault() {
        var signals = Self.quiet()
        signals.confidence = nil
        let decision = RefinementGate().decide(signals)
        #expect(decision.shouldRefine == false)
        #expect(decision.confidenceUnavailable)
        #expect(decision.summary.contains("conf=n/a"))

        let cautious = RefinementGate(settings: RefinementGateSettings(treatsUnknownConfidenceAsUncertain: true))
        #expect(cautious.decide(signals).reason == .lowConfidence)
    }

    // MARK: Condition 2 — context near miss (phonetic)

    @Test func oneNearMissAloneOpensTheGate() {
        var signals = Self.quiet()
        signals.nearMisses = 1
        let decision = RefinementGate().decide(signals)
        #expect(decision.shouldRefine)
        #expect(decision.reason == .contextNearMiss)
        #expect(decision.conditions == [.contextNearMiss])
    }

    /// A near miss against a term the prompt will not carry is not a reason to run the pass — the
    /// model would never see the word that was supposed to fix it.
    @Test func aNearMissWithoutAPromptDoesNotCount() {
        var signals = Self.quiet()
        signals.nearMisses = 3
        signals.promptTerms = 0
        #expect(RefinementGate().decide(signals).shouldRefine == false)

        let lenient = RefinementGate(settings: RefinementGateSettings(requiresPromptForNearMiss: false))
        #expect(lenient.decide(signals).reason == .contextNearMiss)
    }

    @Test func theNearMissCountIsTunable() {
        var signals = Self.quiet()
        signals.nearMisses = 1
        let strict = RefinementGate(settings: RefinementGateSettings(minNearMisses: 2))
        #expect(strict.decide(signals).shouldRefine == false)
        signals.nearMisses = 2
        #expect(strict.decide(signals).reason == .contextNearMiss)
    }

    @Test func theNearMissThresholdsMirrorTheContextGateOnesTheCountComesFrom() {
        // `ContextGate.Thresholds` defaults, restated here because the count this policy reads is
        // computed with them and the two must not drift (R4.1b: 0.55 similarity, 4 characters).
        #expect(RefinementGateSettings.default.nearMissMinSimilarity == 0.55)
        #expect(RefinementGateSettings.default.nearMissMinWordCharacters == 4)
    }

    // MARK: Condition 3 — non-English

    @Test func aNonLatinScriptOpensTheGate() {
        // The exact Devanagari regression Qwen shipped with before c6c8887.
        var signals = Self.quiet("दकवैक ब्राउन फॉक्स जम्सवर्धा लेजे डॉग")
        signals.languageHint = nil
        let decision = RefinementGate().decide(signals)
        #expect(decision.shouldRefine)
        #expect(decision.reason == .nonEnglish)
    }

    @Test func aLanguageHintThatIsNotEnglishOpensTheGate() {
        var signals = Self.quiet()
        signals.languageHint = "hi-IN"
        #expect(RefinementGate().decide(signals).reason == .nonEnglish)
        for english in ["en", "en-US", "en_GB", "EN-in", "eng"] {
            signals.languageHint = english
            #expect(RefinementGate().decide(signals).shouldRefine == false, "\(english) is English")
        }
    }

    /// A missing hint is not evidence of English, and it is not evidence against it either: with no
    /// hint the decision rests on the script alone.
    /// The hint can be switched off for a caller whose locale is not a per-utterance judgement.
    @Test func theLanguageHintCanBeIgnored() {
        var signals = Self.quiet()
        signals.languageHint = "fr-FR"
        #expect(RefinementGate().decide(signals).reason == .nonEnglish)
        let ignoring = RefinementGate(settings: RefinementGateSettings(honorsLanguageHint: false))
        #expect(ignoring.decide(signals).shouldRefine == false)
        // …and the script test still works with the hint ignored.
        signals.hypothesis = "पूरा वाक्य देवनागरी में लिखा"
        #expect(ignoring.decide(signals).reason == .nonEnglish)
    }

    @Test func aMissingHintDecidesNothingByItself() {
        var signals = Self.quiet()
        signals.languageHint = nil
        #expect(RefinementGate().decide(signals).shouldRefine == false)
    }

    @Test func oneStrayNonLatinLetterIsNotALanguage() {
        var signals = Self.quiet("the quick brown fox jumps over the lazy dog in Mumbaī")
        signals.languageHint = nil
        #expect(RefinementGate().decide(signals).shouldRefine == false)
        // …and accented Latin — French, Spanish, Vietnamese — is Latin script, so the script test
        // cannot see it. That is the documented blind spot: only a hint can catch those.
        signals.hypothesis = "où est passé le renard brun qui sautait par-dessus le chien paresseux"
        #expect(RefinementGate().decide(signals).shouldRefine == false)
        signals.languageHint = "fr-FR"
        #expect(RefinementGate().decide(signals).reason == .nonEnglish)
    }

    @Test func tooFewLettersToJudgeAScript() {
        var signals = Self.quiet("हाँ")
        signals.languageHint = nil
        #expect(RefinementGate().decide(signals).shouldRefine == false,
                "three letters is not enough evidence of a language")
        #expect(RefinementGate.letterCounts("हाँ").letters < RefinementGateSettings.default.nonLatinMinLetters)
    }

    @Test func theScriptTestCountsLettersNotCharacters() {
        let (letters, nonLatin) = RefinementGate.letterCounts("abc 123 — क् 東")
        #expect(letters == 5)
        #expect(nonLatin == 2)
        #expect(RefinementGate.letterCounts("Voilà, café — Łódź").nonLatin == 0)
    }

    // MARK: Condition 4 — long segment

    @Test func aLongSegmentOpensTheGateOnDurationAlone() {
        var signals = Self.quiet()
        signals.segmentSeconds = RefinementGateSettings.default.longSegmentSeconds
        let decision = RefinementGate().decide(signals)
        #expect(decision.shouldRefine)
        #expect(decision.reason == .longSegment)
        signals.segmentSeconds = RefinementGateSettings.default.longSegmentSeconds - 0.1
        #expect(RefinementGate().decide(signals).shouldRefine == false)
    }

    @Test func aLongSegmentOpensTheGateOnWordCountWhenThereIsNoAudioRange() {
        let words = Array(repeating: "word", count: RefinementGateSettings.default.longSegmentWords)
        var signals = Self.quiet(words.joined(separator: " "))
        signals.segmentSeconds = nil
        let decision = RefinementGate().decide(signals)
        #expect(decision.reason == .longSegment)
        #expect(decision.words == RefinementGateSettings.default.longSegmentWords)

        signals.hypothesis = words.dropLast().joined(separator: " ")
        #expect(RefinementGate().decide(signals).shouldRefine == false)
    }

    @Test func noCorpusUtteranceIsLongEnoughToTripTheDurationThreshold() {
        // The threshold was set out of corpus range on purpose (see `longSegmentSeconds`): the
        // real-room corpus is 3.6–9.3 s, one sentence each.
        #expect(RefinementGateSettings.default.longSegmentSeconds > 9.4)
    }

    // MARK: All four together

    @Test func everyConditionFiringIsReportedAndTheFirstOneDecides() {
        let signals = RefinementGateSignals(
            hypothesis: (["ये"] + Array(repeating: "शब्द", count: 40)).joined(separator: " "),
            confidence: 0.2, nearMisses: 2, promptTerms: 80, segmentSeconds: 30,
            languageHint: "hi-IN")
        let decision = RefinementGate().decide(signals)
        #expect(decision.shouldRefine)
        #expect(decision.conditions == [.lowConfidence, .contextNearMiss, .nonEnglish, .longSegment])
        #expect(decision.reason == .lowConfidence)
        #expect(decision.summary.contains("fired=lowConfidence+contextNearMiss+nonEnglish+longSegment"))
    }

    @Test func conditionsAreIndependentOfOneAnother() {
        // Each condition alone, with the other three quiet: four gates, four reasons, no crosstalk.
        var uncertain = Self.quiet(); uncertain.confidence = 0.1
        var nearMiss = Self.quiet(); nearMiss.nearMisses = 1
        var foreign = Self.quiet("पूरा वाक्य देवनागरी में"); foreign.languageHint = nil
        var long = Self.quiet(); long.segmentSeconds = 40
        let gate = RefinementGate()
        #expect(gate.conditions(uncertain) == [.lowConfidence])
        #expect(gate.conditions(nearMiss) == [.contextNearMiss])
        #expect(gate.conditions(foreign) == [.nonEnglish])
        #expect(gate.conditions(long) == [.longSegment])
        #expect(gate.conditions(Self.quiet()).isEmpty)
    }

    @Test func everyConditionCanBeTurnedOffByItsSettings() {
        let signals = RefinementGateSignals(
            hypothesis: (["ये"] + Array(repeating: "शब्द", count: 40)).joined(separator: " "),
            confidence: 0.2, nearMisses: 2, promptTerms: 80, segmentSeconds: 30,
            languageHint: "hi-IN")
        let gate = RefinementGate(settings: .noConditions)
        #expect(gate.conditions(signals).isEmpty)
        #expect(gate.decide(signals).reason == .noConditionMet)
    }

    // MARK: Modes

    @Test func neverMeansNeverEvenWhenEveryConditionFires() {
        let signals = RefinementGateSignals(hypothesis: "देवनागरी में लंबा वाक्य", confidence: 0.1,
                                            nearMisses: 5, promptTerms: 100, segmentSeconds: 60)
        let decision = RefinementGate(mode: .never).decide(signals)
        #expect(decision.shouldRefine == false)
        #expect(decision.reason == .modeNever)
        #expect(decision.conditions.isEmpty, "Never does not even evaluate the policy")
    }

    @Test func alwaysMeansAlwaysEvenWhenNoConditionFires() {
        let decision = RefinementGate(mode: .always).decide(Self.quiet())
        #expect(decision.shouldRefine)
        #expect(decision.reason == .modeAlways)
    }

    /// V3 §9.7 — nothing is labelled available that is not. Availability outranks the mode, so
    /// "Always" on a Mac without the weights still refines nothing and says why.
    @Test func availabilityOutranksEveryMode() {
        for mode in RefinementMode.allCases {
            var signals = Self.quiet()
            signals.refinementAvailable = false
            signals.confidence = 0.1
            let decision = RefinementGate(mode: mode).decide(signals)
            #expect(decision.shouldRefine == false)
            #expect(decision.reason == .unavailable, "\(mode) claimed a pass that cannot run")
        }
    }

    // MARK: Signals from spans

    @Test func signalsFromSpansReadTheSegmentTheWayTheStageSeesIt() {
        let spans = [
            TranscriptSpan(text: "send the deck", confidence: 0.8, audioRange: 0...1.5),
            TranscriptSpan(text: "to Prea", confidence: 0.4, audioRange: 1.5...3),
        ]
        let signals = RefinementGateSignals(spans: spans, nearMisses: 1, promptTerms: 12)
        #expect(signals.hypothesis == "send the deck to Prea")
        #expect(signals.wordCount == 5)
        #expect(abs((signals.confidence ?? 0) - 0.6) < 1e-6)
        #expect(abs((signals.segmentSeconds ?? 0) - 3) < 1e-6)
    }

    @Test func signalsFromNoSpansReportNothingRatherThanZero() {
        let signals = RefinementGateSignals(spans: [])
        #expect(signals.confidence == nil)
        #expect(signals.segmentSeconds == nil)
        #expect(RefinementGate().decide(signals).confidenceUnavailable)
    }

    // MARK: The decision is loggable, and it reaches the stage

    @Test func theSummaryCarriesNoTextAndNoTerms() {
        var signals = Self.quiet("book a table at Kothari's for Priya")
        signals.nearMisses = 1
        let summary = RefinementGate().decide(signals).summary
        for secret in ["Kothari", "Priya", "table", "book"] {
            #expect(!summary.contains(secret), "the summary leaked \(secret)")
        }
        #expect(summary.contains("nearMisses=1"))
        #expect(summary.contains("terms=40"))
    }

    @Test func theDecisionSwitchesTheRefineStageThroughItsOwnKey() async throws {
        let spans = [TranscriptSpan(text: "pass one text", confidence: 0.9, audioRange: 0...1)]
        let refiner = ControllableRefiner(text: "pass two text")
        let reports = ReportLog()
        let stage = RefineStage(refiner: refiner, samples: Array(repeating: 0.1, count: 16_000),
                                observer: { reports.append($0) })

        // Gate closed: the stage is told so through the key it documents, and pass-1 stands.
        let closed = RefinementGate().decide(Self.quiet())
        #expect(closed.stageExtra == [RefineStage.enabledKey: "false"])
        let kept = try await stage.process(spans, context: StageContext(extra: closed.stageExtra))
        #expect(kept.map(\.text) == ["pass one text"])
        #expect(reports.last?.outcome == .disabled)

        // Gate open: the same stage, the same spans, refined.
        var uncertain = Self.quiet(); uncertain.confidence = 0.2
        let open = RefinementGate().decide(uncertain)
        #expect(open.stageExtra == [RefineStage.enabledKey: "true"])
        let refined = try await stage.process(spans, context: StageContext(extra: open.stageExtra))
        #expect(refined.map(\.text) == ["pass two text"])
        #expect(reports.last?.outcome == .refined)
    }

    // MARK: Modes as the user meets them

    @Test func everyModeHasATitleAndAnExplanationAndSurvivesARoundTrip() throws {
        #expect(RefinementMode.allCases.map(\.rawValue) == ["auto", "always", "never"])
        for mode in RefinementMode.allCases {
            #expect(!mode.title.isEmpty)
            #expect(mode.explanation.count > 20)
            let data = try JSONEncoder().encode(mode)
            #expect(try JSONDecoder().decode(RefinementMode.self, from: data) == mode)
        }
    }
}

/// Collects `RefineReport`s from the stage observer without a captured `var` (the observer is
/// `@Sendable`). Mirrors `CallLog` in `RefineStageTests`.
final class ReportLog: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [RefineReport] = []
    func append(_ report: RefineReport) { lock.lock(); defer { lock.unlock() }; reports.append(report) }
    var last: RefineReport? { lock.lock(); defer { lock.unlock() }; return reports.last }
}
