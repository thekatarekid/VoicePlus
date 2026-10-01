import Foundation

// V5 O2 + O3 — the one vocabulary for "what an utterance is" (V5 Build §10). No lane invents another.
//
// * `UtteranceOwner` — the capability that owns an utterance. Exactly one per utterance (O2).
// * `UtteranceDecision` — the one decision per utterance: who owns it, how sure, why (O3). Emitted by
//   the intent arbiter (lane 5b, `Engine/Decide/IntentArbiter`) — or, until it lands, derived from
//   the landing route — settled once by `UtteranceDecisionHub` (App), logged to Q13 diagnostics.
// * `UtteranceTag` — what every running *recorder* (meeting session, ambient timeline) receives for a
//   settled decision, so it can render the span ("dictated", "command", "note"). Recorders keep
//   everything and never act; capabilities act and never record (O2).
//
// None of these types carries dictated text: decisions are logged, tags are fanned out to stores
// that already hold the words.

/// The capability that owns one utterance (V5 O2). Raw values are stable: they are logged (Q13) and
/// persisted on recorder transcripts.
public enum UtteranceOwner: String, Codable, CaseIterable, Sendable {
    /// Typed into the focused field.
    case dictate
    /// A command on existing text (repair, transform, "scratch that").
    case edit
    /// An action on the computer (act domain / computer use).
    case act
    /// Stored in Notes, never typed.
    case note
    /// A question for the assistant (the ask pill).
    case ask
    /// Not for the computer. Recorders still keep it; nothing acts on it.
    case ignore

    /// The word a recorder shows next to the span this owner claimed; nil for `.ignore` (an ignored
    /// utterance is just conversation, so the recorder renders it untagged).
    public var recorderLabel: String? {
        switch self {
        case .dictate: return "dictated"
        case .edit, .act: return "command"
        case .note: return "note"
        case .ask: return "asked"
        case .ignore: return nil
        }
    }
}

/// The ambient confidence band an arbiter decision fell in (V5 §O-b rubric 5). Thresholds live in
/// lane 5b's settings-backed `DecisionBands`; this is only the name of the band.
public enum UtteranceBand: String, Codable, CaseIterable, Sendable {
    /// High → act.
    case act
    /// Upper-middle → ask / confirm.
    case ask
    /// Lower-middle → Note.
    case note
    /// Low → ignore.
    case ignore
}

/// O3 — the one decision about one utterance.
public struct UtteranceDecision: Codable, Equatable, Sendable {
    /// Who owns the utterance.
    public var owner: UtteranceOwner
    /// 0…1. Layer 0 (explicit trigger, wake verb, hotkey) decides with confidence 1.
    public var confidence: Double
    /// The ambient band, when the decision came from banded (ambient) scoring; nil otherwise.
    public var band: UtteranceBand?
    /// A short reason *code* ("hotkey", "wakeVerb.note", "layer1.kev") — never transcript text.
    public var reason: String
    /// Layer 1's per-question probabilities (question id → p). Empty for Layer 0 decisions.
    public var questionProbabilities: [String: Double]

    public init(owner: UtteranceOwner, confidence: Double, band: UtteranceBand? = nil, reason: String,
                questionProbabilities: [String: Double] = [:]) {
        self.owner = owner
        self.confidence = min(1, max(0, confidence))
        self.band = band
        self.reason = reason
        self.questionProbabilities = questionProbabilities
    }

    /// A Layer 0 decision: explicit, certain.
    public static func explicit(_ owner: UtteranceOwner, reason: String) -> UtteranceDecision {
        UtteranceDecision(owner: owner, confidence: 1, reason: reason)
    }
}

/// O2 — what a recorder receives for one settled utterance: its owner and when it was spoken (wall
/// clock, so each recorder maps it onto its own timeline).
public struct UtteranceTag: Codable, Equatable, Sendable {
    /// The utterance id the decision was settled under (dedupe key).
    public var utteranceID: String
    public var owner: UtteranceOwner
    public var range: ClosedRange<Date>

    public init(utteranceID: String, owner: UtteranceOwner, range: ClosedRange<Date>) {
        self.utteranceID = utteranceID
        self.owner = owner
        self.range = range
    }

    /// Seconds of overlap between this tag and `[lower, upper]` on the same clock.
    public func overlap(_ lower: Date, _ upper: Date) -> TimeInterval {
        max(0, min(range.upperBound, upper).timeIntervalSince(max(range.lowerBound, lower)))
    }
}

/// O2 — a recorder (meeting session, ambient timeline): keeps everything, never acts, and renders
/// the owner of each utterance a capability claimed while it was running.
public protocol UtteranceTagRecording: AnyObject {
    func record(_ tag: UtteranceTag)
}
