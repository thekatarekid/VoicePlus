import Foundation
import Shared

/// Word-level alignment of two hypotheses over the same audio. Edit-distance DP whose
/// substitution cost is discounted when the two words' audio spans overlap, so a word the
/// preview heard as "cotari" lines up with the final's "Kothari" even if neighbours shift.
public enum WordAligner {
    public enum Op: Equatable, Sendable { case match, substitute, insert, delete }

    public struct Pair: Equatable, Sendable {
        public var op: Op
        /// Index into preview spans (nil for `.insert`).
        public var preview: Int?
        /// Index into final spans (nil for `.delete`).
        public var final: Int?
    }

    /// Lower-cased, punctuation-stripped form used for "semantically equal" checks.
    public static func normalize(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " })
            .split(separator: " ").joined(separator: " ")
    }

    static func overlap(_ a: ClosedRange<TimeInterval>, _ b: ClosedRange<TimeInterval>) -> Double {
        let inter = max(0, min(a.upperBound, b.upperBound) - max(a.lowerBound, b.lowerBound))
        let union = max(a.upperBound, b.upperBound) - min(a.lowerBound, b.lowerBound)
        return union > 0 ? inter / union : (a == b ? 1 : 0)
    }

    public static func align(preview p: [TranscriptSpan], final f: [TranscriptSpan]) -> [Pair] {
        let n = p.count, m = f.count
        let gap = 0.6
        var cost = [[Double]](repeating: [Double](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: 1, through: n, by: 1) { cost[i][0] = Double(i) * gap }
        for j in stride(from: 1, through: m, by: 1) { cost[0][j] = Double(j) * gap }
        for i in stride(from: 1, through: n, by: 1) {
            for j in stride(from: 1, through: m, by: 1) {
                let equal = normalize(p[i - 1].text) == normalize(f[j - 1].text)
                let sub = equal ? 0 : 1.0 - 0.5 * overlap(p[i - 1].audioRange, f[j - 1].audioRange)
                cost[i][j] = min(cost[i - 1][j - 1] + sub, cost[i - 1][j] + gap, cost[i][j - 1] + gap)
            }
        }
        var pairs: [Pair] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0 {
                let equal = normalize(p[i - 1].text) == normalize(f[j - 1].text)
                let sub = equal ? 0 : 1.0 - 0.5 * overlap(p[i - 1].audioRange, f[j - 1].audioRange)
                if abs(cost[i][j] - (cost[i - 1][j - 1] + sub)) < 1e-9 {
                    pairs.append(Pair(op: equal ? .match : .substitute, preview: i - 1, final: j - 1)); i -= 1; j -= 1; continue
                }
            }
            if i > 0, abs(cost[i][j] - (cost[i - 1][j] + gap)) < 1e-9 {
                pairs.append(Pair(op: .delete, preview: i - 1, final: nil)); i -= 1
            } else {
                pairs.append(Pair(op: .insert, preview: nil, final: j - 1)); j -= 1
            }
        }
        return pairs.reversed()
    }

    /// Groups consecutive non-match ops into disagreement regions. Pure insertions/deletions
    /// adjacent to a substitution merge into it so "data base" → "database" is one region.
    public static func disagreements(preview p: [TranscriptSpan], final f: [TranscriptSpan],
                                     unknownPreviewConfidence: Float = 0.5) -> [Disagreement] {
        var out: [Disagreement] = []
        var run: [Pair] = []
        func flush() {
            guard !run.isEmpty else { return }
            let pi = run.compactMap(\.preview), fi = run.compactMap(\.final)
            let insertAt = pi.isEmpty ? insertionIndex(for: fi, preview: p, final: f) : 0
            let pr = (pi.first ?? insertAt)..<((pi.last.map { $0 + 1 }) ?? insertAt)
            let fr = (fi.first ?? 0)..<((fi.last.map { $0 + 1 }) ?? 0)
            let ps = pi.map { p[$0] }, fs = fi.map { f[$0] }
            let ranges = (ps + fs).map(\.audioRange)
            let audio = (ranges.map(\.lowerBound).min() ?? 0)...(ranges.map(\.upperBound).max() ?? 0)
            out.append(Disagreement(
                previewRange: pr, finalRange: fr,
                previewText: ps.joinedText, finalText: fs.joinedText,
                previewConfidence: ps.map(\.confidence).min() ?? unknownPreviewConfidence,
                finalConfidence: fs.map(\.confidence).min() ?? 0,
                audioRange: audio))
            run.removeAll()
        }
        for pair in align(preview: p, final: f) {
            if pair.op == .match { flush() } else { run.append(pair) }
        }
        flush()
        return out
    }

