import Actions
import Engine
import Foundation
import Shared

// V5 L2 · the ambient guarantees (amends V3 §8; owner approved). Replaces R8.1's
// `AmbientInjectionAudit` / `AmbientNeverInjectsTests`, which proved "ambient never types" — no longer
// the rule now that Listen & act exists. What must hold instead, every one enforced here and proven in
// `Tests/AppTests/AmbientGuaranteesTests.swift`:
//
//   1. No inject / act unless the mode is Listen & act. Off records nothing new; Listen & note at most
//      stores a Note — it never reaches `delivery`.
//   2. Only the user's voice (K4/M6 speaker verdict `.you` → `SpeakerGate.Verdict.user`). An unknown
//      or other voice never acts and never becomes the user's note.
//   3. Only the act band: dictate / edit / act need `band == .act` (or an explicit Layer 0 trigger,
//      confidence 1). The ask pill — which only asks the user — needs at least the ask band.
//   4. Irreversible steps are never self-confirmed: an ambient utterance can never be the "confirm"
//      for an irreversible action (§O-b rubric 6); it needs a turn the user started, or a click.
//
// `AmbientDecisionPipeline` is the only place ambient speech meets the arbiter, and it consults
// `disposition` before anything leaves; a disposition other than `.deliver` cannot reach a delivery sink.

/// Where one ambient utterance may go.
public enum AmbientDisposition: Equatable, Sendable {
    /// Kept in the Timeline only (it already was); nothing else happens.
    case recordOnly(AmbientHoldReason)
    /// Stored as a Note (Listen & note, or the note band).
    case note
    /// May be handed to the capability (dictate / edit / act / ask). Listen & act only.
    case deliver(UtteranceOwner)

    public var delivers: Bool { if case .deliver = self { return true } else { return false } }
}

public enum AmbientHoldReason: String, Equatable, Sendable {
    case modeOff, ignored, notUserVoice, belowActBand, cannotSelfConfirm, modeCommand
}

/// Where an utterance came from, for the confirmation rule.
public enum UtteranceSource: Equatable, Sendable {
    /// Ambient listening (no key, no latch the user started for this turn).
    case ambient
    /// A turn the user started (hold, latch, act key).
    case explicitTurn
    /// A click on the confirmation card.
    case click
}

public enum AmbientGuarantees {
    /// The band a decision counts as: its own, or `.act` for an explicit (Layer 0, confidence 1) one.
    public static func effectiveBand(_ d: UtteranceDecision) -> UtteranceBand {
        if let b = d.band { return b }
        return d.confidence >= 1 ? .act : .ignore
    }

    /// Guarantees 1–3 (and 4's ambient half: a bare "confirm" is never forwarded).
    public static func disposition(mode: AmbientMode, verdict: SpeakerGate.Verdict,
                                   decision: UtteranceDecision, text: String) -> AmbientDisposition {
        guard mode.listens else { return .recordOnly(.modeOff) }
        if decision.owner == .ignore { return .recordOnly(.ignored) }
        guard verdict.isUser else { return .recordOnly(.notUserVoice) }
        if ConfirmationCard.isSpokenConfirm(text) { return .recordOnly(.cannotSelfConfirm) }
        if decision.owner == .note { return .note }
        // dictate / edit / act / ask from here.
        guard mode.mayAct else { return .note }                       // Listen & note: never delivery
        let band = effectiveBand(decision)
        switch decision.owner {
        case .ask:
            return (band == .act || band == .ask) ? .deliver(.ask) : .note
        case .dictate, .edit, .act:
            return band == .act ? .deliver(decision.owner) : .recordOnly(.belowActBand)
        case .note, .ignore:
            return .note
        }
    }

    /// Guarantee 4: may this utterance confirm a pending action of this reversibility?
    public static func mayConfirm(_ utterance: String, source: UtteranceSource, reversibility: Reversibility) -> Bool {
        switch source {
        case .click: return true
        case .explicitTurn: return ConfirmationCard.isSpokenConfirm(utterance)
        case .ambient: return reversibility != .irreversible && ConfirmationCard.isSpokenConfirm(utterance)
        }
    }
}
