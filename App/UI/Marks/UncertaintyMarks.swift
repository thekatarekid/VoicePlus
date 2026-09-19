import Engine
import Foundation
import Shared

// S5 — uncertainty marks (design_v1 §7 "Confidence and correction"; build doc S5).
//
// Where the red dotted marks go in a final text. The recogniser decides which words are uncertain
// (`TranscriptSpan.isLowConfidence`, the backend's min-token-probability rule); formatting, cleanup,
// punctuation and code-switching then rewrite the words. Marks are never placed by reusing raw
// character offsets: the spans' words are aligned to the final words with `WordAligner`, and
//   - a matched uncertain word keeps its mark (a preserved name stays marked),
//   - an uncertain word that was removed (a filler) loses it,
//   - an uncertain word inside a rewrite that cannot be aligned word for word marks the smallest
//     reliably aligned phrase (T05 "Review this phrase"), or the whole result when nothing aligns.

/// One whitespace-delimited word of a text, with its UTF-16 range (the unit AX and TextKit ranges use).
public struct MarkWord: Equatable, Sendable {
    /// The word as it appears, punctuation included ("Mira,").
    public var text: String
    /// The whole word.
    public var range: Range<Int>
    /// The word without leading or trailing punctuation and symbols: what a mark underlines and what a
    /// correction replaces (the comma after "Mira," stays put).
    public var core: Range<Int>
    /// `WordAligner.normalize(text)`: the identity used to align words. Empty for pure punctuation.
    public var normalized: String
}

public enum MarkWords {
    /// The whitespace-delimited words of `text`, in order (the same split the pill's text lane wraps).
    public static func words(in text: String) -> [MarkWord] {
        var out: [MarkWord] = []
        var offset = 0
        var start: Int?
        var current = ""
        func flush() {
            guard let s = start else { return }
            out.append(make(current, at: s))
            start = nil
            current = ""
        }
        for ch in text {
            if ch.isWhitespace {
                flush()
            } else {
                if start == nil { start = offset }
                current.append(ch)
            }
            offset += ch.utf16.count
        }
        flush()
        return out
    }

    static let edgeCharacters = CharacterSet.punctuationCharacters.union(.symbols)

    static func make(_ word: String, at start: Int) -> MarkWord {
        let chars = Array(word)
        func isEdge(_ c: Character) -> Bool { c.unicodeScalars.allSatisfy { edgeCharacters.contains($0) } }
        var lead = 0, trail = chars.count
        while lead < trail, isEdge(chars[lead]) { lead += 1 }
        while trail > lead, isEdge(chars[trail - 1]) { trail -= 1 }
        let length = word.utf16.count
        let core: Range<Int>
        if lead < trail {
            let before = chars[..<lead].reduce(0) { $0 + $1.utf16.count }
            let inner = chars[lead..<trail].reduce(0) { $0 + $1.utf16.count }
            core = (start + before)..<(start + before + inner)
        } else {
            core = start..<(start + length)
        }
        return MarkWord(text: word, range: start..<(start + length), core: core, normalized: WordAligner.normalize(word))
    }

    /// The UTF-16 slice of `text`, or nil when `range` is outside it.
    public static func slice(_ text: String, _ range: Range<Int>) -> String? {
        let units = text.utf16
        guard range.lowerBound >= 0, range.upperBound <= units.count, range.lowerBound <= range.upperBound else { return nil }
        let lo = units.index(units.startIndex, offsetBy: range.lowerBound)
        let hi = units.index(lo, offsetBy: range.count)
        return String(units[lo..<hi])
    }
}

