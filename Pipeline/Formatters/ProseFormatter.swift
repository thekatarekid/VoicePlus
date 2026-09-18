import Foundation
import Shared

/// P1.7 T5 — prose / list register formatter. Deterministic `[TranscriptSpan] -> [TranscriptSpan]`:
/// filler removal, self-correction resolution ("Friday no Thursday"), spoken punctuation commands,
/// list detection ("first … second …", "bullet"), number/date normalization, capitalization.
///
/// Confidence contract (Bet 9): spans below `TranscriptSpan.lowConfidenceThreshold` are never
/// rewritten. They pass through verbatim (provenance appended) and act as barriers for every
/// cross-span transform; if the formatter *would* have touched one it sets `needsRepair`.
///
/// Output keeps one span per input span (audioRange/confidence/alternates untouched). Text that
/// was deleted leaves an empty span; punctuation glues onto the previous word's span. Use
/// `renderedText` (Shared, G0.1) to join the result for injection.
public struct ProseListFormatter: PipelineStage {
    public struct Options: Sendable {
        /// Append a period when the utterance ends without terminal punctuation.
        public var addTerminalPeriod = true
        /// Spell out 0–9 (prose style); larger values become digits.
        public var spellOutSmallNumbers = true
        public init() {}
    }

    public let id: StageID = .formatterProse
    public var options: Options

    public init(options: Options = Options()) { self.options = options }

    public func process(_ spans: [TranscriptSpan], context: StageContext) async throws -> [TranscriptSpan] {
        format(spans, register: context.register)
    }

    /// Synchronous entry point (tests, Lab).
    public func format(_ spans: [TranscriptSpan], register: Utterance.Register = .prose) -> [TranscriptSpan] {
        guard !spans.isEmpty else { return [] }
        var toks = Tokenizer.tokens(from: spans)
        Fillers.remove(&toks)
        SpokenPunctuation.apply(&toks)
        SelfCorrection.resolve(&toks)
        Numbers.normalize(&toks, spellOutSmall: options.spellOutSmallNumbers, spans: spans)
        ListDetector.apply(&toks, forceList: register == .list)
        Capitalizer.apply(&toks, addTerminalPeriod: options.addTerminalPeriod)
        return Assembler.assemble(toks, into: spans, stage: id)
    }
}

// MARK: - Token model

enum TokKind: Equatable {
    case word
    case punct(String)     // glued to previous token, e.g. "," "." "?"
    case open(String)      // glued to the next token, e.g. "(" "\""
    case newline(Int)      // 1 = new line, 2 = new paragraph
    case listMarker        // "1." / "-"; a newline is emitted before it by the assembler
}

struct Tok {
    var text: String
    var span: Int
    var kind: TokKind = .word
    /// Comes from a low-confidence span: never modified, never deleted.
    var locked = false
    var flagged = false

    var lower: String { text.lowercased() }
    var isWord: Bool { kind == .word }
    /// Sentence-ending token (explicit punctuation or a word carrying trailing ".?!").
    var endsSentence: Bool {
        switch kind {
        case .punct(let p): return p == "." || p == "?" || p == "!"
        case .newline, .listMarker: return true
        case .word: return text.last.map { ".?!".contains($0) } ?? false
        case .open: return false
        }
    }
    var isBoundary: Bool {
        if locked { return true }
        if case .word = kind { return endsSentence }
        return true
    }
}

enum Tokenizer {
    static func tokens(from spans: [TranscriptSpan]) -> [Tok] {
        var out: [Tok] = []
        for (i, s) in spans.enumerated() {
            let parts = s.text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            if s.isLowConfidence {
                // Opaque barrier; keep the whole text as one token.
                if !parts.isEmpty { out.append(Tok(text: s.text, span: i, locked: true)) }
                continue
            }
            for p in parts { out.append(Tok(text: String(p), span: i)) }
        }
        return out
    }
}

// MARK: - Fillers

enum Fillers {
    static let single: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "er", "erm", "hmm", "hm", "mm", "ah", "eh"]
    static func remove(_ toks: inout [Tok]) {
        var i = 0
        while i < toks.count {
            let t = toks[i]
            let core = t.lower.trimmingCharacters(in: .punctuationCharacters)
            if t.isWord, single.contains(core) {
                if t.locked { toks[i].flagged = true; i += 1 } else { toks.remove(at: i) }
                continue
            }
            // "you know" mid-sentence (not at start, not followed by a clause continuation verb).
            if !t.locked, t.lower == "you", i + 1 < toks.count, toks[i + 1].lower == "know", !toks[i + 1].locked,
               i > 0, !toks[i - 1].isBoundary, i + 2 < toks.count, !["that", "what", "how", "if", "the", "it"].contains(toks[i + 2].lower) {
                toks.removeSubrange(i...(i + 1))
                continue
            }
            i += 1
        }
    }
}

// MARK: - Spoken punctuation

