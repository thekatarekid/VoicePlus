import Foundation
import SwiftUI

// S10 — grapheme-safe placement of uncertainty marks (design §11: "Mixed scripts, CJK, RTL, emoji and
// long identifiers must not split graphemes or detach marks"; §7 marks).
//
// A mark always covers whole grapheme clusters (`Character`s): an emoji with its skin tone or ZWJ
// sequence, a flag, a keycap, a letter with its combining marks (Arabic harakat, Devanagari matras,
// Hangul jamo). Ranges that arrive as UTF-16 offsets are widened to the clusters they touch; words are
// found by whole-cluster comparison. In scripts written without spaces (Han, kana, Thai, Lao, Khmer,
// Myanmar) a word is matched inside the run; elsewhere it must not be part of a longer word.

public enum GraphemeMarks {
    // MARK: UTF-16 spans (turn detail, Today's held cards, the recovery sheet)

    /// UTF-16 spans → `NSRange`s in `text`, each widened to the whole grapheme clusters it touches;
    /// empty, negative or out-of-range spans dropped (a span that no longer fits the text is stale,
    /// never clamped onto other words); overlapping or touching ones merged, in order.
    public static func ranges(in text: String, utf16Spans spans: [Range<Int>]) -> [NSRange] {
        let string = text as NSString
        let length = string.length
        let widened: [NSRange] = spans
            .filter { $0.lowerBound >= 0 && $0.upperBound <= length && !$0.isEmpty }
            .map { string.rangeOfComposedCharacterSequences(for: NSRange(location: $0.lowerBound, length: $0.count)) }
            .sorted { $0.location < $1.location }
        var merged: [NSRange] = []
        for range in widened {
            if let last = merged.last, range.location <= NSMaxRange(last) {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    // MARK: Words (the pill's text lane)

    /// Where each of `words` (normalised as `PillTextLane.normalized` does: lower-cased, outer
    /// punctuation and symbols dropped) occurs in `line`, as whole-cluster ranges.
    public static func wordRanges(of words: Set<String>, in line: String) -> [Range<String.Index>] {
        let clusters = Array(line)
        let indices = Array(line.indices) + [line.endIndex]
        let folded = clusters.map { String($0).lowercased() }
        var found: [Range<Int>] = []
        for word in words where !word.isEmpty {
            let needle = Array(word).map { String($0) }
            guard needle.count <= clusters.count else { continue }
            var start = 0
            while start + needle.count <= clusters.count {
                if Array(folded[start..<start + needle.count]) == needle,
                   boundaryOK(clusters, before: start, word: needle.first),
                   boundaryOK(clusters, after: start + needle.count, word: needle.last) {
                    found.append(start..<start + needle.count)
                    start += needle.count
                } else {
                    start += 1
                }
            }
        }
        return merge(found).map { indices[$0.lowerBound]..<indices[$0.upperBound] }
    }

    /// `line` with a dotted underline in `color` on every uncertain word.
    public static func attributed(_ line: String, uncertain: Set<String>, color: Color) -> AttributedString {
        var out = AttributedString(line)
        for range in wordRanges(of: uncertain, in: line) {
            guard let marked = Range<AttributedString.Index>(range, in: out) else { continue }
            out[marked].underlineStyle = Text.LineStyle(pattern: .dot, color: color)
        }
        return out
    }

    // MARK: Pieces

    /// A script written without spaces between words: a word may start or end inside a run.
    static func isUnspaced(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: return true   // kana
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x3134F: return true // Han
            case 0x0E00...0x0EFF: return true   // Thai, Lao
            case 0x1000...0x109F: return true   // Myanmar
            case 0x1780...0x17FF: return true   // Khmer
            case 0x3000...0x303F: return true   // CJK punctuation
            default: return false
            }
        }
    }

    /// A cluster that continues a word (letters, digits, combining marks, the apostrophe inside).
    static func isWordCluster(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "'" || character == "’" || character == "_"
    }

    private static func boundaryOK(_ clusters: [Character], before index: Int, word first: String?) -> Bool {
        guard index > 0 else { return true }
        let neighbour = clusters[index - 1]
        if let first = first?.first, isUnspaced(first) || isUnspaced(neighbour) { return true }
        return !isWordCluster(neighbour)
    }

    private static func boundaryOK(_ clusters: [Character], after index: Int, word last: String?) -> Bool {
        guard index < clusters.count else { return true }
        let neighbour = clusters[index]
        if let last = last?.first, isUnspaced(last) || isUnspaced(neighbour) { return true }
        return !isWordCluster(neighbour)
    }

    private static func merge(_ ranges: [Range<Int>]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = out.last, range.lowerBound <= last.upperBound {
                out[out.count - 1] = last.lowerBound..<Swift.max(last.upperBound, range.upperBound)
            } else {
                out.append(range)
            }
        }
        return out
    }
}
