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
/// `renderedText` (below) to join the result for injection.
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
        Numbers.normalize(&toks, spellOutSmall: options.spellOutSmallNumbers)
        ListDetector.apply(&toks, forceList: register == .list)
        Capitalizer.apply(&toks, addTerminalPeriod: options.addTerminalPeriod)
        return Assembler.assemble(toks, into: spans, stage: id)
    }
}

public extension Array where Element == TranscriptSpan {
    /// Joins span texts for injection: single spaces between words, none around newlines,
    /// empty spans skipped.
    var renderedText: String {
        var out = ""
        for s in self where !s.text.isEmpty {
            if !out.isEmpty, !out.hasSuffix("\n"), !s.text.hasPrefix("\n") { out += " " }
            out += s.text
        }
        return out
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

    /// Parses a run of number words starting at `i`. Returns (value, tokensConsumed).
    static func parse(_ toks: [Tok], at i: Int) -> (Int, Int)? {
        var total = 0, current = 0, j = i, sawAny = false
        while j < toks.count, toks[j].isWord, !toks[j].locked {
            let l = toks[j].lower
            if let u = units[l], l != "oh" {
                if current % 10 != 0 || (current >= 20 && u >= 10) { break }  // "five six" are separate
                if current > 0, current < 20 { break }                          // "twelve five"
                current += u; sawAny = true
            } else if let t = tens[l] {
                if current % 100 != 0 { break }
                current += t; sawAny = true
            } else if let s = scales[l] {
                if !sawAny { break }
                if s == 100 { current = (current == 0 ? 1 : current) * 100 }
                else { total += (current == 0 ? 1 : current) * s; current = 0 }
            } else if l == "and", sawAny, current % 100 == 0, current > 0, j + 1 < toks.count,
                      (units[toks[j + 1].lower] != nil || tens[toks[j + 1].lower] != nil) {
                // "one hundred and twenty"
            } else { break }
            j += 1
        }
        guard sawAny else { return nil }
        return (total + current, j - i)
    }

    static let unitsAfter: [String: String] = ["percent": "%", "%": "%"]
    static let currencyAfter: [String: String] = ["dollars": "$", "dollar": "$", "bucks": "$", "euros": "€", "pounds": "£"]
    static let timeAfter: Set<String> = ["am", "pm", "a.m.", "p.m.", "o'clock", "oclock"]

    static func normalize(_ toks: inout [Tok], spellOutSmall: Bool) {
        var out: [Tok] = []
        var i = 0
        while i < toks.count {
            let t = toks[i]
            guard t.isWord, !t.locked else { out.append(t); i += 1; continue }
            let prevIsMonth = out.last.map { SelfCorrection.months.contains($0.lower) && $0.isWord } ?? false

            // Ordinal after month: "March fifth" -> "March 5"; "fifth of March" -> "5th of March".
            if let o = ordinalValue(t.lower), prevIsMonth || (i + 2 < toks.count && toks[i + 1].lower == "of" && SelfCorrection.months.contains(toks[i + 2].lower)) {
                var day = o
                var consumed = 1
                if o >= 20, o % 10 == 0, i + 1 < toks.count, let u = ordinalValue(toks[i + 1].lower), u < 10 { day += u; consumed = 2 }
                out.append(Tok(text: prevIsMonth ? "\(day)" : "\(day)\(suffix(day))", span: t.span))
                i += consumed
                // Year after "March 5 twenty twenty four" -> "March 5, 2024".
                if prevIsMonth, let (y, n) = parseYear(toks, at: i) {
                    out.append(Tok(text: ",", span: toks[i].span, kind: .punct(",")))
                    out.append(Tok(text: "\(y)", span: toks[i].span))
                    i += n
                }
                continue
            }
            // Compound ordinal after month using tens + ordinal: "March twenty first".
            if prevIsMonth, let ten = tens[t.lower], i + 1 < toks.count, let u = ordinalValue(toks[i + 1].lower), u < 10 {
                out.append(Tok(text: "\(ten + u)", span: t.span)); i += 2
                if let (y, n) = parseYear(toks, at: i) {
                    out.append(Tok(text: ",", span: toks[i].span, kind: .punct(",")))
                    out.append(Tok(text: "\(y)", span: toks[i].span)); i += n
                }
                continue
            }

            if let (y, n) = parseYear(toks, at: i), prevIsMonth || isYearContext(out) {
                out.append(Tok(text: "\(y)", span: t.span)); i += n; continue
            }
            guard let (value, n) = parse(toks, at: i) else { out.append(t); i += 1; continue }
            let next = i + n < toks.count ? toks[i + n] : nil
            let nextLower = next?.lower ?? ""
            let nextOK = next.map { $0.isWord && !$0.locked } ?? false

            // Time: "three thirty pm", "three pm", "seven o'clock".
            if nextOK, value <= 24, let (mins, m) = parse(toks, at: i + n), mins < 60, i + n + m < toks.count,
               timeAfter.contains(toks[i + n + m].lower), toks[i + n + m].isWord {
                out.append(Tok(text: String(format: "%d:%02d", value, mins), span: t.span))
                i += n + m; continue
            }
            if nextOK, timeAfter.contains(nextLower), value <= 24 {
                out.append(Tok(text: "\(value)", span: t.span)); i += n; continue
            }
            if nextOK, let sym = unitsAfter[nextLower] {
                out.append(Tok(text: "\(value)\(sym)", span: t.span)); i += n + 1; continue
            }
            if nextOK, let sym = currencyAfter[nextLower] {
                out.append(Tok(text: "\(sym)\(value)", span: t.span)); i += n + 1; continue
            }
            if prevIsMonth {
                out.append(Tok(text: "\(value)", span: t.span)); i += n; continue
            }
            // "one" alone is usually a pronoun/article ("one of them"); leave single small words.
            if spellOutSmall, value < 10, n == 1 {
                out.append(t); i += 1; continue
            }
            out.append(Tok(text: "\(value)", span: t.span))
            i += n
        }
        toks = out
    }

    /// "twenty twenty four" / "nineteen ninety five" / "two thousand twenty" -> year.
    static func parseYear(_ toks: [Tok], at i: Int) -> (Int, Int)? {
        guard let (a, n) = parse(toks, at: i) else { return nil }
        if (1900...2099).contains(a) { return (a, n) }
        guard (19...20).contains(a), let (b, m) = parse(toks, at: i + n), b < 100, b >= 1 || toks[i + n].lower == "hundred" else { return nil }
        return (a * 100 + b, n + m)
    }

    static func isYearContext(_ out: [Tok]) -> Bool {
        guard let last = out.last(where: { $0.isWord }) else { return false }
        return ["in", "since", "of", "year", "by", "until"].contains(last.lower)
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