enum SpokenPunctuation {
    static let single: [String: TokKind] = [
        "comma": .punct(","), "period": .punct("."), "fullstop": .punct("."), "colon": .punct(":"),
        "semicolon": .punct(";"), "hyphen": .punct("-"), "dash": .punct(" —"), "ellipsis": .punct("..."),
        "newline": .newline(1),
    ]
    static let pairs: [String: TokKind] = [
        "full stop": .punct("."), "question mark": .punct("?"), "exclamation mark": .punct("!"),
        "exclamation point": .punct("!"), "new line": .newline(1), "new paragraph": .newline(2),
        "open quote": .open("\""), "close quote": .punct("\""), "end quote": .punct("\""),
        "open paren": .open("("), "close paren": .punct(")"), "open parenthesis": .open("("),
        "close parenthesis": .punct(")"), "open bracket": .open("["), "close bracket": .punct("]"),
        "semi colon": .punct(";"),
    ]

    static func apply(_ toks: inout [Tok]) {
        var out: [Tok] = []
        var i = 0
        while i < toks.count {
            let t = toks[i]
            if t.locked {
                if single[t.lower] != nil { out.append(withFlag(t)) } else { out.append(t) }
                i += 1
                continue
            }
            if i + 1 < toks.count, !toks[i + 1].locked, let kind = pairs[t.lower + " " + toks[i + 1].lower] {
                out.append(Tok(text: "", span: t.span, kind: kind))
                i += 2
                continue
            }
            if let kind = single[t.lower] {
                out.append(Tok(text: "", span: t.span, kind: kind))
                i += 1
                continue
            }
            out.append(t)
            i += 1
        }
        toks = out
    }

    private static func withFlag(_ t: Tok) -> Tok { var c = t; c.flagged = true; return c }
}

// MARK: - Self-correction

enum SelfCorrection {
    enum Class: Equatable { case number, ordinal, weekday, month, capitalized, other }

    static let weekdays: Set<String> = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
    static let months: Set<String> = ["january", "february", "march", "april", "may", "june", "july", "august",
                                      "september", "october", "november", "december"]
    static let stopWords: Set<String> = ["at", "on", "in", "and", "the", "to", "for", "with", "by", "of", "a", "an", "or", "but"]

    static func classify(_ t: Tok) -> Class {
        let l = t.lower
        if Numbers.isNumberWord(l) || Int(l) != nil { return .number }
        if Numbers.ordinalValue(l) != nil { return .ordinal }
        if weekdays.contains(l) { return .weekday }
        if months.contains(l) { return .month }
        if let f = t.text.first, f.isUppercase { return .capitalized }
        return .other
    }

    static func isDateish(_ c: Class) -> Bool { c != .other && c != .capitalized }

    static func resolve(_ toks: inout [Tok]) {
        var i = 0
        while i < toks.count {
            guard toks[i].isWord, !toks[i].locked else { i += 1; continue }
            let l = toks[i].lower
            // Strong markers.
            if l == "scratch", i + 1 < toks.count, toks[i + 1].lower == "that", !toks[i + 1].locked {
                let start = clauseStart(toks, before: i)
                toks.removeSubrange(start...(i + 1))
                i = start
                continue
            }
            var markerLen = 0
            if l == "correction" { markerLen = 1 }
            else if l == "i", i + 1 < toks.count, toks[i + 1].lower == "mean", !toks[i + 1].locked { markerLen = 2 }
            else if l == "no", i + 1 < toks.count, toks[i + 1].lower == "wait", !toks[i + 1].locked { markerLen = 2 }
            else if l == "wait", i + 1 < toks.count, toks[i + 1].lower == "no", !toks[i + 1].locked { markerLen = 2 }
            else if l == "no", i + 1 < toks.count, toks[i + 1].lower == "no", !toks[i + 1].locked { markerLen = 2 }

            if markerLen > 0 {
                // "to John, I mean to Jane": a comma right before a strong marker is part of the restart.
                if i > 0, toks[i - 1].kind == .punct(",") {
                    toks.remove(at: i - 1); i -= 1
                }
                if applyStrong(&toks, marker: i, len: markerLen) { continue }
                i += markerLen
                continue
            }
            // Weak markers: need a class match on both sides.
            if l == "no" || l == "sorry" || l == "actually" || l == "rather" {
                if applyWeak(&toks, marker: i) { continue }
            }
            i += 1
        }
    }

    /// Words before `i` in the same clause (stops at punctuation / locked / sentence end).
    static func clauseStart(_ toks: [Tok], before i: Int) -> Int {
        var s = i
        while s > 0, !toks[s - 1].isBoundary { s -= 1 }
        return s
    }

