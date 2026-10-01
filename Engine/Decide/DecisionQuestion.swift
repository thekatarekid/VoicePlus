import Foundation
import Shared

// V5 O4 · the fixed question set Layer 1 asks about every ambient utterance (§O-d).
//
// Plain text, asked together in one call, never trained: the decision models (Kev, Intern-Decision,
// Laya) answer typed questions zero-shot. Question ids are stable — they are the keys of
// `UtteranceDecision.questionProbabilities` and therefore of the Q13 diagnostics record.

/// One of the six questions. Raw values are the logged ids.
public enum DecisionQuestion: String, CaseIterable, Codable, Sendable {
    /// Addressed to the computer (an instruction or dictation), not to another person?
    case addressed
    /// A continuation of the last exchange with the computer?
    case continuation
    /// Complete, or is the speaker still mid-thought?
    case complete
    /// Which capability: dictate / edit / act / note / ask / ignore.
    case capability
    /// Needs the computer-use agent or the internet?
    case needsAgent
    /// Worth keeping as a note even if it is not for the computer?
    case worthNoting

    /// The six, in the order they are asked.
    public static let all: [DecisionQuestion] = allCases

    public enum Kind: Sendable, Equatable {
        /// Yes/no. Probabilities are reported under `"no"` and `"yes"`.
        case yesNo
        /// Pick one of `options` (keys).
        case choice([String])
    }

    public var kind: Kind {
        switch self {
        case .capability: return .choice(DecisionQuestion.capabilityOptions.map(\.key))
        default: return .yesNo
        }
    }

    /// The instruction text the model reads.
    public var instruction: String {
        switch self {
        case .addressed:
            return "Is the latest utterance addressed to the computer (an instruction, a question for the assistant, or text to type) rather than to another person in the room or on a call?"
        case .continuation:
            return "Does the latest utterance continue the last exchange with the computer?"
        case .complete:
            return "Is the latest utterance complete, with the speaker finished rather than still mid-thought?"
        case .capability:
            return "Which capability should handle the latest utterance?"
        case .needsAgent:
            return "Does the latest utterance need the computer-use agent or the internet to carry out?"
        case .worthNoting:
            return "Is the latest utterance worth keeping as a note even if it is not for the computer?"
        }
    }

    /// Capability options, keyed by `UtteranceOwner` raw values so an answer maps 1:1 onto an owner.
    public static let capabilityOptions: [(key: String, description: String)] = [
        (UtteranceOwner.dictate.rawValue, "type these words into the focused text field"),
        (UtteranceOwner.edit.rawValue, "change text already written (fix, rewrite, delete, scratch that)"),
        (UtteranceOwner.act.rawValue, "do something on the computer (open, click, send, switch, search)"),
        (UtteranceOwner.note.rawValue, "keep it as a note for later"),
        (UtteranceOwner.ask.rawValue, "answer a question for the user"),
        (UtteranceOwner.ignore.rawValue, "not for the computer: conversation with someone else, or noise"),
    ]
}

/// Layer 1's answers: for every asked question, a probability per option key (`"no"`/`"yes"` for
/// yes/no questions, owner raw values for `capability`).
public struct DecisionAnswers: Equatable, Sendable {
    public var distributions: [DecisionQuestion: [String: Double]]

    public init(_ distributions: [DecisionQuestion: [String: Double]] = [:]) {
        self.distributions = distributions
    }

    /// P(yes) for a yes/no question; nil when it was not answered.
    public func yes(_ q: DecisionQuestion) -> Double? {
        distributions[q]?["yes"]
    }

    /// The capability distribution as owners (unknown keys dropped).
    public var capability: [UtteranceOwner: Double] {
        var out: [UtteranceOwner: Double] = [:]
        for (k, p) in distributions[.capability] ?? [:] {
            if let o = UtteranceOwner(rawValue: k) { out[o] = p }
        }
        return out
    }

    /// The most likely capability (ties broken by `UtteranceOwner.allCases` order); nil if unanswered.
    public var bestCapability: (owner: UtteranceOwner, p: Double)? {
        let c = capability
        var best: (UtteranceOwner, Double)?
        for o in UtteranceOwner.allCases {
            guard let p = c[o] else { continue }
            if best == nil || p > best!.1 { best = (o, p) }
        }
        return best.map { (owner: $0.0, p: $0.1) }
    }

    /// Flattened for `UtteranceDecision.questionProbabilities` / Q13: yes/no questions log P(yes) under
    /// their id; the choice logs each option as `capability.<owner>`.
    public var flattened: [String: Double] {
        var out: [String: Double] = [:]
        for (q, dist) in distributions {
            switch q.kind {
            case .yesNo: if let p = dist["yes"] { out[q.rawValue] = p }
            case .choice: for (k, p) in dist { out["\(q.rawValue).\(k)"] = p }
            }
        }
        return out
    }
}
