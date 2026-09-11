// VoicePlus original (task R5.2). Re-aligning word timing after a second pass.
import Foundation
import Shared

/// Puts the refined words back on the pass-1 audio map.
///
/// The refinement session returns text for a whole segment and no word timings (V3 §5.3 asks the
/// caller to "re-align word timing"). Pass 1 gave us one span per word or phrase, each with a real
/// `audioRange`. So the alignment is: keep every input `audioRange` exactly as it is, and hand each
/// span a share of the refined words proportional to how much of the segment's audio it covers.
///
/// This is deliberately geometric, not acoustic — the second pass reports no timings to align to.
/// It keeps three things true that matter more than per-word precision: no `audioRange` moves, no
/// span is dropped, and the words stay in order across the segment.
public enum RefinedWordAlignment {
    /// Words per span, proportional to each span's share of the audio. Sums to `wordCount`.
    ///
    /// Spans with no measurable duration (or a segment where every span is zero-length) fall back
    /// to an equal split. Every span that can be given a word gets one before any span is given a
    /// second: a middle span left empty while its neighbour takes three is worse timing than a
    /// rough split, so once every span could have a word, one is taken back from the longest
    /// allocation until they all do. When there are fewer words than spans the leftover spans get
    /// empty text — the established way to keep an `audioRange` alive with nothing to say (see
    /// `SnippetStage`).
    public static func allocate(wordCount: Int, durations: [TimeInterval]) -> [Int] {
        let n = durations.count
        guard n > 0 else { return [] }
        guard wordCount > 0 else { return Array(repeating: 0, count: n) }
        guard n > 1 else { return [wordCount] }

        let total = durations.reduce(0) { $0 + max($1, 0) }
        let weights: [Double] = total > 0
            ? durations.map { max($0, 0) / total }
            : Array(repeating: 1.0 / Double(n), count: n)

        var counts = [Int](repeating: 0, count: n)
        var remainders: [(index: Int, value: Double)] = []
        for (i, weight) in weights.enumerated() {
            let ideal = weight * Double(wordCount)
            let floored = min(Int(ideal.rounded(.down)), wordCount)
            counts[i] = floored
            remainders.append((i, ideal - Double(floored)))
        }

        var leftover = wordCount - counts.reduce(0, +)
        let order = remainders.sorted {
            $0.value > $1.value || ($0.value == $1.value && $0.index < $1.index)
        }
        // Largest-remainder, but empty spans first.
        for entry in order where leftover > 0 && counts[entry.index] == 0 {
            counts[entry.index] += 1
            leftover -= 1
        }
        for entry in order where leftover > 0 {
            counts[entry.index] += 1
            leftover -= 1
        }
        // With at least one word per span available, no span is left silent while a neighbour
        // holds two: take from the longest allocation until every span has a word.
        if wordCount >= n {
            while let empty = counts.firstIndex(of: 0) {
                guard let donor = counts.indices.max(by: { counts[$0] < counts[$1] }),
                      counts[donor] > 1 else { break }
                counts[donor] -= 1
                counts[empty] += 1
            }
        }
        return counts
    }

    /// Split `text` on whitespace and lay it over `spans`' audio ranges. Returns one string per
    /// span, in span order.
    public static func distribute(_ text: String, over spans: [TranscriptSpan]) -> [String] {
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let counts = allocate(
            wordCount: words.count,
            durations: spans.map { $0.audioRange.upperBound - $0.audioRange.lowerBound }
        )
        var out: [String] = []
        var cursor = 0
        for take in counts {
            let end = min(cursor + take, words.count)
            out.append(cursor < end ? words[cursor..<end].joined(separator: " ") : "")
            cursor = end
        }
        return out
    }
}