    static func applyStrong(_ toks: inout [Tok], marker i: Int, len: Int) -> Bool {
        let after = i + len
        guard after < toks.count, i > 0, !toks[i - 1].isBoundary else { return false }
        // Try a class-matched replacement first (handles "twenty five, I mean twenty six").
        if applyWeak(&toks, marker: i, len: len) { return true }
        // Generic: one word, or "<stop word> + words…" mirrored onto the matching stop word
        // before the marker ("to John, I mean to Jane" -> "to Jane").
        guard toks[after].isWord, !toks[after].locked, !toks[after].isBoundary else { return false }
        let start = clauseStart(toks, before: i)
        var r = after + 1
        var pStart = i - 1
        if stopWords.contains(toks[after].lower) {
            while r < toks.count, r - after < 3, toks[r].isWord, !toks[r].locked, !toks[r].isBoundary,
                  !stopWords.contains(toks[r].lower) { r += 1 }
            guard let back = (max(start, i - 5)..<i).reversed().first(where: { toks[$0].lower == toks[after].lower })
            else { return false }
            pStart = back
        }
        guard pStart >= start else { return false }
        toks.removeSubrange(pStart..<after)
        return true
    }

    static func applyWeak(_ toks: inout [Tok], marker i: Int, len: Int = 1) -> Bool {
        let after = i + len
        guard after < toks.count, i > 0 else { return false }
        let prev = toks[i - 1], next = toks[after]
        guard prev.isWord, !prev.locked, !prev.endsSentence, next.isWord, !next.locked else { return false }
        let cp = classify(prev), cn = classify(next)
        let match = (cp == cn && cp != .other) || (isDateish(cp) && isDateish(cn))
        guard match else { return false }
        let run: (Class) -> Bool = isDateish(cn) ? isDateish : { $0 == cn }
        // Replacement run R.
        var r = after
        while r < toks.count, toks[r].isWord, !toks[r].locked, run(classify(toks[r])), r - after < 4 { r += 1 }
        // Preceding run P.
        var p = i
        while p > 0, toks[p - 1].isWord, !toks[p - 1].locked, !toks[p - 1].endsSentence, run(classify(toks[p - 1])), i - p < 4 { p -= 1 }
        let rCount = r - after, pCount = i - p
        guard rCount > 0, pCount > 0 else { return false }
        let remove = min(rCount, pCount)
        toks.removeSubrange((i - remove)..<after)
        return true
    }
}

// MARK: - Numbers and dates

