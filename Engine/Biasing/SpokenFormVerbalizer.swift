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
        guard !t.isEmpty else { return [] }
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

    /// An all-capitals letters-only term short enough to be spelled ("GPT", "NASA"), which is also
    /// read as a word from three letters on.
    static func isSpelledInitialism(_ t: String) -> Bool {
        (3...maxSpelledLetters).contains(t.count) && t.allSatisfy { $0.isLetter && $0.isUppercase }
    }

    /// True when the term has a spoken form the matcher and booster can work from: one the user
    /// typed, or one this verbalizer derives.
    public static func hasSpokenForm(_ term: String, typed: [String] = []) -> Bool {
        typed.contains { !collapse($0).isEmpty } || !forms(for: term).isEmpty
    }

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
            if c.isLetter {
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
