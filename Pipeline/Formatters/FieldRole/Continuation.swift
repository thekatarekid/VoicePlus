import Foundation
import Shared

/// D2/D3 — what may end the insertion. Spoken periods ("full stop") are always kept; `?`, `!`
/// and ellipses are never touched.
public enum PeriodRule: String, Sendable, Equatable, CaseIterable {
    /// The caret ends a sentence position (after `.!?` + space, a new line, a finished field):
    /// the recogniser's period stays and the field role may add one (`FieldRules.trailingPeriod`).
    case keep
    /// Mid-sentence: after a word, or with text following on the same line. The recogniser's
    /// period and any period a formatter added are removed.
    case strip
    /// An empty field: a period only for a full clause. The recogniser's period needs three
    /// words, one a formatter adds needs four (V4.4: "≥ 4 words", cheap `hypothesis`).
    case fullClause
    /// The caret is unknown: `UnknownCaretStyle` and the word count decide (see `resolved`).
    case unknownCaret
}

/// D2 — what happens to the first word's capital.
public enum FirstWordAction: String, Sendable, Equatable {
    /// Sentence start: capitalize a lowercase first letter.
    case capitalize
    /// Mid-sentence: lowercase a capital, whether the recogniser or a formatter produced it
    /// (a proper-noun-shaped word — "I", an acronym, an identifier, a weekday — is kept).
    case lowercase
    /// Leave the recogniser's casing: only undo a capital a formatter added.
    case lowercaseAddedOnly
}

/// R4.2 / D3 — what to put *between* what is already in the field and what is about to be
/// inserted, and how the insertion may begin and end.
///
/// `leading`/`trailing` are deliberately not spans: they are field state, not transcribed audio,
/// so they never get an `audioRange` and never claim provenance. `Injection` sends
/// `FormattedField.text`.
public struct ContinuationPlan: Sendable, Equatable {
    /// `""` or `" "`. (The paragraph branch was removed: nothing produced `paragraphIntent`.)
    public var leading: String
    /// `""` or `" "` — a space so a mid-sentence insertion does not fuse with the word after it.
    public var trailing: String
    /// True at a sentence start (after a sentence end, at the start of a line or of the field).
    public var capitalizeFirstWord: Bool
    /// D2 — a capital the recogniser produced is lowercased: the caret sits after a word, a
    /// space after a non-terminal, or other non-terminal punctuation.
    public var lowercaseModelCapital: Bool
    public var period: PeriodRule
    /// The caret state the plan was made for.
    public var caretKind: CaretState.Kind
    public var unknownCaretStyle: UnknownCaretStyle

    public var paragraphBreak: Bool { leading.contains("\n\n") }

    public init(leading: String = "", trailing: String = "", capitalizeFirstWord: Bool = true,
                lowercaseModelCapital: Bool = false, period: PeriodRule = .keep,
                caretKind: CaretState.Kind = .endOfField, unknownCaretStyle: UnknownCaretStyle = .sentence) {
        self.leading = leading
        self.trailing = trailing
        self.capitalizeFirstWord = capitalizeFirstWord
        self.lowercaseModelCapital = lowercaseModelCapital
        self.period = period
        self.caretKind = caretKind
        self.unknownCaretStyle = unknownCaretStyle
    }

    /// The decisions that depend on the utterance itself, resolved for `wordCount` words.
    public struct Resolved: Sendable, Equatable {
        public var firstWord: FirstWordAction
        /// Keep a period the recogniser produced.
        public var keepModelPeriod: Bool
        /// Keep a period a formatter added (subject to `FieldRules.trailingPeriod` as well).
        public var keepAddedPeriod: Bool
    }

    /// Word-count thresholds (V4.2, V4.4).
    public static let unknownSentenceMinWords = 3
    public static let modelPeriodMinWords = 3
    public static let addedPeriodMinWords = 4

    /// `textRole` is `FieldRules.autoCapitalize`: code and terminal roles keep their formatter's
    /// casing and punctuation (an identifier such as `String` must not be lowercased); only the
    /// continuation whitespace applies to them.
    public func resolved(wordCount: Int, textRole: Bool = true) -> Resolved {
        guard textRole else {
            return Resolved(firstWord: .lowercaseAddedOnly, keepModelPeriod: true, keepAddedPeriod: true)
        }
        switch period {
        case .unknownCaret:
            if unknownCaretStyle == .sentence, wordCount >= Self.unknownSentenceMinWords {
                return Resolved(firstWord: .lowercaseAddedOnly, keepModelPeriod: true, keepAddedPeriod: false)
            }
            return Resolved(firstWord: .lowercase, keepModelPeriod: false, keepAddedPeriod: false)
        case .keep, .strip, .fullClause:
            let first: FirstWordAction = capitalizeFirstWord ? .capitalize
                : (lowercaseModelCapital ? .lowercase : .lowercaseAddedOnly)
            switch period {
            case .keep: return Resolved(firstWord: first, keepModelPeriod: true, keepAddedPeriod: true)
            case .strip: return Resolved(firstWord: first, keepModelPeriod: false, keepAddedPeriod: false)
            default:
                return Resolved(firstWord: first, keepModelPeriod: wordCount >= Self.modelPeriodMinWords,
                                keepAddedPeriod: wordCount >= Self.addedPeriodMinWords)
            }
        }
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
    /// Punctuation that attaches to the word before it: no trailing space is needed before it.
    static let attaching: Set<Character> = [",", ".", ";", ":", "!", "?"]
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
        if isAbbreviation(word) { return false }
        return true
    }

