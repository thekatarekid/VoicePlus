import Foundation
import Shared

// V5 O4 + O5 + L4 · the intent arbiter: one decision per utterance, in layers (§O-d).
//
// Layer 0 — explicit, deterministic. A pressed key (the caller passes it as `explicit`), then each
//   `ExplicitDecider` in order: wake verb (`WakeVerbGrammar`), `ActIntentParser`, `GatekeeperStage`.
//   The first that recognises the utterance decides with confidence 1 and no model gets a vote
//   (rule 0.5: an explicit instruction wins outright). Engine cannot import Pipeline/Actions, so the
//   app supplies those three as adapters (`App/Ambient/ArbiterWiring.swift`).
// Layer 1 — one decision model call over the O5 state with the six fixed questions. The score is
//   P(addressed to the computer); `DecisionBands` turns it into a band; the band and the capability
//   answer give the owner.
// Layer 2 — `Layer2Handoff` (act → CU4/CUA-S1/planner, note → Notes, ask → ask pill).
//
// Every decision is reported through `onDecision` (the app settles it on `UtteranceDecisionHub`,
// which logs it to Q13 with the question-level probabilities). No transcript text in the decision.

/// A Layer 0 recogniser: returns a decision when the utterance is an explicit instruction.
public protocol ExplicitDecider: Sendable {
    /// Short id for the reason code ("wakeVerb", "actIntent", "gatekeeper").
    var id: String { get }
    func decide(_ text: String) -> UtteranceDecision?
}

/// A Layer 0 recogniser from a closure (adapters, tests).
public struct ClosureExplicitDecider: ExplicitDecider {
    public let id: String
    private let body: @Sendable (String) -> UtteranceDecision?
    public init(id: String, _ body: @escaping @Sendable (String) -> UtteranceDecision?) {
        self.id = id; self.body = body
    }
    public func decide(_ text: String) -> UtteranceDecision? { body(text) }
}

/// One utterance to decide.
public struct ArbiterInput: Sendable {
    public var utteranceID: String
    public var range: ClosedRange<Date>
    /// A decision the caller already knows is explicit (hotkey / act key / latch claim). Wins outright.
    public var explicit: UtteranceDecision?
    /// O5 context; `state.utterance` is the text.
    public var state: DecisionState

    public init(utteranceID: String, range: ClosedRange<Date>, explicit: UtteranceDecision? = nil, state: DecisionState) {
        self.utteranceID = utteranceID; self.range = range; self.explicit = explicit; self.state = state
    }

    public var text: String { state.utterance }
}

/// What the arbiter decided, and how.
public struct ArbiterResult: Sendable {
    public enum Layer: Int, Sendable { case explicit = 0, model = 1 }
    public var decision: UtteranceDecision
    public var layer: Layer
    /// Layer 1's answers (nil for Layer 0, or when no model answered).
    public var answers: DecisionAnswers?
    /// The rendered O5 state the model saw (diagnostics only — it contains transcript text, so it is
    /// never put in the decision or in Q13).
    public var renderedState: String?
}

public final class IntentArbiter: @unchecked Sendable {
    public let layer0: [any ExplicitDecider]
    private let model: @Sendable () async -> (any DecisionModel)?
    private let bands: @Sendable () -> DecisionBands
    public let renderer: DecisionStateRenderer
    /// In the ignore band, an utterance at least this "worth noting" becomes a note.
    public var worthNotingThreshold: Double
    /// Settled decisions (the app forwards them to `UtteranceDecisionHub`, which logs Q13).
    public var onDecision: ((UtteranceDecision, ArbiterInput) -> Void)?
    /// Layer 2.
    public var handoff: (any Layer2Handoff)?

    public static let questions = DecisionQuestion.all

    public init(layer0: [any ExplicitDecider] = [],
                model: @escaping @Sendable () async -> (any DecisionModel)?,
                bands: @escaping @Sendable () -> DecisionBands = { .defaults },
                renderer: DecisionStateRenderer = DecisionStateRenderer(),
                worthNotingThreshold: Double = 0.85) {
        self.layer0 = layer0
        self.model = model
        self.bands = bands
        self.renderer = renderer
        self.worthNotingThreshold = worthNotingThreshold
    }

