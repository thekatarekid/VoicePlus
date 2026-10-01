import Foundation
import Shared

// V5 D1 — the two ITN layers that are not `Numbers`: en-IN locale rules and the NeMo residual pass.
// Both work on `Tok`s (ProseFormatter.swift) so a rewrite lands in its first span and the spans it
// consumed are left empty — the same convention as the digit-sequence rule; `renderedText` skips them.

// MARK: - en-IN: lakh / crore, ₹, day-first dates

enum IndianNumbers {
    static let lakh: Set<String> = ["lakh", "lakhs", "lac", "lacs"]
    static let crore: Set<String> = ["crore", "crores"]
    static let rupees: Set<String> = ["rupees", "rupee", "rs"]

    static func apply(_ toks: inout [Tok]) {
        var out: [Tok] = []
        var i = 0
        while i < toks.count {
            let t = toks[i]
            guard t.isWord, !t.locked else { out.append(t); i += 1; continue }
            if let (tokens, end) = date(toks, at: i) {
                out.append(contentsOf: tokens); i = end; continue
            }
            if let (tok, end) = amount(toks, at: i) {
                out.append(tok); i = end; continue
            }
            // Not ours: skip the whole number run so no rule starts in the middle of it.
            let run = Numbers.parse(toks, at: i)?.consumed ?? 1
            out.append(contentsOf: toks[i..<(i + run)]); i += run
        }
        toks = out
    }

    /// "twelve lakh" → `12,00,000`; "two crore fifty lakh" → `2,50,00,000`; "five lakh rupees" →
    /// `₹5,00,000`; "two thousand three hundred forty rupees" → `₹2,340`.
    static func amount(_ toks: [Tok], at i: Int) -> (Tok, Int)? {
        var total = 0, j = i, mark = "", sawScale = false
        while j < toks.count, let n = Numbers.parse(toks, at: j) {
            let k = j + n.consumed
            let scaleWord = n.mark.isEmpty && k < toks.count && toks[k].isWord && !toks[k].locked ? Numbers.core(toks[k]) : ""
            if crore.contains(scaleWord) || lakh.contains(scaleWord) {
                total += n.value * (crore.contains(scaleWord) ? 10_000_000 : 100_000)
                sawScale = true
                mark = Numbers.mark(toks[k])
                j = k + 1
                if !mark.isEmpty { break }
                continue
            }
            // A plain number: the tail of a lakh/crore amount ("two lakh fifty thousand"), or a lone
            // amount that only counts when rupees follow.
            if sawScale, n.value < 100_000 { total += n.value; j = k; mark = n.mark }
            else if !sawScale { total = n.value; j = k; mark = n.mark }
            break
        }
        guard j > i else { return nil }
        var withRupee = false
        if mark.isEmpty, j < toks.count, toks[j].isWord, !toks[j].locked, rupees.contains(Numbers.core(toks[j])) {
            withRupee = true
            mark = Numbers.mark(toks[j])
            j += 1
        }
        guard sawScale || withRupee else { return nil }
        return (Tok(text: (withRupee ? "₹" : "") + grouped(total) + mark, span: toks[i].span), j)
    }

    /// Indian digit grouping: last three, then pairs — 1200000 → `12,00,000`.
    static func grouped(_ value: Int) -> String {
        let digits = Array(String(value))
        guard digits.count > 3 else { return String(digits) }
        var head = Array(digits.dropLast(3)), groups: [String] = [String(digits.suffix(3))]
        while head.count > 2 { groups.insert(String(head.suffix(2)), at: 0); head.removeLast(2) }
        if !head.isEmpty { groups.insert(String(head), at: 0) }
        return groups.joined(separator: ",")
    }

    // Day-first dates: "March fifth" / "fifth of March" → `5 March`; with a year → `5 March 2024`.

    static func date(_ toks: [Tok], at i: Int) -> ([Tok], Int)? {
        func isMonth(_ k: Int) -> Bool {
            k < toks.count && toks[k].isWord && !toks[k].locked && SelfCorrection.months.contains(Numbers.core(toks[k]))
        }
        // Month first: "March fifth [twenty twenty four]". Lowercase "may" is the verb.
        if isMonth(i), Numbers.mark(toks[i]).isEmpty, toks[i].text != "may",
           let (day, end, dayMark) = ordinalDay(toks, at: i + 1) {
            return finish(day: day, month: toks[i], dayMark: dayMark, daySpan: toks[i].span, monthSpan: toks[i + 1].span,
                          toks: toks, after: end)
        }
        // Day first: "fifth of March", "fifth March".
        if let (day, end, dayMark) = ordinalDay(toks, at: i), dayMark.isEmpty {
            var m = end
            let sawOf = m < toks.count && Numbers.core(toks[m]) == "of"
            if sawOf { m += 1 }
            guard isMonth(m), sawOf || toks[m].text != "may" else { return nil }
            return finish(day: day, month: toks[m], dayMark: Numbers.mark(toks[m]), daySpan: toks[i].span,
                          monthSpan: toks[m].span, toks: toks, after: m + 1)
        }
        return nil
    }

    private static func ordinalDay(_ toks: [Tok], at i: Int) -> (Int, Int, String)? {
        guard i < toks.count, toks[i].isWord, !toks[i].locked else { return nil }
        let c = Numbers.core(toks[i]), m = Numbers.mark(toks[i])
        if m.isEmpty, let ten = Numbers.tens[c], ten <= 30, i + 1 < toks.count, toks[i + 1].isWord, !toks[i + 1].locked,
           let u = Numbers.ordinalValue(Numbers.core(toks[i + 1])), u < 10, ten + u <= 31 {
            return (ten + u, i + 2, Numbers.mark(toks[i + 1]))
        }
        if let o = Numbers.ordinalValue(c), o <= 31 { return (o, i + 1, m) }
        return nil
    }