/// One red dotted mark in a final text.
public struct UncertainMark: Equatable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Equatable, Hashable, Sendable {
        /// One uncertain word, mapped word for word (or one final word a rewrite produced from it).
        case word
        /// The smallest reliably aligned phrase around an uncertain word a rewrite changed (T05).
        case phrase
        /// Nothing aligned: the whole result is labelled for review (T05).
        case wholeResult
    }

    public var id: Int
    public var kind: Kind
    /// UTF-16 range in the final text: first word's core start ..< last word's core end.
    public var range: Range<Int>
    /// The final text at `range` ("Mira").
    public var text: String
    /// What the recogniser heard for this stretch ("mira"), kept as source-to-final provenance.
    public var heard: String
    /// The weakest source word's confidence (the min rule). Never shown as a probability of being right.
    public var confidence: Float
    /// At most three credible alternatives, best first, never equal to `text`.
    public var alternatives: [String]
    /// Indices of the spans the mark came from.
    public var sourceSpans: [Int]
    /// The final words the mark covers (indices into `MarkWords.words(in:)` of the final text).
    public var words: Range<Int>

    public init(id: Int, kind: Kind, range: Range<Int>, text: String, heard: String, confidence: Float,
                alternatives: [String] = [], sourceSpans: [Int] = [], words: Range<Int> = 0..<0) {
        self.id = id
        self.kind = kind
        self.range = range
        self.text = text
        self.heard = heard
        self.confidence = confidence
        self.alternatives = alternatives
        self.sourceSpans = sourceSpans
        self.words = words
    }

    /// VoiceOver: "Mira, uncertain word" / "…, uncertain phrase".
    public var accessibilityLabel: String {
        kind == .word ? "\(text), \(MarkCopy.uncertainWord)" : "\(text), \(MarkCopy.uncertainPhrase)"
    }
}

/// Copy the marks speak, from the design (§7, catalogue T04 / T05 / D09) and the copy fixture.
public enum MarkCopy {
    public static let uncertainWord = "uncertain word"
    public static let uncertainPhrase = "uncertain phrase"
    /// Design §7: "If no confidence exists, show “Confidence unavailable” on review".
    public static let confidenceUnavailable = "Confidence unavailable"
    /// "1 word to review", "2 words to review" (`PillCopy.wordsToReview`).
    public static func wordsToReview(_ n: Int) -> String { PillCopy.wordsToReview(n) }
    /// T05's headline: a rewrite moved an uncertain word into a phrase.
    public static var reviewPhrase: String { RecoveryCatalog.entry(.T05).headline }
}

/// Where the marks go in one final text.
public struct MarkMapping: Equatable, Sendable {
    public var text: String
    public var marks: [UncertainMark]
    /// The source carried decoder confidence. False for text with no spans, or streaming words taken as
    /// "Use available text" (no final confidence): nothing is marked, and nothing is claimed as checked.
    public var confidenceAvailable: Bool

    public init(text: String, marks: [UncertainMark], confidenceAvailable: Bool) {
        self.text = text
        self.marks = marks
        self.confidenceAvailable = confidenceAvailable
    }

    public static let empty = MarkMapping(text: "", marks: [], confidenceAvailable: false)

    public var isEmpty: Bool { marks.isEmpty }
    public var count: Int { marks.count }
    /// Marks of single words (the "N words to review" count).
    public var wordCount: Int { marks.filter { $0.kind == .word }.count }
    /// A rewrite forced a phrase or the whole result to be marked (T05).
    public var needsPhraseReview: Bool { marks.contains { $0.kind != .word } }

    /// "1 word to review" · "2 words to review" · "Review this phrase" (T05) · "" when nothing to review.
    public var reviewLine: String {
        if needsPhraseReview { return MarkCopy.reviewPhrase }
        return marks.isEmpty ? "" : MarkCopy.wordsToReview(marks.count)
    }

    /// The marks' ranges in the final text (`TurnRecord.uncertainSpans`).
    public var uncertainRanges: [Range<Int>] { marks.map(\.range) }

    public func mark(id: Int) -> UncertainMark? { marks.first { $0.id == id } }

    /// The mark under a UTF-16 offset of the text.
    public func mark(at offset: Int) -> UncertainMark? { marks.first { $0.range.contains(offset) } }

    /// Without the marks the user resolved (corrected or kept) for this turn.
    public func removing(_ ids: Set<Int>) -> MarkMapping {
        guard !ids.isEmpty else { return self }
        var copy = self
        copy.marks.removeAll { ids.contains($0.id) }
        return copy
    }