enum Numbers {
    static let units: [String: Int] = [
        "zero": 0, "oh": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    static let tens: [String: Int] = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60,
                                      "seventy": 70, "eighty": 80, "ninety": 90]
    static let scales: [String: Int] = ["hundred": 100, "thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000]
    static let ordinals: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8,
        "ninth": 9, "tenth": 10, "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14, "fifteenth": 15,
        "sixteenth": 16, "seventeenth": 17, "eighteenth": 18, "nineteenth": 19, "twentieth": 20, "thirtieth": 30,
    ]
    static let smallWords = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]

    static func isNumberWord(_ l: String) -> Bool {
        (units[l] != nil && l != "oh") || tens[l] != nil || scales[l] != nil
    }

    static func ordinalValue(_ l: String) -> Int? { ordinals[l] }

    static func suffix(_ n: Int) -> String {
        let m100 = n % 100, m10 = n % 10
        if (11...13).contains(m100) { return "th" }
        return m10 == 1 ? "st" : m10 == 2 ? "nd" : m10 == 3 ? "rd" : "th"
    }

    // MARK: Punctuation-tolerant lookup (E1, V4.11)

    /// Marks the recogniser glues onto a word ("fifty.", "one,"). They are stripped before every
    /// table lookup and re-attached to what is emitted for the last word consumed. A word that
    /// carries one always ends the number: the mark is a boundary somebody heard.
    static let trailingMarks: Set<Character> = [",", ".", ";", ":", "!", "?"]

    /// "fifty." → ("fifty", "."); "a.m.," → ("a.m", ".,"); "hello" → ("hello", "").
    static func split(_ text: String) -> (core: String, mark: String) {
        var end = text.endIndex
        while end > text.startIndex {
            let before = text.index(before: end)
            guard trailingMarks.contains(text[before]) else { break }
            end = before
        }
        return (String(text[..<end]), String(text[end...]))
    }

    /// Lowercased token text without its trailing marks.
    static func core(_ t: Tok) -> String { split(t.lower).core }
    /// The token's trailing marks ("" when it has none).
    static func mark(_ t: Tok) -> String { split(t.text).mark }

    /// A parsed number: its value, the tokens it used, and the trailing mark of the last of them.
    struct Parsed: Equatable {
        var value: Int
        var consumed: Int
        var mark: String
    }

    /// Parses a run of number words starting at `i`.
    static func parse(_ toks: [Tok], at i: Int) -> Parsed? {
        var total = 0, current = 0, j = i, sawAny = false, mark = ""
        while j < toks.count, toks[j].isWord, !toks[j].locked {
            let (l, m) = split(toks[j].lower)
            if let u = units[l], l != "oh" {
                // "five six" and "twenty fifteen" are separate; "one hundred fifteen" is one number.
                if current % 10 != 0 || (current % 100 >= 20 && u >= 10) { break }
                if current > 0, current < 20 { break }                          // "twelve five"
                current += u; sawAny = true
            } else if let t = tens[l] {
                if current % 100 != 0 { break }
                current += t; sawAny = true
            } else if let s = scales[l] {
                if !sawAny { break }
                if s == 100 { current = (current == 0 ? 1 : current) * 100 }
                else { total += (current == 0 ? 1 : current) * s; current = 0 }
            } else if l == "and", m.isEmpty, bridges(toks, at: j, current: current) {
                // "one hundred and twenty"
            } else { break }
            j += 1
            if !m.isEmpty { mark = m; break }
        }
        guard sawAny else { return nil }
        return Parsed(value: total + current, consumed: j - i, mark: mark)
    }

    /// The `and` of "one hundred and fifty": only after a hundreds value, and only when the word
    /// after it — marks stripped ("fifty.") — continues the number.
    static func bridges(_ toks: [Tok], at j: Int, current: Int) -> Bool {
        guard current > 0, current % 100 == 0, j + 1 < toks.count, toks[j + 1].isWord, !toks[j + 1].locked
        else { return false }
        let next = core(toks[j + 1])
        return (units[next] != nil && next != "oh") || tens[next] != nil
    }

    static let unitsAfter: [String: String] = ["percent": "%", "%": "%"]
    static let currencyAfter: [String: String] = ["dollars": "$", "dollar": "$", "bucks": "$", "euros": "€", "pounds": "£"]
    static let timeAfter: Set<String> = ["am", "pm", "a.m.", "p.m.", "o'clock", "oclock"]

    static func isTimeWord(_ t: Tok) -> Bool {
        guard t.isWord, !t.locked else { return false }
        let c = core(t)
        return timeAfter.contains(t.lower) || timeAfter.contains(c) || timeAfter.contains(c + ".")
    }

    /// - Parameter spans: the formatter's input spans. Their `audioRange`s drive the digit-sequence
    ///   and paired-year rules (E2); with none, those rules are off and single digits stay words.
    static func normalize(_ toks: inout [Tok], spellOutSmall: Bool, spans: [TranscriptSpan] = []) {
        var out: [Tok] = []
        var i = 0
        var digitRunBlockedUntil = 0      // E2: a run a low-confidence digit blocked ends here
        while i < toks.count {
            let t = toks[i]
            guard t.isWord, !t.locked else { out.append(t); i += 1; continue }
            let prevIsMonth = out.last.map { SelfCorrection.months.contains($0.lower) && $0.isWord } ?? false
            let (tCore, tMark) = split(t.lower)

            // Ordinal after month: "March fifth" -> "March 5"; "fifth of March" -> "5th of March".
            if let o = ordinalValue(tCore), prevIsMonth || (tMark.isEmpty && i + 2 < toks.count && toks[i + 1].lower == "of"
                                                             && SelfCorrection.months.contains(core(toks[i + 2]))) {
                var day = o, consumed = 1, dayMark = tMark
                if tMark.isEmpty, o >= 20, o % 10 == 0, i + 1 < toks.count, toks[i + 1].isWord, !toks[i + 1].locked,
                   let u = ordinalValue(core(toks[i + 1])), u < 10 {
                    day += u; consumed = 2; dayMark = mark(toks[i + 1])
                }
                out.append(Tok(text: (prevIsMonth ? "\(day)" : "\(day)\(suffix(day))") + dayMark, span: t.span))
                i += consumed
                // Year after "March 5 twenty twenty four" -> "March 5, 2024".
                if prevIsMonth, dayMark.isEmpty, let y = parseYear(toks, at: i) {
                    out.append(Tok(text: ",", span: toks[i].span, kind: .punct(",")))
                    out.append(Tok(text: "\(y.value)" + y.mark, span: toks[i].span))
                    i += y.consumed
                }
                continue
            }
            // Compound ordinal after month using tens + ordinal: "March twenty first".
            if prevIsMonth, tMark.isEmpty, let ten = tens[tCore], i + 1 < toks.count, toks[i + 1].isWord, !toks[i + 1].locked,
               let u = ordinalValue(core(toks[i + 1])), u < 10 {
                let dayMark = mark(toks[i + 1])
                out.append(Tok(text: "\(ten + u)" + dayMark, span: t.span)); i += 2
                if dayMark.isEmpty, let y = parseYear(toks, at: i) {
                    out.append(Tok(text: ",", span: toks[i].span, kind: .punct(",")))
                    out.append(Tok(text: "\(y.value)" + y.mark, span: toks[i].span)); i += y.consumed
                }
                continue
            }

            if let y = parseYear(toks, at: i), prevIsMonth || isYearContext(out) {
                out.append(Tok(text: "\(y.value)" + y.mark, span: t.span)); i += y.consumed; continue
            }

            // E2 (V4.12): spoken digits read by their timing — "1234" or "1, 2, 3, 4".
            if !spans.isEmpty {
                switch i < digitRunBlockedUntil ? nil : DigitSequence.match(toks, at: i, spans: spans) {
                case .rewrite(let tokens, let end)?:
                    out.append(contentsOf: tokens); i = end; continue
                case .blocked(let neighbours, let end)?:
                    // A low-confidence digit would have joined the run: rewrite none of it (not even
                    // the tail that is still ≥ 3 digits long) and flag that digit.
                    digitRunBlockedUntil = end
                    for n in neighbours {
                        if n > i { toks[n].flagged = true } else if let last = out.indices.last, out[last].locked { out[last].flagged = true }
                    }
                case nil:
                    break
                }
                if let y = DigitSequence.pairedYear(toks, at: i, spans: spans) {
                    out.append(Tok(text: "\(y.value)" + y.mark, span: t.span)); i += y.consumed; continue
                }
            }

            guard let number = parse(toks, at: i) else { out.append(t); i += 1; continue }
            let value = number.value, n = number.consumed
            // A mark on the number's last word closes it: nothing after the mark binds to it.
            let next = number.mark.isEmpty && i + n < toks.count ? toks[i + n] : nil
            let nextOK = next.map { $0.isWord && !$0.locked } ?? false
            let (nextCore, nextMark) = next.map { split($0.lower) } ?? (core: "", mark: "")

            // Time: "three thirty pm", "three pm", "seven o'clock".
            if nextOK, value <= 24, let mins = parse(toks, at: i + n), mins.mark.isEmpty, mins.value < 60,
               i + n + mins.consumed < toks.count, isTimeWord(toks[i + n + mins.consumed]) {
                out.append(Tok(text: String(format: "%d:%02d", value, mins.value), span: t.span))
                i += n + mins.consumed; continue
            }
            if nextOK, let next, isTimeWord(next), value <= 24 {
                out.append(Tok(text: "\(value)", span: t.span)); i += n; continue
            }
            if nextOK, let sym = unitsAfter[nextCore] {
                out.append(Tok(text: "\(value)\(sym)" + nextMark, span: t.span)); i += n + 1; continue
            }
            if nextOK, let sym = currencyAfter[nextCore] {
                out.append(Tok(text: "\(sym)\(value)" + nextMark, span: t.span)); i += n + 1; continue
            }
            if prevIsMonth {
                out.append(Tok(text: "\(value)" + number.mark, span: t.span)); i += n; continue
            }
            // "one" alone is usually a pronoun/article ("one of them"); leave single small words.
            if spellOutSmall, value < 10, n == 1 {
                out.append(t); i += 1; continue
            }
            out.append(Tok(text: "\(value)" + number.mark, span: t.span))
            i += n
        }
        toks = out
    }

    /// "twenty twenty four" / "nineteen ninety five" / "two thousand twenty" -> year.
    static func parseYear(_ toks: [Tok], at i: Int) -> Parsed? {
        guard let a = parse(toks, at: i) else { return nil }
        if (1900...2099).contains(a.value) { return a }
        guard a.mark.isEmpty, (19...20).contains(a.value), let b = parse(toks, at: i + a.consumed), b.value < 100,
              b.value >= 1 else { return nil }
        return Parsed(value: a.value * 100 + b.value, consumed: a.consumed + b.consumed, mark: b.mark)
    }

    static func isYearContext(_ out: [Tok]) -> Bool {
        guard let last = out.last(where: { $0.isWord }) else { return false }
        return ["in", "since", "of", "year", "by", "until"].contains(last.lower)
    }
}

