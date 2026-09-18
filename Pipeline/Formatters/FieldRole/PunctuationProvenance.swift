import Foundation
import Shared

/// D2 (V4.1) — where the punctuation of a formatted insertion came from.
///
/// The recogniser punctuates on its own (`.model`); that punctuation is provisional, and the
/// caret decides whether it stays. A mark the user dictated ("comma", "full stop") is `.spoken`
/// and always stays. A period a formatter appended is `.stage`.
///
/// The inner formatters (`ProseListFormatter`'s `SpokenPunctuation`, `ChatFormatter`) turn spoken
/// commands into marks glued onto the previous word, keeping each input span's `audioRange`
/// (prose) or merging neighbours (chat). This runs right after them inside
/// `FieldRoleFormatterStage` — the stage that owns the app's formatting pass — and compares
/// their output with the recogniser's spans, so it needs no change to the formatters and holds
/// for every register they serve.
enum PunctuationProvenance {
    /// Spoken command → mark, one word. The prose and chat tables, newlines excluded.
    static let singleWord: [String: String] = {
        var out: [String: String] = [:]
        for (word, kind) in SpokenPunctuation.single { if let mark = mark(kind) { out[word] = mark } }
        for (phrase, mark) in ChatFormatter.spokenPunctuation where !phrase.contains(" ") && !mark.hasPrefix("\n") {
            out[phrase] = mark
        }
        return out
    }()

    /// Spoken command → mark, two words ("full stop", "question mark").
    static let twoWords: [String: String] = {
        var out: [String: String] = [:]
        for (phrase, kind) in SpokenPunctuation.pairs { if let mark = mark(kind) { out[phrase] = mark } }
        for (phrase, mark) in ChatFormatter.spokenPunctuation where phrase.contains(" ") && !mark.hasPrefix("\n") {
            out[phrase] = mark
        }
        return out
    }()

    static let fillers: Set<String> = Fillers.single.union(ChatFormatter.fillers)

    private static func mark(_ kind: TokKind) -> String? {
        switch kind {
        case .punct(let p): return p.trimmingCharacters(in: .whitespaces)
        case .open(let o): return o
        case .newline, .listMarker, .word: return nil
        }
    }

    struct Word: Equatable {
        var core: String
        var span: Int
    }

    /// The recogniser's words, lowercased and stripped of punctuation, with their span index.
    static func words(_ spans: [TranscriptSpan]) -> [Word] {
        var out: [Word] = []
        for (i, span) in spans.enumerated() {
            for part in span.text.split(whereSeparator: { $0.isWhitespace }) {
                let core = part.lowercased().trimmingCharacters(in: .punctuationCharacters)
                if !core.isEmpty { out.append(Word(core: core, span: i)) }
            }
        }
        return out
    }

    /// A spoken command starting at `i`: its mark and its length in words.
    static func command(at i: Int, in words: [Word]) -> (mark: String, length: Int)? {
        if i + 1 < words.count, let mark = twoWords[words[i].core + " " + words[i + 1].core] { return (mark, 2) }
        if let mark = singleWord[words[i].core] { return (mark, 1) }
        return nil
    }

    static func midpoint(_ range: ClosedRange<TimeInterval>) -> TimeInterval { (range.lowerBound + range.upperBound) / 2 }

    /// Original spans an output span stands for: its own (prose keeps ranges) or the ones a
    /// merge folded into it (chat).
    static func originals(of span: TranscriptSpan, in original: [TranscriptSpan]) -> [TranscriptSpan] {
        original.filter { span.audioRange.contains(midpoint($0.audioRange)) }
    }

    static func hasContent(_ text: String) -> Bool { text.contains { $0.isLetter || $0.isNumber } }

    // MARK: - Marking

    /// Every output span that carries a mark the user dictated becomes `.spoken`. Nothing else
    /// about the span changes (text, confidence, audioRange and provenance are the caller's).
    static func annotate(_ out: [TranscriptSpan], original: [TranscriptSpan]) -> [TranscriptSpan] {
        let ws = words(original)
        guard !ws.isEmpty else { return out }
        var result = out
        var i = 0
        while i < ws.count {
            guard let (mark, length) = command(at: i, in: ws) else { i += 1; continue }
            defer { i += length }
            guard i > 0 else { continue }
            let anchor = original[ws[i - 1].span].audioRange
            if let j = result.lastIndex(where: { $0.audioRange.contains(midpoint(anchor)) && $0.text.contains(mark) }) {
                result[j].punctuationOrigin = .spoken
            }
        }
        return result
    }

    // MARK: - The final period

    /// The insertion's final period and where it came from; `nil` when it does not end in a
    /// plain period (`?`, `!`, `...` and `…` are never touched), when the last span is low
    /// confidence (Bet 9: never rewritten), or when the dot belongs to an abbreviation (`etc.`).
    static func trailingPeriod(in out: [TranscriptSpan], original: [TranscriptSpan]) -> (index: Int, origin: PunctuationOrigin)? {
        guard let li = out.lastIndex(where: { hasContent($0.text) || $0.text.contains(".") }) else { return nil }
        let text = out[li].text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out[li].isLowConfidence, text.hasSuffix("."), !text.hasSuffix("..") else { return nil }
        let lastWord = text.split(whereSeparator: { $0.isWhitespace }).last.map { $0.lowercased() } ?? ""
        guard !ContinuationPlanner.isAbbreviation(lastWord) else { return nil }

        let covered = originals(of: out[li], in: original)
        // An earlier stage already said so.
        if covered.contains(where: { $0.punctuationOrigin == .spoken }) { return (li, .spoken) }
        // "… full stop" (a trailing filler after it is fine).
        var ws = words(original)
        while let last = ws.last, fillers.contains(last.core) { ws.removeLast() }
        if ws.count >= 2, twoWords[ws[ws.count - 2].core + " " + ws[ws.count - 1].core] == "." { return (li, .spoken) }
        if let last = ws.last, singleWord[last.core] == "." { return (li, .spoken) }
        // The recogniser put it there.
        if let heard = covered.last(where: { hasContent($0.text) }), heard.text.trimmingCharacters(in: .whitespaces).hasSuffix(".") {
            return (li, .model)
        }
        if covered.isEmpty, let heard = original.last(where: { hasContent($0.text) }),
           heard.text.trimmingCharacters(in: .whitespaces).hasSuffix(".") {
            return (li, .model)
        }
        return (li, .stage)
    }

    /// True when the recogniser's first word began with a lowercase letter, i.e. a capital there
    /// now was added by a formatter. Fillers the formatter removed are skipped.
    static func heardFirstLetterIsLowercase(for span: TranscriptSpan, original: [TranscriptSpan]) -> Bool {
        let candidates = originals(of: span, in: original)
        let pool = candidates.isEmpty ? original : candidates
        for s in pool {
            for part in s.text.split(whereSeparator: { $0.isWhitespace }) {
                let core = part.lowercased().trimmingCharacters(in: .punctuationCharacters)
                if fillers.contains(core) { continue }
                if let c = part.first(where: \.isLetter) { return c.isLowercase }
            }
        }
        return false
    }
}