    private static func finish(day: Int, month: Tok, dayMark: String, daySpan: Int, monthSpan: Int,
                               toks: [Tok], after end: Int) -> ([Tok], Int) {
        let name = Numbers.core(month)
        let monthText = name.prefix(1).uppercased() + name.dropFirst()
        var out = [Tok(text: "\(day)", span: daySpan)]
        if dayMark.isEmpty, let y = Numbers.parseYear(toks, at: end) {
            out.append(Tok(text: monthText, span: monthSpan))
            out.append(Tok(text: "\(y.value)" + y.mark, span: toks[end].span))
            return (out, end + y.consumed)
        }
        out.append(Tok(text: monthText + dayMark, span: monthSpan))
        return (out, end)
    }
}

// MARK: - NeMo residual

/// Sends spoken-form clauses to the NeMo backend (before the Swift rules), one clause at a time, and
/// writes back only what changed: common leading/trailing words are trimmed, the changed middle goes
/// into the first changed token, the other changed tokens are dropped (their spans end up empty).
enum NemoResidual {
    /// A clause is only sent when one of these is still in it.
    static let triggers: Set<String> = {
        var s = Set(Numbers.units.keys).union(Numbers.tens.keys).union(Numbers.scales.keys).union(Numbers.ordinals.keys)
        s.formUnion(["point", "dollars", "dollar", "cents", "cent", "percent", "half", "quarter", "minus",
                     "rupees", "rupee", "euros", "pounds", "lakh", "crore"])
        s.remove("oh")
        return s
    }()

    /// Only what the Swift rules cannot write, as one token: `$5.50`, `2.5`, `12.5%`, `€3`. NeMo's
    /// English sentence mode otherwise rewrites prose (D1 LibriSpeech run: "and one more" → "1 more",
    /// "from four to five" → "from 04:56", "two hours" → "2 h"). Hindi: one token holding a digit.
    static func accepts(_ out: [String], language: String) -> Bool {
        guard out.count == 1, let w = out.first else { return false }
        if language != "en" { return w.contains(where: \.isNumber) }
        return w.range(of: #"^[$€£₹]?\d[\d,]*(\.\d+)?%?$"#, options: .regularExpression) != nil
            && (w.contains(where: { "$€£₹%".contains($0) }) || w.range(of: #"\d\.\d"#, options: .regularExpression) != nil)
    }

    static func apply(_ toks: inout [Tok], backend: any ITNBackend, language: String, policy: ITNPolicy) {
        var out: [Tok] = []
        var window: [Tok] = []

        func flush() {
            defer { window.removeAll() }
            guard !window.isEmpty else { return }
            out.append(contentsOf: rewrite(window, backend: backend, language: language, policy: policy))
        }

        for t in toks {
            guard t.isWord, !t.locked else { flush(); out.append(t); continue }
            window.append(t)
            if !Numbers.mark(t).isEmpty { flush() }     // a heard mark closes the clause
        }
        flush()
        toks = out
    }

    static func rewrite(_ window: [Tok], backend: any ITNBackend, language: String, policy: ITNPolicy) -> [Tok] {
        // Devanagari has no trigger table; Hindi clauses always go.
        guard language != "en" || window.contains(where: { triggers.contains(Numbers.core($0)) }) else { return window }
        let cores = window.map { Numbers.split($0.text).core }
        let lastMark = Numbers.mark(window[window.count - 1])
        guard let result = backend.normalizeSentence(cores.joined(separator: " "), language: language) else { return window }
        let outWords = result.split(separator: " ").map(String.init)
        guard !outWords.isEmpty else { return window }

        let n = cores.count, m = outWords.count
        var p = 0
        while p < n, p < m, cores[p].lowercased() == outWords[p].lowercased() { p += 1 }
        var s = 0
        while s < n - p, s < m - p, cores[n - 1 - s].lowercased() == outWords[m - 1 - s].lowercased() { s += 1 }
        guard p < n - s, p < m - s else { return window }   // nothing changed, or a pure deletion

        let changedOut = Array(outWords[p..<(m - s)])
        guard accepts(changedOut, language: language) else { return window }

        var replaced = window[p]
        replaced.text = changedOut.joined(separator: " ") + (s == 0 ? lastMark : "")
        replaced.flagged = window[p..<(n - s)].contains(where: \.flagged)
        return Array(window[..<p]) + [replaced] + Array(window[(n - s)...])
    }
}

// MARK: - AM / PM

/// After a time the Swift rules wrote ("3:30", "3"): `am`, `a.m.`, `pm`, `p.m.` → `AM` / `PM` (the
/// written form in the D1 goldens). The abbreviation's own final dot goes; a mark after it stays.
enum Meridiem {
    static func apply(_ toks: inout [Tok]) {
        for i in toks.indices.dropFirst() where toks[i].isWord && !toks[i].locked {
            let prev = toks[i - 1]
            guard prev.isWord, isTime(Numbers.split(prev.text).core), Numbers.mark(prev).isEmpty else { continue }
            let (core, mark) = Numbers.split(toks[i].lower)
            let written: String
            switch core {
            case "am", "a.m": written = "AM"
            case "pm", "p.m": written = "PM"
            default: continue
            }
            toks[i].text = written + (core.contains(".") && mark.hasPrefix(".") ? String(mark.dropFirst()) : mark)
        }
    }

    static func isTime(_ s: String) -> Bool {
        s.range(of: #"^\d{1,2}(:\d{2})?$"#, options: .regularExpression) != nil
    }
}