    /// A known abbreviation (`etc.`) or a single-letter initial (`J.`). `word` is lowercased.
    static func isAbbreviation(_ word: String) -> Bool {
        if abbreviations.contains(word) { return true }
        // "J." / "H. P." — a single letter plus a dot is an initial.
        if word.count == 2, let first = word.first, first.isLetter, word.last == "." { return true }
        return false
    }

    /// True when the caret already sits where a new sentence begins: the start of the field or
    /// of a line, or after a sentence end.
    public static func atSentenceStart(_ text: String) -> Bool {
        if text.isEmpty { return true }
        if text.hasSuffix("\n") || text.hasSuffix("\r") { return true }
        let trimmed = String(text.reversed().drop { $0.isWhitespace }.reversed())
        if trimmed.isEmpty { return true }
        return endsSentence(trimmed)
    }

    /// A letter, digit or joiner-free word character: what "inside a word" means.
    static func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber }

    /// True when text follows the caret on the same line (so the insertion is inside a sentence).
    static func textFollowsOnLine(_ after: String) -> Bool {
        after.prefix { $0 != "\n" && $0 != "\r" }.contains { !$0.isWhitespace }
    }

    /// The plan for inserting at the caret described by `field`, under `rules`.
    public static func plan(for field: FieldContext, rules: FieldRules) -> ContinuationPlan {
        plan(caret: field.caret, rules: rules, preferences: field.preferences)
    }

    /// Compatibility: a caret the caller read, given as the text either side of it.
    public static func plan(before textBefore: String, after textAfter: String = "", rules: FieldRules,
                            preferences: FormattingPreferences = .default) -> ContinuationPlan {
        plan(caret: FieldContext.caret(before: textBefore, after: textAfter), rules: rules, preferences: preferences)
    }

    /// D3 — the continuation table.
    ///
    /// | caret | leading | first word | period |
    /// |---|---|---|---|
    /// | after `[.!?]` + space | none | capital | kept |
    /// | after `[.!?]`, no space | `" "` | capital | kept |
    /// | after a word (or `,` `;` `:`) | `" "` | lowercase | none |
    /// | after an opener (`(`, `"`, `--`, `~/`) | none | as heard | none |
    /// | before a word | — (trailing `" "`) | — | none |
    /// | inside a word | none, no trailing either | lowercase | none |
    /// | empty field | none | capital | only a full clause |
    /// | unknown | **none** | by `UnknownCaretStyle` + word count | by style + word count |
    ///
    /// `SpacingPreference` then overrides the whitespace: `.never` removes both sides, `.always`
    /// adds a leading space unless the text before is known to be empty or to end in whitespace.
    public static func plan(caret: CaretState, rules: FieldRules,
                            preferences: FormattingPreferences = .default) -> ContinuationPlan {
        var plan = ContinuationPlan(caretKind: caret.kind, unknownCaretStyle: preferences.unknownCaretStyle)

        guard let before = caret.textBefore, let after = caret.textAfter else {
            // V4.2 — nothing was read. Invent nothing: no space, no capital, no period.
            plan.leading = preferences.spacing == .always ? " " : ""
            plan.trailing = ""
            plan.capitalizeFirstWord = false
            plan.lowercaseModelCapital = false
            plan.period = .unknownCaret
            return plan
        }

        let sentenceStart = atSentenceStart(before)
        if before.isEmpty {
            plan.leading = ""
            plan.capitalizeFirstWord = rules.autoCapitalize
        } else if let last = before.last, last.isWhitespace {
            plan.leading = ""
            plan.capitalizeFirstWord = rules.autoCapitalize && sentenceStart
        } else if endsWithOpener(before) {
            // `--`, `~/`, `"`, `(` — glue, never a space, never a capital.
            plan.leading = ""
            plan.capitalizeFirstWord = false
        } else {
            plan.leading = " "
            plan.capitalizeFirstWord = rules.autoCapitalize && endsSentence(before)
        }
        // D2 — mid-sentence: after a word, a space after a non-terminal, or `,` `;` `:`.
        plan.lowercaseModelCapital = rules.autoCapitalize && !sentenceStart && !endsWithOpener(before)

        if let next = after.first, !next.isWhitespace, !closers.contains(next), !attaching.contains(next) {
            plan.trailing = " "
        }
        // Inside a word: no spaces on either side.
        if let last = before.last, let next = after.first, isWordCharacter(last), isWordCharacter(next) {
            plan.leading = ""
            plan.trailing = ""
        }

        if textFollowsOnLine(after) || !sentenceStart {
            plan.period = .strip
        } else if before.allSatisfy(\.isWhitespace), after.allSatisfy(\.isWhitespace) {
            plan.period = .fullClause
        } else {
            plan.period = .keep
        }

        switch preferences.spacing {
        case .automatic:
            break
        case .never:
            plan.leading = ""
            plan.trailing = ""
        case .always:
            if let last = before.last, !last.isWhitespace { plan.leading = " " }
            if let next = after.first, !next.isWhitespace, !attaching.contains(next), !closers.contains(next) {
                plan.trailing = " "
            }
        }
        return plan
    }
}
