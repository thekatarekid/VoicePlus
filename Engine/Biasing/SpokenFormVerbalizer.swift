import Foundation

// Context Writer §2.4 / investigation A1 — principled spoken forms for alphanumerics and acronyms.
//
// "a16z" is heard "a sixteen z" (or "a one six z"), "k8s" "k eight s", "GPT-4o" "g p t four o",
// "3.5" "three point five". The recogniser writes what it hears, so the vocabulary matcher and the
// booster need the heard shape of every written term. This is the model-free subset: digits as
// number words and as digit sequences, letters as letter names, a decimal point as "point", a short
// initialism spelled and also read as a word ("NASA": "n a s a", "nasa"), plus `HeardAliases`'
// separator and camelCase splits. A spoken form is words only: a split that still carries digits
// ("GPT 4o") is a written variant, not something anyone says — the digits are already spoken in
// the forms above, and the matcher reads heard digits the same way (`reading(of:)`). A plain word
// ("Kothari", "Qwen") has no verbalized form — how it is pronounced is the user's to type, or the
// enrichment pass's to guess. Deterministic: the same term always yields the same forms in order.
//
// What it will not say: a term holding a symbol that is spoken but that this verbalizer does not
// read ("C++", "C#", "AT&T", "x@y", "100%") gets no form at all — its written form is not a spoken
// form either — so it is matched and boosted only through a form the user typed ("c plus plus").
// Reading "+" / "#" / "&" aloud is deliberately not attempted: the booster spots the written form,
// and a guessed reading that is wrong is worse than none. A dotted abbreviation is spelled
// ("U.S." → "u s", "Ph.D." → "p h d"); a dot inside a longer word is said ("node.js" →
// "node dot js"). Single letters are encoded by their names (`letterNames`), so "h" and "w" carry
// sound and "c" sounds like the "see" a recogniser may write.

public enum SpokenFormVerbalizer {
    /// Most forms generated for one term (the cartesian product of its segments is cut here).
    public static let maxForms = 8
    /// An all-capitals run up to this long is an initialism and is spelled out ("g p t"); longer
    /// ones ("NVIDIA") are read as a word.
    public static let maxSpelledLetters = 5

    /// Spoken forms of `term` other than the term itself, case-insensitively distinct, in a fixed
    /// order: number-word readings before digit-by-digit ones, spelled initialisms before the
    /// initialism read as a word, then `HeardAliases`' digit-free splits. Empty for a plain word or
    /// phrase. The one form that may equal the term is an initialism's word reading ("NASA" →
    /// "nasa"): it says the term is also pronounced as a word, not only spelled.
    public static func forms(for term: String) -> [String] {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !hasUnsayableSymbol(t) else { return [] }
        let own = collapse(t).lowercased()
        var seen: Set<String> = isSpelledInitialism(t) ? [] : [own]
        var out: [String] = []
        func add(_ form: String) {
            let s = collapse(form)
            guard !s.isEmpty, seen.insert(s.lowercased()).inserted else { return }
            out.append(s)
        }
        for combo in product(segments(t).map(\.alternatives), limit: maxForms) {
            add(combo.joined(separator: " "))
        }
        for alias in HeardAliases.aliases(for: t) where !alias.contains(where: \.isNumber) { add(alias) }
        return out
    }

