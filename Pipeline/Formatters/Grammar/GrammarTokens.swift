import Foundation
import Shared

/// N12 — the word view the surface grammars parse, and the one way they write back.
///
/// Grammars read words (lowercased, edge punctuation split off) and propose replacements over
/// word ranges. A replacement is applied only when it covers whole spans and none of them is
/// low-confidence (Bet 9): the merged span keeps the lowest confidence, the union of audio
/// ranges, alternates and provenance, and `needsRepair` — nothing is dropped.
struct GrammarWord: Equatable {
    /// Lowercased, edge punctuation removed: what the grammars match.
    var core: String
    /// As written, edge punctuation removed (case kept).
    var text: String
    var lead: String
    var trail: String
    var span: Int
    var firstInSpan: Bool
    var lastInSpan: Bool
    var lowConfidence: Bool
}

struct GrammarReplacement {
    var range: ClosedRange<Int>
    var text: String
    /// Keep the last word's trailing punctuation (a sentence's period after `google.com`).
    var keepTrail: Bool = true
    var keepLead: Bool = true
}

enum GrammarTokens {
    static let edge: Set<Character> = [".", ",", "!", "?", ";", ":", "\"", "'", "(", ")", "\u{201C}", "\u{201D}", "\u{2018}", "\u{2019}"]

    static func words(_ spans: [TranscriptSpan]) -> [GrammarWord] {
        var out: [GrammarWord] = []
        for (index, span) in spans.enumerated() {
            let parts = span.text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            for (k, part) in parts.enumerated() {
                let (lead, body, trail) = split(part)
                out.append(GrammarWord(core: body.lowercased(), text: body, lead: lead, trail: trail, span: index,
                                       firstInSpan: k == 0, lastInSpan: k == parts.count - 1,
                                       lowConfidence: span.isLowConfidence))
            }
        }
        return out
    }

    /// `"(google."` → `("(", "google", ".")`. A word that is all punctuation stays whole.
    static func split(_ word: String) -> (String, String, String) {
        var body = Substring(word)
        var lead = "", trail = ""
        while let f = body.first, edge.contains(f), body.count > 1 { lead.append(f); body.removeFirst() }
        while let l = body.last, edge.contains(l), body.count > 1 { trail.insert(l, at: trail.startIndex); body.removeLast() }
        if body.count == 1, let c = body.first, edge.contains(c) { return ("", String(body), "") }
        return (lead, String(body), trail)
    }

    /// Applies non-overlapping replacements (earlier ones win). A replacement that would split a
    /// span or touch a low-confidence span is skipped: those words stay as heard.
    static func apply(_ replacements: [GrammarReplacement], to spans: [TranscriptSpan],
                      words: [GrammarWord], stage: StageID) -> [TranscriptSpan] {
        var bySpan: [Int: (end: Int, text: String)] = [:]
        var lastEnd = -1
        for r in replacements.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            guard r.range.lowerBound > lastEnd, r.range.upperBound < words.count else { continue }
            let first = words[r.range.lowerBound], last = words[r.range.upperBound]
            guard first.firstInSpan, last.lastInSpan,
                  !words[r.range].contains(where: \.lowConfidence) else { continue }
            let text = (r.keepLead ? first.lead : "") + r.text + (r.keepTrail ? last.trail : "")
            bySpan[first.span] = (last.span, text)
            lastEnd = r.range.upperBound
        }
        guard !bySpan.isEmpty else { return spans }
        var out: [TranscriptSpan] = []
        var i = 0
        while i < spans.count {
            if let (end, text) = bySpan[i] {
                out.append(merge(Array(spans[i...end]), text: text, stage: stage))
                i = end + 1
            } else {
                out.append(spans[i]); i += 1
            }
        }
        return out
    }

    static func merge(_ spans: [TranscriptSpan], text: String, stage: StageID) -> TranscriptSpan {
        var provenance: [StageID] = []
        for s in spans { for p in s.provenance where !provenance.contains(p) { provenance.append(p) } }
        provenance.append(stage)
        let first = spans[0]
        return TranscriptSpan(
            text: text,
            confidence: spans.map(\.confidence).min() ?? first.confidence,
            audioRange: (spans.map(\.audioRange.lowerBound).min() ?? 0)...(spans.map(\.audioRange.upperBound).max() ?? 0),
            alternates: spans.flatMap(\.alternates),
            provenance: provenance,
            needsRepair: spans.contains(where: \.needsRepair),
            stability: first.stability,
            punctuationOrigin: first.punctuationOrigin)
    }

    /// Whole utterance as one value (a URL bar, a formula): every span merged.
    static func replaceAll(_ spans: [TranscriptSpan], with text: String, stage: StageID) -> [TranscriptSpan]? {
        guard !spans.isEmpty, !spans.contains(where: \.isLowConfidence) else { return nil }
        return [merge(spans, text: text, stage: stage)]
    }
}

/// Spoken numbers and letter names, shared by the formula, phone and number grammars.
enum SpokenNumbers {
    static let units: [String: Int] = [
        "zero": 0, "oh": 0, "o": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    static let tens: [String: Int] = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60,
                                      "seventy": 70, "eighty": 80, "ninety": 90]

    /// A single digit word ("five", "oh") or a written digit run ("555").
    static func digits(_ word: String) -> String? {
        if !word.isEmpty, word.allSatisfy(\.isNumber) { return word }
        if let v = units[word], v < 10 { return String(v) }
        return nil
    }

    /// The longest cardinal starting at `i`: "twenty one" → (21, 2), "one hundred five" → (105, 3),
    /// "42" → (42, 1). "oh" counts only as a digit, never as a cardinal on its own.
    static func cardinal(_ words: [String], at i: Int) -> (value: Int, count: Int)? {
        guard i < words.count else { return nil }
        if let n = Int(words[i]) { return (n, 1) }
        var total = 0, current = 0, j = i, any = false
        while j < words.count {
            let w = words[j]
            if w == "oh" || w == "o" { break }
            if let u = units[w] { current += u; any = true; j += 1
                if j < words.count, tens[words[j]] != nil || units[words[j]] != nil { break }
                continue }
            if let t = tens[w] {
                current += t; any = true; j += 1
                if j < words.count, let u = units[words[j]], u < 10, words[j] != "oh", words[j] != "o", words[j] != "zero" { current += u; j += 1 }
                if j < words.count, words[j] == "hundred" || words[j] == "thousand" { continue }
                break
            }
            if w == "hundred", any { current *= 100; j += 1; continue }
            if w == "thousand", any { total += current * 1000; current = 0; j += 1; continue }
            if w == "and", any, j + 1 < words.count, units[words[j + 1]] != nil || tens[words[j + 1]] != nil { j += 1; continue }
            break
        }
        guard any else { return nil }
        return (total + current, j - i)
    }

    /// Letter names as recognisers write them: "see" → c, "dee" → d, "ell" → l.
    static let letterNames: [String: String] = [
        "ay": "a", "bee": "b", "be": "b", "see": "c", "sea": "c", "cee": "c", "dee": "d", "ee": "e", "eff": "f",
        "gee": "g", "aitch": "h", "jay": "j", "kay": "k", "el": "l", "ell": "l", "em": "m", "en": "n",
        "pee": "p", "cue": "q", "queue": "q", "ar": "r", "are": "r", "ess": "s", "tee": "t", "vee": "v",
        "ex": "x", "why": "y", "zee": "z", "zed": "z",
    ]

    /// A single letter or a letter name.
    static func letter(_ word: String) -> String? {
        if word.count == 1, let c = word.first, c.isLetter, c.isASCII { return word }
        return letterNames[word]
    }
}