// MARK: - Digit sequences (E2, V4.12)

extension Numbers {
    /// Spoken digits read by their timing: "one two three four" said without a pause is one number
    /// (a PIN, a phone number, an amount read digit by digit); said with pauses or spoken commas it
    /// is a list.
    ///
    /// - A run is ≥ 3 consecutive single-digit words (`zero`–`nine`, a bare digit, or `oh` after the
    ///   first), each in its own span: digits that share a span, or whose spans carry no usable
    ///   timing (see `gap`), are left as they are. A word carrying `.?!;:` ends the run and its mark
    ///   stays on the result; a model comma does not end it.
    /// - Between two digits, a spoken comma ("comma", or a span whose punctuation is `.spoken`) or a
    ///   gap of ≥ 250 ms between their `audioRange`s is a break; anything shorter joins them.
    /// - No breaks → one number ("1234"). Only breaks → a list ("1, 2, 3, 4"). Both → groups, split
    ///   by a space where the speaker paused and by ", " where they said "comma" ("982 345 6789").
    /// - Each group is written into its first span; the other spans are left empty (`Assembler`),
    ///   which `renderedText` skips.
    /// - A low-confidence digit next to the run would have been merged into it, so nothing is
    ///   rewritten and that span is flagged for repair (Bet 9).
    enum DigitSequence {
        static let pauseSeconds: TimeInterval = 0.25
        static let minimumRun = 3

        enum Boundary: Equatable { case join, pause, spokenComma }