    /// How a heard token with digits is said: digit runs as number words, letter runs as the
    /// verbalizer reads them, the first reading only ("4o" → "four o", "a16z" → "a sixteen z",
    /// "gpt-4o" → "gpt four o"). Nil when the token has no digit (it is already words).
    public static func reading(of token: String) -> String? {
        guard token.contains(where: \.isNumber) else { return nil }
        let words = segments(token).compactMap(\.alternatives.first)
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    /// The letters of a whole-token dotted abbreviation ("U.S." / "u.s" → ["u", "s"], "Ph.D." →
    /// ["p", "h", "d"]); nil for anything else ("node.js", "ok"). Heard tokens and forms are both
    /// read this way (`PhoneticEncoder.spokenWords`).
    public static func spelledAbbreviation(_ token: String) -> [String]? {
        let chars = Array(token)
        guard let a = dottedAbbreviation(chars, at: 0), a.end == chars.count else { return nil }
        return a.letters
    }

    /// Symbols that are said aloud but that this verbalizer does not read. A term holding one has no
    /// derived form (and its written form is not a spoken form): only a typed form can voice it.
    public static let unsayableSymbols: Set<Character> = ["+", "#", "&", "@", "%", "$", "=", "<", ">", "|", "~", "^", "\\"]

    public static func hasUnsayableSymbol(_ term: String) -> Bool {
        term.contains { unsayableSymbols.contains($0) }
    }

    /// How each letter is said, for the phonetic code of a single-letter word: Double Metaphone
    /// gives "h" and "w" no sound at all and "c" the sound of "k", while a spelled initialism is said
    /// letter by letter ("a w s", "h t m l") and a recogniser may write the names ("see", "gee").
    public static let letterNames: [Character: [String]] = [
        "a": ["ay"], "b": ["bee"], "c": ["see"], "d": ["dee"], "e": ["ee"], "f": ["ef"], "g": ["gee"],
        "h": ["aitch"], "i": ["eye"], "j": ["jay"], "k": ["kay"], "l": ["el"], "m": ["em"], "n": ["en"],
        "o": ["oh"], "p": ["pee"], "q": ["cue"], "r": ["ar"], "s": ["ess"], "t": ["tee"], "u": ["you"],
        "v": ["vee"], "w": ["double", "you"], "x": ["ex"], "y": ["why"], "z": ["zee"],
    ]

    /// An all-capitals letters-only term short enough to be spelled ("GPT", "NASA"), which is also
    /// read as a word from three letters on.
    static func isSpelledInitialism(_ t: String) -> Bool {
        (3...maxSpelledLetters).contains(t.count) && t.allSatisfy { $0.isLetter && $0.isUppercase }
    }

    /// True when the term has a spoken form the matcher and booster can work from: one the user
    /// typed (a typed form without a letter or digit, "-", says nothing and does not count), or one
    /// this verbalizer derives. Runs at hotkey-down over the Dictionary (`BoostVocabulary`): the
    /// derived half is memoised per term, so a steady Dictionary costs one lookup per row.
    public static func hasSpokenForm(_ term: String, typed: [String] = []) -> Bool {
        typed.contains(where: isSayable) || hasDerivedForm(term)
    }

    /// A typed spoken form says something only when it holds a letter or a digit.
    static func isSayable(_ form: String) -> Bool { form.contains { $0.isLetter || $0.isNumber } }

    /// `!forms(for:).isEmpty`, memoised per term (bounded; see `DerivedFormMemo`).
    static func hasDerivedForm(_ term: String) -> Bool {
        derivedFormMemo.value(term) { !forms(for: term).isEmpty }
    }

    static let derivedFormMemo = DerivedFormMemo()

    // MARK: segmentation

    struct Segment {
        /// Spoken alternatives for this piece; an empty list means "a word boundary".
        var alternatives: [String]
    }

    /// Letters runs, digit runs, decimal points and boundaries, in order. Every run becomes its
    /// own spoken word(s): "a16z" is three segments, "a", "16", "z".
    static func segments(_ term: String) -> [Segment] {
        let chars = Array(term)
        var out: [Segment] = []
        var i = 0
        var afterDecimalPoint = false
        while i < chars.count {
            let c = chars[i]
            if c.isLetter, i == 0 || chars[i - 1] != ".", let a = dottedAbbreviation(chars, at: i) {
                out.append(Segment(alternatives: [a.letters.joined(separator: " ")]))   // "U.S." → "u s"
                afterDecimalPoint = false
                i = a.end
            } else if c.isLetter {
                var j = i
                while j < chars.count, chars[j].isLetter { j += 1 }
                out.append(Segment(alternatives: lettersAlternatives(String(chars[i..<j]))))
                afterDecimalPoint = false
                i = j
            } else if c.isNumber {
                var j = i
                while j < chars.count, chars[j].isNumber { j += 1 }
                let digits = String(chars[i..<j])
                out.append(Segment(alternatives: afterDecimalPoint ? [digitSequence(digits)] : digitsAlternatives(digits)))
                afterDecimalPoint = false
                i = j
            } else if c == "." {
                let prevDigit = i > 0 && chars[i - 1].isNumber, nextDigit = i + 1 < chars.count && chars[i + 1].isNumber
                let prevLetter = i > 0 && chars[i - 1].isLetter, nextLetter = i + 1 < chars.count && chars[i + 1].isLetter
                if prevDigit && nextDigit {
                    out.append(Segment(alternatives: ["point"]))
                    afterDecimalPoint = true
                } else if prevLetter && nextLetter {
                    out.append(Segment(alternatives: ["dot"]))   // "node.js" → "node dot js"
                }
                i += 1
            } else {
                i += 1   // separators, whitespace, apostrophes, symbols: a word boundary
            }
        }
        return out.filter { !$0.alternatives.isEmpty }
    }

    /// A dotted abbreviation starting at `start`: two or more runs of one or two letters, each
    /// followed by a dot except perhaps the last ("U.S.", "U.S.A", "e.g.", "Ph.D."). Returns its
    /// letters, lower-cased, and the index just past it (its last dot included). A longer run
    /// ("node.js") or a run followed by a digit is not one.
    static func dottedAbbreviation(_ chars: [Character], at start: Int) -> (letters: [String], end: Int)? {
        var letters: [String] = []
        var runs = 0
        var i = start
        var end = start
        while i < chars.count, chars[i].isLetter {
            var j = i
            while j < chars.count, chars[j].isLetter { j += 1 }
            guard j - i <= 2, j == chars.count || !chars[j].isNumber else { return nil }
            letters += chars[i..<j].map { String($0).lowercased() }
            runs += 1
            end = j
            guard j < chars.count, chars[j] == "." else { break }
            end = j + 1
            i = j + 1
        }
        return runs >= 2 ? (letters, end) : nil
    }

    /// A single letter is its name; an all-capitals run of 2…`maxSpelledLetters` is spelled, and
    /// from 3 letters also read as a word ("gpt"); anything else is read as a word (camelCase split
    /// into its parts, lowercased).
    static func lettersAlternatives(_ run: String) -> [String] {
        if run.count == 1 { return [run.lowercased()] }
        if run.allSatisfy(\.isUppercase) {
            guard run.count <= maxSpelledLetters else { return [run.lowercased()] }
            let spelled = run.lowercased().map(String.init).joined(separator: " ")
            return run.count >= 3 ? [spelled, run.lowercased()] : [spelled]
        }
        return [HeardAliases.splitCamel(run).lowercased()]
    }

    /// Number words first ("sixteen"), then the digit sequence ("one six") for 2–4 digit runs. A
    /// leading zero or more than four digits (ids, phone numbers) is read digit by digit only; a
    /// four-digit run also gets its pair reading ("twenty twenty four") when it has one.
    static func digitsAlternatives(_ digits: String) -> [String] {
        guard let value = Int(digits), digits.count <= 4, !(digits.count > 1 && digits.hasPrefix("0")) else {
            return [digitSequence(digits)]
        }
        var out = [numberWords(value)]
        if digits.count >= 2 { out.append(digitSequence(digits)) }
        if digits.count == 4, let head = Int(digits.prefix(2)), let tail = Int(digits.suffix(2)), head >= 10, tail != 0 {
            out.append(numberWords(head) + " " + (tail < 10 ? "oh " + numberWords(tail) : numberWords(tail)))
        }
        return out
    }

    static func digitSequence(_ digits: String) -> String {
        digits.compactMap { $0.wholeNumberValue.map { ones[$0] } }.joined(separator: " ")
    }

    static let ones = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                       "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
    static let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]

