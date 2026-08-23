import Foundation
import Shared

/// What the user asked the repair session to do (Bet 3, T3).
public enum RepairCommand: Equatable, Sendable {
    /// "no, Kothari" — snap the offending word to the best-matching alternate (or the said word).
    case snap(String)
    /// "not that one" — cycle to the next alternate.
    case cycle
    /// "scratch that" — drop the last phrase.
    case scratch
    /// "put it back" — undo the last replacement.
    case undo
    /// "number two" / "the second one" — pick a numbered alternate from the fan-out (1-based).
    case pick(Int)
}

/// Deterministic grammar over the gatekeeper's `repairCommand` route. The gatekeeper (P1.7)
/// decides *that* an utterance is a repair; this grammar decides *which* repair. Not
/// free-form string matching: every rule is anchored at the utterance start and the
/// payload of `snap` is the remainder after the cue.
public enum RepairGrammar {
    static let fillers: Set<String> = ["um", "uh", "uhm", "er", "ah", "hmm", "please", "actually"]

    static let cycleForms: Set<String> = [
        "not that one", "not that", "not this one", "no not that one", "no not that", "next", "next one", "the next one",
        "the other one", "other one", "try another", "try again", "another one", "something else", "not it", "nope not that",
        "no the other one", "no next one", "no next",
    ]
    static let scratchForms: Set<String> = [
        "scratch that", "strike that", "erase that", "delete that", "remove that", "never mind", "nevermind",
        "forget that", "forget it", "delete the last phrase", "delete the last sentence", "delete last", "delete the last",
        "scratch it", "scratch", "cancel that", "drop that", "no scratch that", "no delete that", "get rid of that",
    ]
    static let undoForms: Set<String> = [
        "put it back", "put that back", "undo", "undo that", "go back", "revert", "revert that", "bring it back",
        "no put it back", "undo it", "change it back", "put back", "no undo",
    ]
    static let ordinals: [String: Int] = [
        "first": 1, "one": 1, "1": 1, "second": 2, "two": 2, "2": 2, "third": 3, "three": 3, "3": 3,
        "fourth": 4, "four": 4, "4": 4, "fifth": 5, "five": 5, "5": 5,
    ]
    static let snapCues: [[String]] = [
        ["no", "i", "said"], ["no", "i", "meant"], ["no", "its"], ["no", "it", "is"], ["no", "it's"], ["no", "that's"], ["no", "thats"],
        ["no", "not", "that"], ["nope", "i", "said"], ["nope", "its"], ["i", "said"], ["i", "meant"], ["it's", "spelled"], ["its", "spelled"],
        ["no", "make", "it"], ["no", "make", "that"], ["change", "that", "to"], ["change", "it", "to"],
        ["no"], ["nope"], ["should", "be"], ["that", "should", "be"], ["it", "should", "be"],
    ]

    /// Tokenise: lowercase, strip punctuation except apostrophes, drop leading fillers.
    public static func words(_ text: String) -> [String] {
        let lowered = text.lowercased().replacingOccurrences(of: "’", with: "'")
        var cleaned = ""
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "'" { cleaned.unicodeScalars.append(scalar) }
            else { cleaned.append(" ") }
        }
        var out: [String] = cleaned.split(separator: " ").map(String.init)
        while let f = out.first, fillers.contains(f) { out.removeFirst() }
        while out.count > 1, let l = out.last, fillers.contains(l) { out.removeLast() }
        return out
    }

    /// Returns nil when `text` is not a repair command (it is dictation, or a transform).
    public static func parse(_ text: String) -> RepairCommand? {
        let w = words(text)
        guard !w.isEmpty, w.count <= 8 else { return nil }
        let joined = w.joined(separator: " ")
        if cycleForms.contains(joined) { return .cycle }
        if scratchForms.contains(joined) { return .scratch }
        if undoForms.contains(joined) { return .undo }
        if let n = pickIndex(w) { return .pick(n) }
        // Replace-with form: "replace X with Y" / "change X to Y" → snap to Y.
        if ["replace", "change", "swap"].contains(w[0]), w.count >= 4 {
            if let i = w.lastIndex(where: { $0 == "with" || $0 == "to" }), i > 1, i < w.count - 1 {
                return .snap(w[(i + 1)...].joined(separator: " "))
            }
        }
        // Snap cues (longest first) — payload is the remainder.
        for cue in snapCues.sorted(by: { $0.count > $1.count }) where w.count > cue.count && Array(w.prefix(cue.count)) == cue {
            let payload = Array(w.dropFirst(cue.count))
            guard payload.count <= 4 else { return nil }
            return .snap(payload.joined(separator: " "))
        }
        return nil
    }

    static func pickIndex(_ w: [String]) -> Int? {
        // "the second one", "number two", "option three", "pick the first one", "two", "choose 3"
        var rest = w
        for lead in ["pick", "choose", "select", "use", "take", "go", "with", "no"] where rest.first == lead { rest.removeFirst() }
        if rest.first == "the" { rest.removeFirst() }
        if let first = rest.first, ["number", "option", "alternate", "alternative", "choice"].contains(first) { rest.removeFirst() }
        guard let head = rest.first, let n = ordinals[head] else { return nil }
        rest.removeFirst()
        if rest.isEmpty || rest == ["one"] || rest == ["option"] || rest == ["please"] { return n }
        return nil
    }
}

/// T3 — the repair router as a `PipelineStage` (id `.repair`). It only acts when the
/// gatekeeper routed the utterance as `repairCommand` (or when no route is present and the
/// grammar matches), the `voiceRepair` flag is on, and a `RepairSession` is active.
/// Spans are returned untouched apart from provenance; the session's `lastResult` tells
/// the coordinator whether the utterance was consumed (and must not be injected).
public final class RepairStage: PipelineStage, @unchecked Sendable {
    public let id: StageID = .repair
    public let session: RepairSession
    public static let routeKey = "gatekeeper.route"

    public init(session: RepairSession) { self.session = session }

    public func process(_ spans: [TranscriptSpan], context: StageContext) async throws -> [TranscriptSpan] {
        let touched = spans.map { $0.touched(by: id) }
        guard context.isEnabled(.voiceRepair) else { session.note(.ignored(reason: "flag-off")); return touched }
        if let route = context.extra[Self.routeKey], route != Utterance.Route.repairCommand.rawValue {
            session.note(.ignored(reason: "route:\(route)")); return touched
        }
        guard let command = RepairGrammar.parse(spans.joinedText) else {
            session.note(.ignored(reason: "no-grammar-match")); return touched
        }
        _ = session.apply(command)
        return touched
    }
}
