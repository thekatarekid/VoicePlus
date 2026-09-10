import Foundation
import Shared

/// R2.5 — the three repair commands. Deliberately three, and no more: the V3 spec (§6) binds
/// repair to the last committed region, and anything richer belongs to the fan-out UI.
///
/// Named `RepairVoiceCommand` rather than `RepairCommand` so that a file importing both
/// `Actions` and `Engine` (which has its own beam-decoder `RepairCommand`) stays unambiguous.
/// This grammar is deliberately independent of the beam decoder: repair works with nothing
/// but the committed text region and the ledger.
public enum RepairVoiceCommand: Equatable, Sendable, CustomStringConvertible {
    /// "scratch that" — the last committed region goes away.
    case scratchThat
    /// "no, <replacement>" — the last committed region reads `<replacement>` instead.
    case replaceWith(String)
    /// "put it back" — undo the last repair, from the ledger record.
    case putItBack

    public var description: String {
        switch self {
        case .scratchThat: return "scratch that"
        case .replaceWith(let text): return "no, \(text)"
        case .putItBack: return "put it back"
        }
    }

    /// Spoken form, for suggestion copy.
    public var spokenForm: String { description }
}

/// What one utterance turned out to be.
public enum RepairClassification: Equatable, Sendable {
    case command(RepairVoiceCommand)
    /// Not a repair: ordinary dictation. `quoted` carries the command the user *said*
    /// inside quotes — quoted commands are text, never commands (R2.5, task 4).
    case dictation(quoted: RepairVoiceCommand?)

    public var isCommand: Bool { if case .command = self { return true }; return false }
    public var command: RepairVoiceCommand? { if case .command(let c) = self { return c } else { return nil } }
    public var quotedCommand: RepairVoiceCommand? { if case .dictation(let q) = self { return q } else { return nil } }
}

/// Deterministic, anchored grammar for the three repair commands.
///
/// Anchored means: the whole utterance is the command, apart from fillers. "I had to scratch
/// that itch" is dictation, and so is anything the user put in quotes.
public enum RepairCommandGrammar {
    static let leadingFillers: Set<String> = ["um", "uh", "uhm", "er", "ah", "hmm", "okay", "ok", "oh", "so", "well", "actually"]
    static let trailingFillers: Set<String> = ["please", "thanks", "um", "uh", "hmm"]

    static let scratchForms: Set<String> = [
        "scratch that", "scratch this", "scratch that last bit", "scratch that bit",
        "no scratch that", "scratch that one",
    ]
    static let putBackForms: Set<String> = [
        "put it back", "put that back", "put back", "no put it back", "put it back again",
    ]
    /// Cue words that may follow the leading "no" before the replacement text.
    static let replaceCues: [[String]] = [
        ["i", "said"], ["i", "meant"], ["it", "is"], ["it's"], ["its"], ["that's"], ["thats"],
        ["make", "it"], ["make", "that"], ["it", "should", "be"], ["should", "be"],
    ]
    static let replaceLeads: Set<String> = ["no", "nope"]
    /// A replacement longer than this is far more likely to be dictation than a repair.
    /// Four words matches the beam-repair grammar's payload cap in `Engine/Repair`.
    static let maxReplacementWords = 4
    /// After a bare "no", these openers mean the user is talking, not repairing:
    /// "no, I don't think so" is dictation; "no, Kothari" is a repair.
    static let dictationLeads: Set<String> = [
        "i", "i'm", "im", "you", "we", "they", "he", "she", "there", "that", "this", "these", "those",
        "it", "its", "it's", "not", "never", "don't", "dont", "do", "did", "does", "and", "but", "because",
        "thanks", "thank", "really", "just", "we're", "were", "im",
    ]

    // MARK: - Public API

    /// Classify one finalized utterance. `text` is the raw recognized text, punctuation and all.
    public static func classify(_ text: String) -> RepairClassification {
        // Rule 4 first: a command inside quotes is dictation, even if the rest of the
        // utterance is nothing but that command.
        for quoted in quotedSpans(in: text) {
            if let command = parseCommand(quoted) { return .dictation(quoted: command) }
        }
        if let command = parseCommand(text) { return .command(command) }
        return .dictation(quoted: nil)
    }