    /// 0…9999 in American English without "and" ("one hundred twenty three").
    static func numberWords(_ n: Int) -> String {
        precondition(n >= 0 && n <= 9999)
        if n < 20 { return ones[n] }
        if n < 100 { return n % 10 == 0 ? tens[n / 10] : tens[n / 10] + " " + ones[n % 10] }
        if n < 1000 { return ones[n / 100] + " hundred" + (n % 100 == 0 ? "" : " " + numberWords(n % 100)) }
        return ones[n / 1000] + " thousand" + (n % 1000 == 0 ? "" : " " + numberWords(n % 1000))
    }

    /// Cartesian product in segment order, cut at `limit` results.
    static func product(_ lists: [[String]], limit: Int) -> [[String]] {
        var out: [[String]] = [[]]
        for alternatives in lists {
            var next: [[String]] = []
            for prefix in out {
                for a in alternatives where next.count < limit { next.append(prefix + [a]) }
            }
            out = next
        }
        return out
    }

    static func collapse(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// Whether a term has a derived spoken form, remembered per term string. `hasSpokenForm` runs over
/// every Dictionary row at hotkey-down; the Dictionary changes rarely, so after the first utterance
/// each row costs a dictionary lookup instead of a verbalization. Bounded: past `limit` terms the
/// memo starts over. Holds only Dictionary terms, in memory, never logged.
final class DerivedFormMemo: @unchecked Sendable {
    static let limit = 20_000
    private let lock = NSLock()
    private var known: [String: Bool] = [:]

    func value(_ term: String, _ compute: () -> Bool) -> Bool {
        if let hit = lock.withLock({ known[term] }) { return hit }
        let v = compute()
        lock.withLock {
            if known.count >= Self.limit { known.removeAll(keepingCapacity: true) }
            known[term] = v
        }
        return v
    }

    var count: Int { lock.withLock { known.count } }
    func isKnown(_ term: String) -> Bool { lock.withLock { known[term] != nil } }
}