        enum Outcome {
            /// Replacement tokens for `toks[i..<end]`.
            case rewrite([Tok], end: Int)
            /// Token indices of low-confidence digits touching the run `toks[i..<end]`, which stays
            /// as spoken.
            case blocked([Int], end: Int)
        }

        static func digitValue(_ core: String, allowOh: Bool) -> Int? {
            if core == "oh" { return allowOh ? 0 : nil }
            if let u = units[core], u < 10 { return u }
            if core.count == 1, let d = Int(core) { return d }
            return nil
        }

        static func digit(_ t: Tok, allowOh: Bool) -> Int? {
            guard t.isWord, !t.locked else { return nil }
            return digitValue(core(t), allowOh: allowOh)
        }

        static func isLockedDigit(_ t: Tok) -> Bool {
            t.locked && t.isWord && digitValue(core(t), allowOh: true) != nil
        }

        /// A locked digit before the run that the run would have taken in: one whose own mark does
        /// not close it ("nine." ends a sentence; "nine," is a list item like any other).
        static func joinsFromBefore(_ t: Tok) -> Bool {
            let m = mark(t)
            return isLockedDigit(t) && (m.isEmpty || m == ",")
        }

        /// A "comma" the user said (`SpokenPunctuation` tokens carry no text of their own).
        static func isSpokenComma(_ t: Tok) -> Bool { t.kind == .punct(",") && t.text.isEmpty }

        /// Seconds of silence between two tokens' spans. `nil` — no timing, so no digit rule — when
        /// they share a span, or when the second does not start after the first (identical or
        /// reversed ranges: spans a stage made up, like `0...0` for typed text, carry no pause).
        static func gap(_ a: Tok, _ b: Tok, _ spans: [TranscriptSpan]) -> TimeInterval? {
            guard a.span != b.span, spans.indices.contains(a.span), spans.indices.contains(b.span) else { return nil }
            let first = spans[a.span].audioRange, second = spans[b.span].audioRange
            guard second.lowerBound > first.lowerBound else { return nil }
            return second.lowerBound - first.upperBound
        }

        /// ≥ 250 ms, compared in whole milliseconds so a 0.25 s gap built from float sums is a pause.
        static func isPause(_ gap: TimeInterval) -> Bool { (gap * 1000).rounded() >= pauseSeconds * 1000 }

        static func match(_ toks: [Tok], at i: Int, spans: [TranscriptSpan]) -> Outcome? {
            guard digit(toks[i], allowOh: false) != nil else { return nil }
            var elems = [i]                    // token index of each digit
            var bounds: [Boundary] = []        // bounds[n] sits between elems[n] and elems[n + 1]
            var commas: [Int?] = []            // the spoken comma token at that boundary, if any
            var k = i
            while true {
                let m = mark(toks[k])
                if !m.isEmpty, m != "," { break }                     // ".?!;:" closes the run
                var next = k + 1
                var spoken = m == "," && spans.indices.contains(toks[k].span)
                    && spans[toks[k].span].punctuationOrigin == .spoken
                var comma: Int? = nil
                if next < toks.count, isSpokenComma(toks[next]) { spoken = true; comma = next; next += 1 }
                guard next < toks.count, digit(toks[next], allowOh: true) != nil,
                      let g = gap(toks[k], toks[next], spans) else { break }
                bounds.append(spoken ? .spokenComma : isPause(g) ? .pause : .join)
                commas.append(comma)
                elems.append(next)
                k = next
            }
            // "four five six hundred": the last digit belongs to the scale word after it.
            if elems.count >= 2, let last = elems.last, mark(toks[last]).isEmpty, last + 1 < toks.count,
               toks[last + 1].isWord, !toks[last + 1].locked, scales[core(toks[last + 1])] != nil {
                elems.removeLast(); bounds.removeLast(); commas.removeLast()
            }
            guard elems.count >= minimumRun, let last = elems.last else { return nil }

            let lastMark = mark(toks[last])
            var neighbours: [Int] = []
            if i > 0, joinsFromBefore(toks[i - 1]) { neighbours.append(i - 1) }
            if lastMark.isEmpty || lastMark == ",", last + 1 < toks.count, isLockedDigit(toks[last + 1]) {
                neighbours.append(last + 1)
            }
            if !neighbours.isEmpty { return .blocked(neighbours, end: last + 1) }

            let pausesAreSpaces = bounds.contains(.join)
            var result: [Tok] = []
            var text = "", span = toks[i].span
            for (n, e) in elems.enumerated() {
                if n > 0, bounds[n - 1] != .join {
                    let previous = toks[elems[n - 1]]
                    result.append(Tok(text: text, span: span))
                    if bounds[n - 1] == .spokenComma {
                        // Keep the user's own comma token (it carries the spoken mark to the Assembler).
                        result.append(commas[n - 1].map { toks[$0] } ?? Tok(text: "", span: previous.span, kind: .punct(",")))
                    } else if !pausesAreSpaces {
                        result.append(Tok(text: ",", span: previous.span, kind: .punct(",")))
                    }
                    text = ""; span = toks[e].span
                }
                text += String(digitValue(core(toks[e]), allowOh: true) ?? 0)
            }
            result.append(Tok(text: text + lastMark, span: span))
            return .rewrite(result, end: last + 1)
        }