    /// Convenience: `nil` when the utterance is dictation (quoted commands included).
    public static func parse(_ text: String) -> RepairVoiceCommand? { classify(text).command }

    // MARK: - Tokens

    struct Token: Equatable {
        var original: String
        var lower: String
    }

    /// Split on anything that is not alphanumeric or an apostrophe, keeping the original casing
    /// alongside a lowercased mirror so a replacement keeps the spelling the user asked for.
    static func tokens(_ text: String) -> [Token] {
        var out: [Token] = []
        var current = ""
        func flush() {
            guard !current.isEmpty else { return }
            out.append(Token(original: current, lower: current.lowercased()))
            current = ""
        }
        for scalar in text.replacingOccurrences(of: "’", with: "'").unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "'" {
                current.unicodeScalars.append(scalar)
            } else {
                flush()
            }
        }
        flush()
        // Fillers top and tail. Never strip the last remaining token.
        while let first = out.first, leadingFillers.contains(first.lower), out.count > 1 { out.removeFirst() }
        while let last = out.last, trailingFillers.contains(last.lower), out.count > 1 { out.removeLast() }
        return out
    }

    // MARK: - Command parsing

    static func parseCommand(_ text: String) -> RepairVoiceCommand? {
        let words = tokens(text)
        guard !words.isEmpty else { return nil }
        let joined = words.map(\.lower).joined(separator: " ")
        if scratchForms.contains(joined) { return .scratchThat }
        if putBackForms.contains(joined) { return .putItBack }

        guard let lead = words.first, replaceLeads.contains(lead.lower) else { return nil }
        var rest = Array(words.dropFirst())
        var cueMatched = false
        // "no, scratch that" / "no, put it back" already matched above; a cue may still follow.
        for cue in replaceCues.sorted(by: { $0.count > $1.count })
        where rest.count > cue.count && rest.prefix(cue.count).map(\.lower) == cue {
            rest = Array(rest.dropFirst(cue.count))
            cueMatched = true
            break
        }
        if !cueMatched, let head = rest.first, rest.count > 1, dictationLeads.contains(head.lower) { return nil }
        let restJoined = rest.map(\.lower).joined(separator: " ")
        if scratchForms.contains(restJoined) { return .scratchThat }
        if putBackForms.contains(restJoined) { return .putItBack }
        guard !rest.isEmpty, rest.count <= maxReplacementWords else { return nil }
        return .replaceWith(rest.map(\.original).joined(separator: " "))
    }

    // MARK: - Quotes

    static let quotePairs: [(open: Character, close: Character)] = [
        ("\"", "\""), ("\u{201C}", "\u{201D}"), ("\u{2018}", "\u{2019}"), ("'", "'"),
    ]

    /// Quoted substrings, outermost first. A straight apostrophe only opens a quote at a word
    /// boundary, so "it's" and "don't" are not mistaken for quotation.
    static func quotedSpans(in text: String) -> [String] {
        var spans: [String] = []
        let chars = Array(text)
        for pair in quotePairs {
            var i = 0
            while i < chars.count {
                guard chars[i] == pair.open, opensQuote(chars, at: i, pair: pair) else { i += 1; continue }
                var j = i + 1
                while j < chars.count, !(chars[j] == pair.close && closesQuote(chars, at: j, pair: pair)) { j += 1 }
                guard j < chars.count, j > i + 1 else { i += 1; continue }
                spans.append(String(chars[(i + 1)..<j]))
                i = j + 1
            }
        }
        return spans
    }

    private static func opensQuote(_ chars: [Character], at i: Int, pair: (open: Character, close: Character)) -> Bool {
        guard pair.open == "'" else { return true }
        let before = i == 0 ? " " : chars[i - 1]
        guard before == " " || before == "(" || before == "\n" || i == 0 else { return false }
        guard i + 1 < chars.count else { return false }
        return chars[i + 1] != " "
    }

    private static func closesQuote(_ chars: [Character], at j: Int, pair: (open: Character, close: Character)) -> Bool {
        guard pair.close == "'" else { return true }
        let after = j + 1 < chars.count ? chars[j + 1] : " "
        let before = chars[j - 1]
        return before != " " && (after == " " || after == "." || after == "," || after == "!" || after == "?" || after == "\n" || j + 1 == chars.count)
    }
}