    /// VoiceOver for a text lane: the words, then the uncertain ones by name — never per token.
    public var accessibilityLabel: String {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !marks.isEmpty else { return words }
        let names = marks.map { "“\($0.text)”" }.joined(separator: ", ")
        return "\(words). \(reviewLine): \(names)"
    }
}

/// Maps uncertain spans onto a final text through `WordAligner` (design §7).
public enum UncertaintyMarkMapper {
    /// Most alternatives a correction offers (design §8.8: "at most three credible alternatives").
    public static let maxAlternatives = 3

    struct SourceWord {
        var normalized: String
        var text: String
        var span: Int
        var uncertain: Bool
        var confidence: Float
    }

    /// Streaming words taken as "Use available text" carry a placeholder confidence and no audio
    /// time (`TurnController.useAvailableText`); they are neither flagged nor claimed as checked.
    public static func carriesConfidence(_ span: TranscriptSpan) -> Bool {
        !(span.audioRange.lowerBound == 0 && span.audioRange.upperBound == 0)
    }

    /// The spans are the ones `text` was rendered from: the same words once spacing and punctuation are
    /// set aside, or at least half of the text's words aligning with them. Spans of another turn never
    /// mark a text they did not produce.
    public static func belongs(_ spans: [TranscriptSpan], to text: String) -> Bool {
        let source = spans.flatMap { $0.text.split(whereSeparator: \.isWhitespace) }
            .map { WordAligner.normalize(String($0)) }.filter { !$0.isEmpty }
        let target = MarkWords.words(in: text).map(\.normalized).filter { !$0.isEmpty }
        guard !source.isEmpty, !target.isEmpty else { return false }
        if source.joined() == target.joined() { return true }
        let matched = WordAligner.align(source: source, target: target).filter { $0.op == .match }.count
        return matched * 2 >= target.count
    }