        /// "twenty twenty six" / "nineteen ninety five" / "twenty oh five": a year said as two pairs
        /// with no pause between them. Outside a year context — `parseYear` already covers "in …".
        /// Not before a currency or unit word: "nineteen ninety nine dollars" is a price, and stays
        /// what the amount rules make of it.
        static func pairedYear(_ toks: [Tok], at i: Int, spans: [TranscriptSpan]) -> Parsed? {
            guard let a = parse(toks, at: i), a.consumed == 1, a.mark.isEmpty, (19...20).contains(a.value),
                  i + 1 < toks.count, let g = gap(toks[i], toks[i + 1], spans), !isPause(g) else { return nil }
            let j = i + 1
            let year: Parsed
            if digit(toks[j], allowOh: true) == 0, mark(toks[j]).isEmpty, j + 1 < toks.count,
               let d = digit(toks[j + 1], allowOh: false), d > 0,
               let g2 = gap(toks[j], toks[j + 1], spans), !isPause(g2) {
                year = Parsed(value: a.value * 100 + d, consumed: 3, mark: mark(toks[j + 1]))   // "twenty oh five"
            } else {
                guard let b = parse(toks, at: j), (10...99).contains(b.value) else { return nil }
                year = Parsed(value: a.value * 100 + b.value, consumed: 1 + b.consumed, mark: b.mark)
            }
            let after = i + year.consumed
            if year.mark.isEmpty, after < toks.count, toks[after].isWord, !toks[after].locked,
               unitsAfter[core(toks[after])] != nil || currencyAfter[core(toks[after])] != nil {
                return nil
            }
            return year
        }
    }
}

// MARK: - Lists

enum ListDetector {
    static let ordinalWords = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth"]
    static let finalWords: Set<String> = ["finally", "lastly", "last"]
    /// "first of all", "first line", "second time" … are not list items.
    static let notListNoun: Set<String> = ["of", "line", "time", "thing", "one", "half", "place", "floor", "name",
                                           "step", "person", "class", "draft", "round", "day", "week", "year"]

    static func apply(_ toks: inout [Tok], forceList: Bool) {
        var markers: [(index: Int, len: Int, bullet: Bool, number: Int)] = []
        var expected = 1
        var i = 0
        while i < toks.count {
            let t = toks[i]
            defer { i += 1 }
            guard t.isWord, !t.locked else { continue }
            let l = t.lower
            let next = i + 1 < toks.count ? toks[i + 1] : nil
            // "bullet" / "bullet point" / "next bullet" / "new bullet"
            if l == "bullet" {
                let len = (next?.lower == "point") ? 2 : 1
                markers.append((i, len, true, 0)); continue
            }
            if (l == "next" || l == "new"), next?.lower == "bullet", next?.locked == false {
                markers.append((i, 2, true, 0)); continue
            }
            // "number one" / "number two"
            if l == "number", let n = next, let v = Numbers.units[n.lower] ?? Int(n.lower), v == expected, !n.locked {
                markers.append((i, 2, false, v)); expected += 1; continue
            }
            if let idx = ordinalWords.firstIndex(of: l), idx + 1 == expected, !(next.map { notListNoun.contains($0.lower) } ?? false) {
                // "at first", "the first" are not list starts.
                if expected == 1, i > 0, ["at", "the", "my", "his", "her", "their", "our"].contains(toks[i - 1].lower) { continue }
                markers.append((i, 1, false, expected)); expected += 1; continue
            }
            if expected > 2, finalWords.contains(l), i + 1 < toks.count {
                markers.append((i, 1, false, expected)); expected += 1; continue
            }
        }
        let numbered = markers.filter { !$0.bullet }
        let bullets = markers.filter { $0.bullet }
        // Explicit "new line" commands mean the user is laying out text by hand; don't number ordinals.
        let hasNewlineCommands = toks.contains { if case .newline = $0.kind { return true }; return false }
        let useNumbered = !hasNewlineCommands && (numbered.count >= 2 || (forceList && numbered.count >= 1))
        let active = (useNumbered ? numbered : []) + bullets
        guard !active.isEmpty else { return }

        var bulletCount = 0
        for m in active.sorted(by: { $0.index > $1.index }) {  // back to front so indices stay valid
            var rep: [Tok] = []
            let span = toks[m.index].span
            if m.bullet { rep.append(Tok(text: "-", span: span, kind: .listMarker)); bulletCount += 1 }
            else { rep.append(Tok(text: "\(m.number).", span: span, kind: .listMarker)) }
            var end = m.index + m.len
            // Drop a comma/colon/"of all" right after the marker.
            if end < toks.count, case .punct(let p) = toks[end].kind, p == "," || p == ":" { end += 1 }
            toks.replaceSubrange(m.index..<end, with: rep)
            // Intro text before the first marker gets a colon if it ends on a bare word.
            if m.index > 0, m.index == active.map(\.index).min(), toks[m.index - 1].isWord, !toks[m.index - 1].locked,
               !toks[m.index - 1].endsSentence {
                toks.insert(Tok(text: ":", span: toks[m.index - 1].span, kind: .punct(":")), at: m.index)
            }
            // Strip trailing comma/period from the previous item's content.
            if m.index > 0, case .punct(let p) = toks[m.index - 1].kind, p == "," || p == "." || p == ";" {
                toks.remove(at: m.index - 1)
            }
        }
    }
}

