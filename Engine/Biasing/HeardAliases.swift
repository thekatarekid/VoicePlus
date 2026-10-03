import Foundation

// H18 — heard aliases: how a written term sounds when it is dictated.
//
// "hold-to-talk" is one written token, but the recogniser hears and writes "hold to talk";
// "snake_case_name" is heard "snake case name"; "TeamViewer" is heard "team viewer". The booster
// (CTC spotting + rescoring) and the exact-alias rewrite match on these spoken forms and always
// write the term's written (on-screen) form. Pure and model-free.

public enum HeardAliases {
    /// Spoken forms of `term` other than the term itself, case-insensitively distinct. Empty for a
    /// plain word or phrase. Hyphens / underscores / slashes between letters become spaces; a
    /// camelCase or PascalCase word splits at its inner capitals (each part ≥ 2 letters).
    public static func aliases(for term: String) -> [String] {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 3 else { return [] }
        var out: [String] = []
        var seen: Set<String> = [t.lowercased()]
        func add(_ s: String) {
            let s = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !s.isEmpty, s.contains(" "), seen.insert(s.lowercased()).inserted else { return }
            out.append(s)
        }
        let separated = splitSeparators(t)
        if separated != t { add(separated) }
        let camel = separated.split(separator: " ").map { splitCamel(String($0)) }.joined(separator: " ")
        if camel != separated { add(camel) }
        return out
    }

    /// The form a recogniser most likely writes for `term` ("hold to talk" for "hold-to-talk").
    /// The term itself when it has no separator-based alias (camelCase keeps its written form: the
    /// tokenizer handles case, but not punctuation inside a word).
    public static func spokenForm(_ term: String) -> String {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = splitSeparators(t)
        return s == t ? t : s.lowercased()
    }

    /// True when the term has a separator (hyphen / underscore / slash) the recogniser never writes.
    public static func hasSeparator(_ term: String) -> Bool { splitSeparators(term) != term }

    static func splitSeparators(_ t: String) -> String {
        let chars = Array(t)
        var out = ""
        for (i, c) in chars.enumerated() {
            if "-_/".contains(c), i > 0, i < chars.count - 1,
               chars[i - 1].isLetter || chars[i - 1].isNumber, chars[i + 1].isLetter || chars[i + 1].isNumber {
                out.append(" ")
            } else {
                out.append(c)
            }
        }
        return out
    }

    static func splitCamel(_ w: String) -> String {
        let chars = Array(w)
        guard chars.count >= 4, chars.allSatisfy({ $0.isLetter || $0.isNumber }) else { return w }
        var parts: [String] = []
        var cur = ""
        for (i, c) in chars.enumerated() {
            if i > 0, c.isUppercase, chars[i - 1].isLowercase { parts.append(cur); cur = "" }
            cur.append(c)
        }
        parts.append(cur)
        guard parts.count >= 2, parts.allSatisfy({ $0.count >= 2 }) else { return w }
        return parts.joined(separator: " ")
    }
}

/// H18 — exact spoken-alias rewrite on plain text: where a term's multi-word heard alias appears
/// word-for-word (case- and punctuation-insensitive), write the term's on-screen form instead.
/// Punctuation around the run is kept ("hold to talk." → "hold-to-talk.").
public enum HeardAliasText {
    public struct Replacement: Equatable, Sendable {
        public var original: String
        public var replacement: String
    }

    /// The rewritten text and what changed; `text` unchanged (and no replacements) when nothing matched.
    public static func rewrite(_ text: String, terms: [String]) -> (text: String, replacements: [Replacement]) {
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count >= 2 else { return (text, []) }
        var forms: [(term: String, keys: [String])] = []
        for term in terms {
            for alias in aliases(term) {
                let keys = alias.split(separator: " ").map { key(String($0)) }
                if keys.count >= 2, keys.allSatisfy({ !$0.isEmpty }) { forms.append((term, keys)) }
            }
        }
        guard !forms.isEmpty else { return (text, []) }
        forms.sort { $0.keys.count > $1.keys.count }   // longest alias wins
        var replacements: [Replacement] = []
        var i = 0
        while i < words.count {
            for f in forms where i + f.keys.count <= words.count {
                let run = words[i..<(i + f.keys.count)]
                guard zip(run, f.keys).allSatisfy({ key($0) == $1 }) else { continue }
                // Inner punctuation (a comma or full stop inside the run) is a boundary, not an alias.
                guard run.dropLast().allSatisfy({ trailing($0).isEmpty }), run.dropFirst().allSatisfy({ leading($0).isEmpty }) else { continue }
                let original = run.joined(separator: " ")
                let written = leading(run.first!) + f.term + trailing(run.last!)
                words.replaceSubrange(i..<(i + f.keys.count), with: [written])
                replacements.append(Replacement(original: original, replacement: written))
                break
            }
            i += 1
        }
        guard !replacements.isEmpty else { return (text, []) }
        return (words.joined(separator: " "), replacements)
    }

    /// Aliases that are worth a word-level rewrite: separator aliases ("hold to talk") and camel
    /// splits ("team viewer").
    static func aliases(_ term: String) -> [String] { HeardAliases.aliases(for: term) }

    static func key(_ w: String) -> String { w.lowercased().filter { $0.isLetter || $0.isNumber } }

    static func leading(_ w: String) -> String {
        String(w.prefix { !($0.isLetter || $0.isNumber) })
    }

    static func trailing(_ w: String) -> String {
        String(String(w.reversed()).prefix { !($0.isLetter || $0.isNumber) }.reversed())
    }
}

/// H17 — words of a caret window with their UTF-16 distance from the caret.
enum NearCaretWords {
    struct Word: Equatable {
        var text: String
        /// UTF-16 units between the word and the caret (0 = touching it).
        var distance: Int
        /// Punctuation after the word ends a phrase / capitalised run.
        var breakAfter: Bool
    }

    static let separators: Set<Character> = [",", ";", "(", ")", "\"", "\u{201C}", "\u{201D}", "[", "]",
                                             "{", "}", "<", ">", "`", "*", "|"]

    /// - Parameter isBefore: the text ends at the caret (distances count back from the end);
    ///   otherwise it starts at the caret.
    static func split(_ text: String, isBefore: Bool) -> [Word] {
        let total = text.utf16.count
        var out: [Word] = []
        var i = text.startIndex
        while i < text.endIndex {
            while i < text.endIndex, text[i].isWhitespace || separators.contains(text[i]) {
                if separators.contains(text[i]), !out.isEmpty { out[out.count - 1].breakAfter = true }
                i = text.index(after: i)
            }
            guard i < text.endIndex else { break }
            let start = i
            while i < text.endIndex, !text[i].isWhitespace, !separators.contains(text[i]) { i = text.index(after: i) }
            var w = String(text[start..<i])
            var broke = false
            while let last = w.last, !(last.isLetter || last.isNumber) { w.removeLast(); broke = true }
            while let first = w.first, !(first.isLetter || first.isNumber) { w.removeFirst() }
            let lo = text.utf16.distance(from: text.startIndex, to: start)
            let hi = text.utf16.distance(from: text.startIndex, to: i)
            out.append(Word(text: w, distance: max(0, isBefore ? total - hi : lo), breakAfter: broke))
        }
        return out
    }
}
