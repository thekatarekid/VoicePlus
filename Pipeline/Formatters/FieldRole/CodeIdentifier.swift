import Foundation
import Shared

/// R4.2 — "preserve code identifiers". A formatter is allowed to lowercase, capitalize and strip
/// punctuation from words; it is never allowed to do that to `user_session_token`, `camelCase`,
/// `--flag`, `Fixtures/transcripts` or `AppPaths.fixturesDirectory`.
///
/// The mechanism is deliberately after-the-fact rather than a rule inside each formatter: collect
/// the identifier-shaped tokens from the stage's *input*, then restore that exact spelling in the
/// output. It works no matter which formatter ran, and no matter how it merged spans.
public enum CodeIdentifier {
    /// Characters that continue an identifier, used for the match boundary check.
    static let wordish: Set<Character> = ["_", "-", "/", "\\", ".", ":", "$"]

    static func isWordish(_ c: Character) -> Bool { c.isLetter || c.isNumber || wordish.contains(c) }

    /// Does this token carry spelling a formatter must not normalize?
    public static func looksLikeIdentifier(_ raw: String) -> Bool {
        let token = raw.trimmingCharacters(in: .whitespaces)
        guard token.count >= 2, token.contains(where: \.isLetter) else { return false }
        // Sentence punctuation only ("cold." / "yes,") is not an identifier.
        let core = String(token.reversed().drop { ",;:!?".contains($0) }.reversed())
        guard core.count >= 2 else { return false }

        if core.hasPrefix("-") { return true }                       // -m, --save-dev
        if core.hasPrefix("$") { return true }                       // $HOME
        if core.contains("_") { return true }                        // user_session_token
        if core.contains("/") || core.contains("\\") { return true }  // Fixtures/transcripts
        if core.contains("::") { return true }                       // std::vector

        // An interior dot with word characters on both sides: file.swift, obj.property.
        if let dot = core.dropFirst().dropLast().firstIndex(of: "."),
           let before = core[..<dot].last, before.isLetter || before.isNumber,
           let after = core[core.index(after: dot)...].first, after.isLetter || after.isNumber {
            return true
        }
        // Mixed case with an interior capital: camelCase, doSomething, NSURLSession,
        // TranscriptSpan. A plain capitalized word ("Thursday") and an acronym ("OK") are not
        // identifiers — the first has no interior capital, the second has no lowercase.
        return core.contains(where: \.isLowercase)
            && core.dropFirst().contains(where: \.isUppercase)
    }

    /// Identifier spellings present in `spans`, longest first (so `a_b_c` is restored before `a_b`).
    public static func spellings(in spans: [TranscriptSpan]) -> [String] {
        var out: [String] = []
        for span in spans {
            for token in span.text.split(whereSeparator: \.isWhitespace) {
                let t = String(token)
                if looksLikeIdentifier(t), !out.contains(t) { out.append(t) }
            }
        }
        return out.sorted { $0.count > $1.count }
    }

    /// Restores each spelling wherever a case-insensitive copy of it appears in `spans`.
    ///
    /// Low-confidence spans are skipped: Bet 9 forbids rewriting them, and no formatter changed
    /// them either, so there is nothing to restore.
    public static func restore(_ spellings: [String], in spans: [TranscriptSpan]) -> [TranscriptSpan] {
        guard !spellings.isEmpty else { return spans }
        return spans.map { span in
            guard !span.isLowConfidence, !span.text.isEmpty else { return span }
            var copy = span
            for spelling in spellings { copy.text = replacing(spelling, in: copy.text) }
            return copy
        }
    }

    /// Case-insensitive replacement on identifier boundaries. Only rewrites when the found text
    /// actually differs, so an untouched span stays `Equatable`-identical.
    static func replacing(_ spelling: String, in text: String) -> String {
        guard text.count >= spelling.count else { return text }
        let needle = Array(spelling.lowercased())
        let hay = Array(text), lowerHay = Array(text.lowercased())
        guard lowerHay.count == hay.count else { return text }   // case folding changed length: bail
        var out: [Character] = []
        var i = 0
        while i < hay.count {
            let end = i + needle.count
            let boundaryBefore = i == 0 || !isWordish(hay[i - 1])
            let boundaryAfter = end >= hay.count || !isWordish(hay[end])
            if end <= hay.count, boundaryBefore, boundaryAfter, Array(lowerHay[i..<end]) == needle {
                out.append(contentsOf: spelling)
                i = end
            } else {
                out.append(hay[i])
                i += 1
            }
        }
        return String(out)
    }
}
