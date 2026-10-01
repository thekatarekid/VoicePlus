import Foundation
import Shared

// V5 O4 · Layer 2 — what to do once the arbiter knows what an utterance is (§O-d).
//
// act  → CU4 retrieval over the action catalogue → CUA-S1 picks the element → planner (multi-step).
// note → Notes (N).  ask → the ask pill.  dictate/edit/ignore → nothing here (dictation and edits
// arrive through the hotkey path; ignore is only recorded).
//
// CU4/CUA-S1 are W7 items; until they land `act` goes to whatever `ActHandoff` the app supplies.
// Ambient mode policy (L1/L2: Listen & note never acts) is applied by the app's handoff wrapper
// (`AmbientDecisionPolicy`), not here — the arbiter only decides.

public protocol Layer2Handoff: Sendable {
    func handle(_ decision: UtteranceDecision, text: String, answers: DecisionAnswers?) async
}

/// Routes a decision to one of three closures by owner.
public struct Layer2Router: Layer2Handoff {
    public var act: (@Sendable (String, _ needsAgent: Bool) async -> Void)?
    public var note: (@Sendable (String) async -> Void)?
    public var ask: (@Sendable (String) async -> Void)?

    public init(act: (@Sendable (String, Bool) async -> Void)? = nil,
                note: (@Sendable (String) async -> Void)? = nil,
                ask: (@Sendable (String) async -> Void)? = nil) {
        self.act = act; self.note = note; self.ask = ask
    }

    public func handle(_ decision: UtteranceDecision, text: String, answers: DecisionAnswers?) async {
        switch decision.owner {
        case .act: await act?(text, (answers?.yes(.needsAgent) ?? 0) >= 0.5)
        case .note: await note?(text)
        case .ask: await ask?(text)
        case .dictate, .edit, .ignore: break
        }
    }
}
