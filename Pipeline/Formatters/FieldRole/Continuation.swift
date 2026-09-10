import Foundation
import Shared

/// R4.2 — what to put *between* what is already in the field and what is about to be inserted.
///
/// Three decisions, all read off the text before the cursor: the leading whitespace, whether the
/// first word is capitalized, and whether a paragraph break is wanted. `leading`/`trailing` are
/// deliberately not spans: they are field state, not transcribed audio, so they never get an
/// `audioRange` and never claim provenance. `Injection` sends `FormattedField.text`.
public struct ContinuationPlan: Sendable, Equatable {
    /// `""`, `" "`, `"\n"` or `"\n\n"`.
    public var leading: String
    /// `""` or `" "` — a space so a mid-sentence insertion does not fuse with the word after it.
    public var trailing: String
    /// False mid-sentence, true after a sentence end or at the start of a line/field.
    public var capitalizeFirstWord: Bool

    public var paragraphBreak: Bool { leading.contains("\n\n") }

    public init(leading: String = "", trailing: String = "", capitalizeFirstWord: Bool = true) {
        self.leading = leading
        self.trailing = trailing
        self.capitalizeFirstWord = capitalizeFirstWord
    }
}

public enum ContinuationPlanner {
    /// Characters after which nothing may be inserted with a space: openers, joiners, path and
    /// flag punctuation. `--save` + `dev` must not become `-- save dev`.
    static let openers: Set<Character> = ["(", "[", "{", "<", "\u{201C}", "\u{2018}",
                                          "/", "\\", "-", "~", "@", "#", "$", "_", "=", "+", "*", "`"]
    /// Straight quotes are open *or* close depending on how many came before.
    static let ambiguousQuotes: Set<Character> = ["\"", "'"]
    /// Sentence enders. `:` and `;` do not start a new sentence.
    static let sentenceEnders: Set<Character> = [".", "!", "?", "\u{2026}"]
    /// Closers that may sit after a sentence ender: `He said "go."` still ends a sentence.
    static let closers: Set<Character> = ["\"", "'", ")", "]", "}", "\u{201D}", "\u{2019}"]
    /// Trailing tokens whose period is an abbreviation, not a full stop. Lowercased, with the dot.
    static let abbreviations: Set<String> = ["e.g.", "i.e.", "etc.", "vs.", "cf.", "approx.", "no.",
                                            "mr.", "mrs.", "ms.", "dr.", "prof.", "st.", "fig.", "al.",
                                            "jan.", "feb.", "mar.", "apr.", "jun.", "jul.", "aug.",
                                            "sep.", "sept.", "oct.", "nov.", "dec."]

    /// Does the caret sit right after something that the insertion must glue onto?
    ///
    /// A straight quote is decided by parity: `he said "` is an open quote (glue), `he said "go."`
    /// closes one (a normal sentence end).
    static func endsWithOpener(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        if ambiguousQuotes.contains(last) { return text.filter { $0 == last }.count % 2 == 1 }
        return openers.contains(last)
    }

    /// True when `text` ends a sentence: a sentence ender (past any closing quotes/brackets) that
    /// is not the dot of a known abbreviation or of a single-letter initial (`J.`).
    public static func endsSentence(_ text: String) -> Bool {
        var tail = String(text.reversed().drop { $0.isWhitespace }.reversed())
        while let last = tail.last, closers.contains(last) { tail.removeLast() }
        guard let last = tail.last, sentenceEnders.contains(last) else { return false }
        guard last == "." else { return true }
        let word = tail.split(whereSeparator: { $0.isWhitespace }).last.map(String.init)?.lowercased() ?? ""
        if abbreviations.contains(word) { return false }
        // "J." / "H. P." — a single letter plus a dot is an initial.
        if word.count == 2, let first = word.first, first.isLetter { return false }
        return true
    }

    /// True when the caret already sits where a new sentence begins.
    static func atSentenceStart(_ text: String) -> Bool {
        if text.isEmpty { return true }
        if text.hasSuffix("\n") { return true }
        let trimmed = String(text.reversed().drop { $0.isWhitespace }.reversed())
        if trimmed.isEmpty { return true }
        return endsSentence(trimmed)
    }

    /// The plan for inserting at the caret described by `field`, under `rules`.
    public static func plan(for field: FieldContext, rules: FieldRules) -> ContinuationPlan {
        plan(before: field.textBeforeCursor, after: field.textAfterCursor,
             paragraphIntent: field.paragraphIntent, rules: rules)
    }

    public static func plan(before textBefore: String, after textAfter: String = "",
                            paragraphIntent: Bool = false, rules: FieldRules) -> ContinuationPlan {
        let wantsParagraph = paragraphIntent && rules.allowParagraphBreak
        var plan = ContinuationPlan()

        if textBefore.isEmpty {
            plan.leading = ""   // nothing to continue from; a paragraph break would be a leading blank line
            plan.capitalizeFirstWord = rules.autoCapitalize
        } else if let last = textBefore.last, last.isWhitespace {
            // Already spaced. Top up newlines only if a paragraph break is wanted and missing.
            let trailingNewlines = textBefore.reversed().prefix { $0 == "\n" || $0 == "\r" }.count
            plan.leading = wantsParagraph ? String(repeating: "\n", count: max(0, 2 - trailingNewlines)) : ""
            plan.capitalizeFirstWord = rules.autoCapitalize && atSentenceStart(textBefore)
        } else if endsWithOpener(textBefore) {
            // `--`, `~/`, `"`, `(` — glue, never a space, never a capital.
            plan.leading = ""
            plan.capitalizeFirstWord = false
        } else if wantsParagraph {
            plan.leading = "\n\n"
            plan.capitalizeFirstWord = rules.autoCapitalize
        } else {
            plan.leading = " "
            plan.capitalizeFirstWord = rules.autoCapitalize && endsSentence(textBefore)
        }

        if let next = textAfter.first, !next.isWhitespace, !closers.contains(next),
           ![",", ".", ";", ":", "!", "?"].contains(next) {
            plan.trailing = " "
        }
        return plan
    }
}