// MARK: - Capitalization

enum Capitalizer {
    static let always: Set<String> = SelfCorrection.weekdays.union(SelfCorrection.months)
    static let iForms: Set<String> = ["i", "i'm", "i'll", "i've", "i'd"]

    static func apply(_ toks: inout [Tok], addTerminalPeriod: Bool) {
        var capNext = true
        for i in toks.indices {
            let t = toks[i]
            switch t.kind {
            case .word:
                guard !t.locked else { capNext = t.endsSentence; continue }
                var text = t.text
                let l = t.lower
                if iForms.contains(l) { text = "I" + text.dropFirst() }
                else if always.contains(l) { text = text.prefix(1).uppercased() + text.dropFirst() }
                if capNext, let f = text.first, f.isLetter { text = f.uppercased() + text.dropFirst() }
                toks[i].text = text
                capNext = t.endsSentence
            case .punct(let p):
                capNext = p == "." || p == "?" || p == "!" || (p == "\"" && capNext)
            case .newline, .listMarker:
                capNext = true
            case .open:
                break
            }
        }
        guard addTerminalPeriod, let lastWord = toks.lastIndex(where: { $0.isWord }) else { return }
        let inList = toks.contains { $0.kind == .listMarker }
        let trailing = toks[(lastWord + 1)...]
        let hasTerminal = toks[lastWord].endsSentence || trailing.contains { t in
            if case .punct(let p) = t.kind { return p != "\"" && p != ")" } ; return false
        }
        if !hasTerminal, !inList, !toks[lastWord].locked, trailing.allSatisfy({ if case .punct = $0.kind { return true }; return false }) {
            toks.append(Tok(text: ".", span: toks[lastWord].span, kind: .punct(".")))
        }
    }
}

// MARK: - Assembly

/// Writes the tokens back into the input spans: each token's text goes into the span it names, so
/// a number built from several words (E1/E2: "5150", "2340") sits in its first span and the spans
/// it consumed are left empty — `renderedText` skips them, so no stray spaces reach the field.
/// Punctuation glues onto the span holding the previous word; every span keeps its own
/// `audioRange`, confidence, alternates and `punctuationOrigin`.
enum Assembler {
    static func assemble(_ toks: [Tok], into spans: [TranscriptSpan], stage: StageID) -> [TranscriptSpan] {
        var texts = [String](repeating: "", count: spans.count)
        var flagged = [Bool](repeating: false, count: spans.count)
        var lastSpan: Int? = nil          // span that holds the previous emitted word
        var pendingOpen: [(String, Int)] = []
        var pendingNewline: String? = nil

        func append(_ s: String, to span: Int, glue: Bool) {
            if texts[span].isEmpty || glue { texts[span] += s } else { texts[span] += " " + s }
        }

        for t in toks {
            if t.flagged { flagged[t.span] = true }
            switch t.kind {
            case .word:
                var word = t.text
                if let nl = pendingNewline { word = nl + word; pendingNewline = nil }
                for (o, _) in pendingOpen { word = o + word }
                pendingOpen.removeAll()
                append(word, to: t.span, glue: word.hasPrefix("\n"))
                lastSpan = t.span
            case .listMarker:
                var marker = t.text
                let isFirstContent = texts.allSatisfy { $0.isEmpty }
                if let nl = pendingNewline { marker = nl + marker; pendingNewline = nil }
                else if !isFirstContent { marker = "\n" + marker }
                append(marker, to: t.span, glue: marker.hasPrefix("\n"))
                lastSpan = t.span
            case .punct(let p):
                if let ls = lastSpan, !spans[ls].isLowConfidence, !texts[ls].isEmpty {
                    texts[ls] += p
                } else {
                    append(p, to: t.span, glue: true)
                    lastSpan = t.span
                }
            case .open(let o):
                pendingOpen.append((o, t.span))
            case .newline(let n):
                pendingNewline = String(repeating: "\n", count: n)
            }
        }
        if let nl = pendingNewline, let ls = lastSpan { texts[ls] += nl }

        return spans.enumerated().map { i, s in
            if s.isLowConfidence {
                return flagged[i] ? s.flaggedForRepair(by: stage) : s.touched(by: stage)
            }
            return s.rewritten(texts[i], by: stage)
        }
    }
}