    /// Marks for `finalText`, from the spans that carry the recogniser's confidence (the engine's raw
    /// spans, or the formatted spans, which carry it through every stage).
    public static func map(source spans: [TranscriptSpan], finalText: String) -> MarkMapping {
        let available = spans.contains { carriesConfidence($0) && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var source: [SourceWord] = []
        for (i, span) in spans.enumerated() {
            let low = carriesConfidence(span) && span.isLowConfidence
            for part in span.text.split(whereSeparator: \.isWhitespace) {
                let n = WordAligner.normalize(String(part))
                guard !n.isEmpty else { continue }
                source.append(SourceWord(normalized: n, text: String(part), span: i, uncertain: low, confidence: span.confidence))
            }
        }
        let all = MarkWords.words(in: finalText)
        let targetIndex = all.indices.filter { !all[$0].normalized.isEmpty }
        let target = targetIndex.map { all[$0] }
        guard available, source.contains(where: \.uncertain), !target.isEmpty else {
            return MarkMapping(text: finalText, marks: [], confidenceAvailable: available)
        }

        let pairs = WordAligner.align(source: source.map(\.normalized), target: target.map(\.normalized))
        var found: [(kind: UncertainMark.Kind, target: Range<Int>, source: [Int], range: Range<Int>?)] = []
        for pair in pairs where pair.op == .match {
            guard let s = pair.preview, let t = pair.final, source[s].uncertain else { continue }
            found.append((.word, t..<(t + 1), [s], nil))
        }
        let matched = pairs.contains { $0.op == .match }
        for region in WordAligner.regions(of: pairs) {
            let uncertain = region.source.filter { source[$0].uncertain }
            // An uncertain word that formatting removed (a filler) loses its mark.
            guard !uncertain.isEmpty, !region.target.isEmpty else { continue }
            // Words joined without spaces (Han, kana, Thai…): each spoken word is found inside the run.
            if region.target.count == 1,
               let pieces = unspacedPieces(of: target[region.target.lowerBound], in: finalText,
                                           words: region.source.map { source[$0].normalized }) {
                for (offset, s) in region.source.enumerated() where source[s].uncertain {
                    found.append((.word, region.target, [s], pieces[offset]))
                }
                continue
            }
            let kind: UncertainMark.Kind
            if region.target.count == 1 {
                kind = .word
            } else if !matched && region.target.count == target.count {
                kind = .wholeResult
            } else {
                kind = .phrase
            }
            found.append((kind, region.target, Array(region.source), nil))
        }
        found.sort { ($0.range?.lowerBound ?? target[$0.target.lowerBound].core.lowerBound)
            < ($1.range?.lowerBound ?? target[$1.target.lowerBound].core.lowerBound) }

        let marks: [UncertainMark] = found.enumerated().map { id, f in
            let first = target[f.target.lowerBound], last = target[f.target.upperBound - 1]
            let range = f.range ?? first.core.lowerBound..<last.core.upperBound
            let text = MarkWords.slice(finalText, range) ?? ""
            let heardWords = f.source.map { source[$0].text }
            let spanIDs = Array(Set(f.source.map { source[$0].span })).sorted()
            let confidence = f.source.filter { source[$0].uncertain }.map { source[$0].confidence }.min() ?? 0
            let words = targetIndex[f.target.lowerBound]..<(targetIndex[f.target.upperBound - 1] + 1)
            return UncertainMark(id: id, kind: f.kind, range: range, text: text, heard: heardWords.joined(separator: " "),
                                 confidence: confidence,
                                 alternatives: alternatives(for: text, heard: heardWords, spans: spanIDs.map { spans[$0] }),
                                 sourceSpans: spanIDs, words: words)
        }
        return MarkMapping(text: finalText, marks: marks, confidenceAvailable: true)
    }

    /// In a script written without spaces, the spoken words of a region are the target word's run
    /// cut in order: each word's UTF-16 range inside it, or nil when the run is not exactly those words.
    static func unspacedPieces(of word: MarkWord, in text: String, words: [String]) -> [Range<Int>]? {
        guard words.count > 1, word.text.contains(where: GraphemeMarks.isUnspaced),
              words.joined() == word.normalized,
              let core = MarkWords.slice(text, word.core) else { return nil }
        var pieces: [Range<Int>] = []
        var offset = word.core.lowerBound
        var chars = Array(core)[...]
        for needed in words {
            var taken = ""
            var start: Int?
            while taken.count < needed.count, let ch = chars.first {
                chars = chars.dropFirst()
                let n = WordAligner.normalize(String(ch))
                if !n.isEmpty, start == nil { start = offset }
                taken += n
                offset += ch.utf16.count
            }
            guard taken == needed, let s = start else { return nil }
            pieces.append(s..<offset)
        }
        return pieces
    }

    /// At most three credible alternatives: the decoder's alternates for the mark's spans, best score
    /// first, then what was heard when formatting changed it — never the current text, never twice,
    /// never empty, cased like the word they would replace.
    public static func alternatives(for text: String, heard: [String], spans: [TranscriptSpan]) -> [String] {
        var seen: Set<String> = [WordAligner.normalize(text)]
        var out: [String] = []
        func consider(_ raw: String) {
            let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: MarkWords.edgeCharacters)
            let key = WordAligner.normalize(candidate)
            guard !key.isEmpty, out.count < maxAlternatives, seen.insert(key).inserted else { return }
            out.append(cased(candidate, like: text))
        }
        let alternates = spans.flatMap(\.alternates).sorted { $0.score > $1.score }
        // A multi-span mark takes whole-mark alternates only: one span's alternate would drop the rest.
        for alternate in alternates where spans.count == 1 { consider(alternate.text) }
        consider(heard.joined(separator: " "))
        return out
    }

    /// "meera" offered for "Mira" reads "Meera".
    static func cased(_ candidate: String, like word: String) -> String {
        guard let w = word.first, w.isUppercase, let c = candidate.first, c.isLowercase else { return candidate }
        return c.uppercased() + candidate.dropFirst()
    }
}
