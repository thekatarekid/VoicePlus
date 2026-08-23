import Foundation
import Shared

/// P1.7 T2 — deterministic email formatter. `[TranscriptSpan] -> [TranscriptSpan]`.
///
/// Passes (in order): filler removal, spoken punctuation / "new paragraph" commands,
/// self-correction resolution ("Friday — no, Thursday"), greeting and sign-off line breaks,
/// list detection ("first … second …", "bullet …", "number one …"), sentence
/// capitalisation and terminal punctuation.
///
/// Confidence contract (Bet 9): tokens from spans with confidence below
/// `TranscriptSpan.lowConfidenceThreshold` are *locked* — never edited, moved or removed —
/// and the span is returned verbatim with `needsRepair = true`. Spans whose words were all
/// removed (pure filler) are merged into a high-confidence neighbour so no audioRange is lost.
public struct EmailFormatter: PipelineStage {
    public let id: StageID = .formatterEmail

    public init() {}

    public func process(_ spans: [TranscriptSpan], context: StageContext) async throws -> [TranscriptSpan] {
        format(spans)
    }

    /// Synchronous core, exposed for golden tests.
    public func format(_ spans: [TranscriptSpan]) -> [TranscriptSpan] {
        guard !spans.isEmpty else { return [] }
        var tokens = EmailToken.tokenize(spans)
        removeFillers(&tokens)
        applySpokenCommands(&tokens)
        resolveSelfCorrections(&tokens)
        applyGreeting(&tokens)
        applySignOff(&tokens)
        detectLists(&tokens)
        applySentenceCase(&tokens)
        return rebuild(spans, from: tokens)
    }

    // MARK: - Rebuild spans