    /// Convenience: Layer 1 from a registry (HW3 swap aware).
    public convenience init(layer0: [any ExplicitDecider] = [], registry: DecisionModelRegistry,
                            bands: @escaping @Sendable () -> DecisionBands = { .defaults }) {
        self.init(layer0: layer0, model: { await registry.current() }, bands: bands)
    }

    /// Decide one utterance, report it, and hand it to Layer 2.
    @discardableResult
    public func decide(_ input: ArbiterInput) async -> ArbiterResult {
        let result = await evaluate(input)
        onDecision?(result.decision, input)
        await handoff?.handle(result.decision, text: input.text, answers: result.answers)
        return result
    }

    /// Decide without reporting or handing off (pure; tests, V1 `--stage decide`).
    public func evaluate(_ input: ArbiterInput) async -> ArbiterResult {
        if let explicit = layer0Decision(input) {
            return ArbiterResult(decision: explicit, layer: .explicit, answers: nil, renderedState: nil)
        }
        let rendered = renderer.render(input.state)
        guard let model = await model() else {
            return ArbiterResult(decision: Self.unavailable("layer1.none"), layer: .model, answers: nil, renderedState: rendered)
        }
        let answers: DecisionAnswers
        do {
            answers = try await model.decide(state: rendered, questions: Self.questions)
        } catch {
            return ArbiterResult(decision: Self.unavailable("layer1.\(model.id).unavailable"), layer: .model,
                                 answers: nil, renderedState: rendered)
        }
        let decision = Self.map(answers, modelID: model.id, bands: bands(), app: input.state.frontmostApp,
                                worthNotingThreshold: worthNotingThreshold)
        return ArbiterResult(decision: decision, layer: .model, answers: answers, renderedState: rendered)
    }

    /// Layer 0: the caller's explicit decision, else the first recogniser that fires. Always confidence 1.
    public func layer0Decision(_ input: ArbiterInput) -> UtteranceDecision? {
        if var e = input.explicit {
            e.confidence = 1
            e.questionProbabilities = [:]
            return e
        }
        for d in layer0 {
            if var hit = d.decide(input.text) {
                hit.confidence = 1
                hit.band = nil
                hit.questionProbabilities = [:]
                if !hit.reason.hasPrefix(d.id) { hit.reason = "\(d.id).\(hit.reason)" }
                return hit
            }
        }
        return nil
    }

    /// No model, or the model failed: nothing acts. Recorders keep the words; the owner is `ignore`.
    static func unavailable(_ reason: String) -> UtteranceDecision {
        UtteranceDecision(owner: .ignore, confidence: 0, band: .ignore, reason: reason)
    }

    /// Layer 1 answers → one decision (band mapping, §O-b rubric 5).
    public static func map(_ answers: DecisionAnswers, modelID: String, bands: DecisionBands, app: String?,
                           worthNotingThreshold: Double = 0.85) -> UtteranceDecision {
        let score = answers.yes(.addressed) ?? 0
        var band = bands.band(for: score, app: app)
        var reason = "layer1.\(modelID)"
        // Still mid-thought: never act on half a sentence — one band down.
        if let complete = answers.yes(.complete), complete < 0.5 {
            reason += ".incomplete"
            switch band {
            case .act: band = .ask
            case .ask: band = .note
            case .note, .ignore: break
            }
        }
        let capability = answers.bestCapability?.owner ?? .ignore
        let owner: UtteranceOwner
        switch band {
        case .act:
            owner = capability
        case .ask:
            owner = (capability == .note || capability == .ignore) ? capability : .ask
        case .note:
            owner = capability == .ignore ? ((answers.yes(.worthNoting) ?? 0) >= 0.5 ? .note : .ignore) : .note
        case .ignore:
            owner = (answers.yes(.worthNoting) ?? 0) >= worthNotingThreshold ? .note : .ignore
        }
        let confidence = owner == .ignore ? 1 - score : score
        return UtteranceDecision(owner: owner, confidence: confidence, band: band, reason: reason,
                                 questionProbabilities: answers.flattened)
    }
}