    /// For a pure-insertion run (no preview indices): the preview index the inserted words sit before,
    /// chosen by audio time.
    private static func insertionIndex(for fi: [Int], preview p: [TranscriptSpan], final f: [TranscriptSpan]) -> Int {
        guard let first = fi.first else { return p.count }
        let start = f[first].audioRange.lowerBound
        return p.firstIndex { $0.audioRange.lowerBound >= start } ?? p.count
    }
}

// MARK: - S5 · text-only alignment (uncertainty marks through formatting)

public extension WordAligner {
    /// One run of words with no reliable word-for-word mapping between two matched anchors (or an end
    /// of either text): the `source` words there became the `target` words. Empty `source` is a pure
    /// insertion (at `source.lowerBound`), empty `target` a pure deletion.
    struct Region: Equatable, Sendable {
        public var source: Range<Int>
        public var target: Range<Int>

        public init(source: Range<Int>, target: Range<Int>) {
            self.source = source
            self.target = target
        }
    }

    /// Word-for-word alignment of two texts of the same speech when one side has no timing (the words
    /// the recogniser produced against the words that were formatted, cleaned up and code-switched).
    /// Same edit-distance DP as `align(preview:final:)`: words are equal when their `normalize`d forms
    /// are, a substitution costs 1 and a gap 0.6. In each `Pair`, `preview` indexes `source` and
    /// `final` indexes `target`.
    static func align(source s: [String], target t: [String]) -> [Pair] {
        let a = s.map(normalize), b = t.map(normalize)
        let n = a.count, m = b.count
        let gap = 0.6
        var cost = [[Double]](repeating: [Double](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: 1, through: n, by: 1) { cost[i][0] = Double(i) * gap }
        for j in stride(from: 1, through: m, by: 1) { cost[0][j] = Double(j) * gap }
        for i in stride(from: 1, through: n, by: 1) {
            for j in stride(from: 1, through: m, by: 1) {
                let sub: Double = a[i - 1] == b[j - 1] ? 0 : 1
                cost[i][j] = min(cost[i - 1][j - 1] + sub, cost[i - 1][j] + gap, cost[i][j - 1] + gap)
            }
        }
        var pairs: [Pair] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0 {
                let equal = a[i - 1] == b[j - 1]
                if abs(cost[i][j] - (cost[i - 1][j - 1] + (equal ? 0 : 1))) < 1e-9 {
                    pairs.append(Pair(op: equal ? .match : .substitute, preview: i - 1, final: j - 1)); i -= 1; j -= 1; continue
                }
            }
            if i > 0, abs(cost[i][j] - (cost[i - 1][j] + gap)) < 1e-9 {
                pairs.append(Pair(op: .delete, preview: i - 1, final: nil)); i -= 1
            } else {
                pairs.append(Pair(op: .insert, preview: nil, final: j - 1)); j -= 1
            }
        }
        return pairs.reversed()
    }

    /// The runs of non-matching pairs of an alignment, in order. Consecutive substitutions,
    /// insertions and deletions form one region: inside it nothing maps word for word, so it is the
    /// smallest stretch a mark can be moved onto reliably.
    static func regions(of pairs: [Pair]) -> [Region] {
        var out: [Region] = []
        var nextSource = 0, nextTarget = 0
        var run: [Pair] = []
        func flush() {
            guard !run.isEmpty else { return }
            let si = run.compactMap(\.preview), ti = run.compactMap(\.final)
            let source = (si.first ?? nextSource)..<((si.last.map { $0 + 1 }) ?? nextSource)
            let target = (ti.first ?? nextTarget)..<((ti.last.map { $0 + 1 }) ?? nextTarget)
            out.append(Region(source: source, target: target))
            nextSource = source.upperBound
            nextTarget = target.upperBound
            run.removeAll()
        }
        for pair in pairs {
            if pair.op == .match {
                flush()
                nextSource = (pair.preview ?? nextSource - 1) + 1
                nextTarget = (pair.final ?? nextTarget - 1) + 1
            } else {
                run.append(pair)
            }
        }
        flush()
        return out
    }
}