    private func rebuild(_ spans: [TranscriptSpan], from tokens: [EmailToken]) -> [TranscriptSpan] {
        var out: [TranscriptSpan?] = []
        for (i, span) in spans.enumerated() {
            if span.isLowConfidence {
                out.append(span.flaggedForRepair(by: id))
                continue
            }
            let text = EmailToken.render(tokens, spanIndex: i)
            if text.isEmpty, !span.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out.append(nil) // emptied by filler/correction removal; merged below
            } else {
                out.append(text == span.text ? span.touched(by: id) : span.rewritten(text, by: id))
            }
        }
        // Merge emptied spans into the nearest high-confidence neighbour (prefer previous).
        var result: [TranscriptSpan] = []
        var pendingEmpty: [TranscriptSpan] = []
        for (i, item) in out.enumerated() {
            guard let ready = item else {
                let original = spans[i]
                if let last = result.indices.last, !result[last].isLowConfidence {
                    result[last] = merge(result[last], absorbing: original)
                } else {
                    pendingEmpty.append(original)
                }
                continue
            }
            var span = ready
            if !pendingEmpty.isEmpty, !span.isLowConfidence {
                for e in pendingEmpty { span = merge(span, absorbing: e) }
                pendingEmpty.removeAll()
            }
            result.append(span)
        }
        for e in pendingEmpty { // no high-confidence neighbour at all: keep range, empty text
            result.append(e.rewritten("", by: id))
        }
        return result
    }

    private func merge(_ keep: TranscriptSpan, absorbing other: TranscriptSpan) -> TranscriptSpan {
        var merged = keep
        merged.audioRange = min(keep.audioRange.lowerBound, other.audioRange.lowerBound)
            ... max(keep.audioRange.upperBound, other.audioRange.upperBound)
        merged.confidence = min(keep.confidence, other.confidence)
        merged.alternates += other.alternates
        return merged
    }

    // MARK: - Passes

    private func removeFillers(_ t: inout [EmailToken]) {
        var i = 0
        while i < t.count {
            if !t[i].locked, EmailWordLists.fillers.contains(t[i].lower) {
                carryOver(&t, removing: i)
            } else {
                i += 1
            }
        }
    }

    /// Removes token `i`, carrying its trailing punctuation / break to a neighbour.
    private func carryOver(_ t: inout [EmailToken], removing i: Int) {
        let removed = t[i]
        if i > 0, !t[i - 1].locked, t[i - 1].trailing.isEmpty, !removed.trailing.isEmpty {
            t[i - 1].trailing = removed.trailing
        }
        if i + 1 < t.count, removed.breakBefore > t[i + 1].breakBefore {
            t[i + 1].breakBefore = removed.breakBefore
        }
        t.remove(at: i)
    }

    private func applySpokenCommands(_ t: inout [EmailToken]) {
        var i = 0
        while i < t.count {
            guard !t[i].locked else { i += 1; continue }
            let w = t[i].lower
            let next = i + 1 < t.count && !t[i + 1].locked ? t[i + 1].lower : ""
            var consumed = 0
            var punct: String?
            var brk = 0
            switch (w, next) {
            case ("new", "paragraph"): consumed = 2; brk = 2
            case ("new", "line"): consumed = 2; brk = 1
            case ("full", "stop"): consumed = 2; punct = "."
            case ("question", "mark"): consumed = 2; punct = "?"
            case ("exclamation", "mark"), ("exclamation", "point"): consumed = 2; punct = "!"
            case ("comma", _): consumed = 1; punct = ","
            case ("colon", _): consumed = 1; punct = ":"
            case ("semicolon", _): consumed = 1; punct = ";"
            case ("period", _):
                let prev = i > 0 ? t[i - 1].lower : ""
                if !EmailWordLists.periodNounCues.contains(prev) { consumed = 1; punct = "." }
            default: break
            }
            guard consumed > 0, i > 0 || punct == nil else { i += 1; continue }
            t.removeSubrange(i..<(i + consumed))
            if let p = punct, i > 0, !t[i - 1].locked {
                t[i - 1].trailing = p
            }
            if brk > 0, i < t.count {
                t[i].breakBefore = max(t[i].breakBefore, brk)
            }
        }
    }

    private func resolveSelfCorrections(_ t: inout [EmailToken]) {
        var i = 1
        while i < t.count {
            guard let (markerLen, ok) = correctionMarker(t, at: i), ok else { i += 1; continue }
            // Replacement Y: tokens after the marker up to clause end, max 4.
            var yEnd = i + markerLen
            var yClause: [EmailToken] = []
            while yEnd < t.count, yClause.count < 4, !t[yEnd].locked {
                if yEnd > i + markerLen, t[yEnd].breakBefore > 0 { break }
                yClause.append(t[yEnd])
                yEnd += 1
                if yClause.last!.endsSentence || yClause.last!.trailing.contains(",") { break }
            }
            var xEnd = i
            if xEnd > 0, t[xEnd - 1].isDash { xEnd -= 1 }
            var yCount = 0
            if !yClause.isEmpty, xEnd > 0 {
                // Anchored: "four thousand, no, five thousand dollars" → Y ends at the shared word.
                if let k = yClause.dropFirst().firstIndex(where: { $0.lower == t[xEnd - 1].lower }) {
                    yCount = k + 1
                } else {
                    yCount = 1
                    while yCount < min(yClause.count, 3), !EmailWordLists.functionWords.contains(yClause[yCount].lower) {
                        yCount += 1
                    }
                }
                // X may not cross a clause boundary.
                var maxX = 1
                while maxX < yCount, xEnd - maxX - 1 >= 0, t[xEnd - maxX - 1].trailing.isEmpty, t[xEnd - maxX].breakBefore == 0 {
                    maxX += 1
                }
                yCount = min(yCount, maxX)
            }
            // Original X: same number of tokens before the marker (skipping a dash).
            let xStart = xEnd - yCount
            guard yCount > 0, xStart >= 0, !t[xStart..<xEnd].contains(where: { $0.locked }) else { i += 1; continue }
            let xBreak = t[xStart].breakBefore
            let xPrefix = t[xStart].listPrefix
            let markerEnd = i + markerLen
            t.removeSubrange(xStart..<markerEnd)
            t[xStart].breakBefore = max(t[xStart].breakBefore, xBreak)
            if t[xStart].listPrefix.isEmpty { t[xStart].listPrefix = xPrefix }
            i = xStart + yCount
        }
    }

    /// Returns (marker token count, valid) when a self-correction marker starts at `i`.
    private func correctionMarker(_ t: [EmailToken], at i: Int) -> (Int, Bool)? {
        guard !t[i].locked else { return nil }
        let w = t[i].lower
        let next = i + 1 < t.count ? t[i + 1].lower : ""
        if w == "i", next == "mean" { return (2, i + 2 < t.count) }
        if w == "sorry" {
            // "sorry" only as a marker when set off by punctuation / a dash.
            let prevSep = t[i - 1].isDash || !t[i - 1].trailing.isEmpty
            return (1, prevSep && !t[i].endsSentence && i + 1 < t.count)
        }
        if w == "no" {
            var len = 1
            if next == "wait" { len = 2 }
            let after = i + len < t.count ? t[i + len].lower : ""
            guard i + len < t.count else { return nil }
            if EmailWordLists.noFalsePositives.contains(after) { return (len, false) }
            let prevSep = t[i - 1].isDash || !t[i - 1].trailing.isEmpty
            let selfSep = !t[i + len - 1].trailing.isEmpty
            let prevIsVerb = ["said", "say", "says", "is", "was", "answered", "replied", "or"].contains(t[i - 1].lower)
            return (len, (prevSep || selfSep || !prevIsVerb) && !t[i + len - 1].endsSentence)
        }
        return nil
    }

    private func applyGreeting(_ t: inout [EmailToken]) {
        guard let first = t.first, !first.locked else { return }
        guard let phrase = EmailWordLists.greetings.first(where: { p in
            p.indices.allSatisfy { $0 < t.count && !t[$0].locked && t[$0].lower == p[$0] && ($0 == p.count - 1 || t[$0].trailing.isEmpty) }
        }) else { return }
        var end = phrase.count - 1 // index of last greeting token
        if t[end].trailing.isEmpty {
            // Look for the addressee: up to 3 tokens, ending at punctuation or a stopper.
            var j = end + 1
            var limit = 3
            while j < t.count, limit > 0, !t[j].locked, t[j].breakBefore == 0 {
                let w = t[j].lower
                if EmailWordLists.greetingStoppers.contains(w) { break }
                end = j
                if !t[j].trailing.isEmpty { break }
                if w == "and" { limit += 1 }
                j += 1
                limit -= 1
            }
        }
        guard end + 1 < t.count else { // greeting is the whole utterance
            t[end].trailing = ","
            capitalizeGreeting(&t, upTo: end, phraseCount: phrase.count)
            return
        }
        if t[end].trailing != "!" { t[end].trailing = "," }
        capitalizeGreeting(&t, upTo: end, phraseCount: phrase.count)
        t[end + 1].breakBefore = max(t[end + 1].breakBefore, 2)
    }

    private func capitalizeGreeting(_ t: inout [EmailToken], upTo end: Int, phraseCount: Int) {
        t[0].core = capitalized(t[0].core)
        t[end].noAutoPeriod = true
        for j in phraseCount...max(phraseCount, end) where j <= end && j < t.count {
            let w = t[j].lower
            if w != "and", !EmailWordLists.lowercaseAddressees.contains(w) { t[j].core = capitalized(t[j].core) }
        }
    }

    private func applySignOff(_ t: inout [EmailToken]) {
        guard t.count >= 2 else { return }
        for phrase in EmailWordLists.signOffs {
            // Try phrase positions leaving 0...2 name tokens after it.
            for nameCount in 0...2 {
                let start = t.count - nameCount - phrase.count
                guard start >= 0 else { continue }
                let slice = t[start..<(start + phrase.count)]
                guard !slice.contains(where: { $0.locked }),
                      zip(slice, phrase).allSatisfy({ $0.lower == $1 }),
                      slice.dropLast().allSatisfy({ $0.trailing.isEmpty })
                else { continue }
                let names = t[(start + phrase.count)...]
                guard names.allSatisfy({ !$0.locked && !EmailWordLists.notNames.contains($0.lower) && $0.breakBefore <= 1 }) else { continue }
                if start > 0 {
                    let prev = t[start - 1]
                    let separated = !prev.trailing.isEmpty || t[start].breakBefore > 0
                    if phrase.count == 1, EmailWordLists.ambiguousSignOffs.contains(phrase[0]) {
                        guard separated || !["the", "is", "be", "very", "my", "our", "its", "it's", "your", "at", "do"].contains(prev.lower) else { continue }
                    } else if nameCount == 0 {
                        // "thanks" alone mid-sentence with no separation: only accept after a clause.
                        guard separated || !["say", "to", "and", "many"].contains(prev.lower) else { continue }
                    }
                    if prev.trailing.isEmpty, !prev.locked, !prev.noAutoPeriod { t[start - 1].trailing = "." }
                    t[start].breakBefore = max(t[start].breakBefore, 2)
                }
                t[start].core = capitalized(t[start].core)
                let last = start + phrase.count - 1
                t[last].trailing = ","
                t[last].noAutoPeriod = true
                for j in (last + 1)..<t.count {
                    t[j].core = capitalized(t[j].core)
                    t[j].trailing = ""
                    t[j].noAutoPeriod = true
                }
                if last + 1 < t.count { t[last + 1].breakBefore = 1 }
                return
            }
        }
    }

    private func detectLists(_ t: inout [EmailToken]) {
        // 1. Explicit "bullet [point]" and "number N" commands.
        var i = 0
        while i < t.count {
            guard !t[i].locked else { i += 1; continue }
            let w = t[i].lower
            let next = i + 1 < t.count && !t[i + 1].locked ? t[i + 1].lower : ""
            if w == "bullet", i + 1 < t.count {
                let consumed = next == "point" ? 2 : 1
                guard i + consumed < t.count else { i += 1; continue }
                t.removeSubrange(i..<(i + consumed))
                t[i].listPrefix = "- "
                t[i].breakBefore = max(t[i].breakBefore, 1)
                markListStart(&t, at: i)
                continue
            }
            if w == "number", let n = EmailWordLists.numberWords[next], i + 2 < t.count, t[i + 1].trailing.isEmpty || t[i + 1].trailing == "," {
                t.removeSubrange(i..<(i + 2))
                t[i].listPrefix = "\(n). "
                t[i].breakBefore = max(t[i].breakBefore, 1)
                markListStart(&t, at: i)
                continue
            }
            i += 1
        }
        // 2. Ordinal markers set off by a comma or "-ly": "first, … second, … finally, …" (need ≥ 2, starting at 1).
        var marks: [(index: Int, number: Int)] = []
        for (j, tok) in t.enumerated() where !tok.locked {
            guard let n = EmailWordLists.ordinals[tok.lower] else { continue }
            let setOff = tok.trailing == "," || tok.lower.hasSuffix("ly")
            guard setOff, j + 1 < t.count, !t[j + 1].locked else { continue }
            marks.append((j, n))
        }
        guard marks.count >= 2, marks.first?.number == 1 else { return }
        var counter = 0
        var numbered: [(index: Int, number: Int)] = []
        for mark in marks {
            counter = mark.number == 0 ? counter + 1 : mark.number
            numbered.append((mark.index, counter))
        }
        for mark in numbered.reversed() { // reverse so removals do not shift pending indices
            var idx = mark.index
            let brk = t[idx].breakBefore
            t.remove(at: idx)
            if idx > 0, t[idx - 1].lower == "and", t[idx - 1].trailing.isEmpty, !t[idx - 1].locked {
                t.remove(at: idx - 1)
                idx -= 1
            }
            t[idx].listPrefix = "\(mark.number). "
            t[idx].breakBefore = max(brk, 1)
        }
        for idx in t.indices where !t[idx].listPrefix.isEmpty { markListStart(&t, at: idx) }
    }

    /// The token before a list item ends its line; give it a colon if it has no punctuation.
    private func markListStart(_ t: inout [EmailToken], at idx: Int) {
        guard idx > 0 else { return }
        let prev = t[idx - 1]
        if prev.trailing.isEmpty, !prev.locked, prev.listPrefix.isEmpty, prev.spanIndex >= 0 {
            // previous token is a list item (somewhere earlier on its line)? then no colon
            var j = idx - 1
            var inItem = false
            while j >= 0 {
                if !t[j].listPrefix.isEmpty { inItem = true; break }
                if t[j].breakBefore > 0 { break }
                j -= 1
            }
            if !inItem { t[idx - 1].trailing = ":" }
        }
    }

    private func applySentenceCase(_ t: inout [EmailToken]) {
        var sentenceStart = true
        for i in t.indices {
            if t[i].breakBefore > 0 || !t[i].listPrefix.isEmpty { sentenceStart = true }
            if !t[i].locked {
                if sentenceStart { t[i].core = capitalized(t[i].core) }
                let l = t[i].lower
                if l == "i" || l.hasPrefix("i'") { t[i].core = "I" + t[i].core.dropFirst() }
                if EmailWordLists.properNouns.contains(l) { t[i].core = capitalized(t[i].core) }
                let isLast = i == t.count - 1
                let nextBreak = !isLast && (t[i + 1].breakBefore >= 2 || !t[i + 1].listPrefix.isEmpty)
                let inListItem = !t[i].listPrefix.isEmpty || (i > 0 && lineHasListPrefix(t, endingAt: i))
                if (isLast || nextBreak), t[i].trailing.isEmpty, !t[i].noAutoPeriod, !inListItem, !t[i].isDash {
                    t[i].trailing = "."
                }
                if t[i].trailing == "," && isLast && !t[i].noAutoPeriod { t[i].trailing = "." }
            }
            sentenceStart = t[i].endsSentence
        }
    }

    private func lineHasListPrefix(_ t: [EmailToken], endingAt i: Int) -> Bool {
        var j = i
        while j >= 0 {
            if !t[j].listPrefix.isEmpty { return true }
            if t[j].breakBefore > 0 { return false }
            j -= 1
        }
        return false
    }

    private func capitalized(_ s: String) -> String {
        guard let f = s.first else { return s }
        return f.uppercased() + s.dropFirst()
    }
}
