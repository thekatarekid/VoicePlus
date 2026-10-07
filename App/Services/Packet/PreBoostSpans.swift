import Engine
import Foundation
import Shared

/// Context Writer §2.5 — the recogniser's own words, before the vocabulary booster.
///
/// The final pass returns *boosted* spans (one per word, `WordConfidence.spans`, a swapped word
/// tagged `asr.boosted`); the decoder keeps the pre-boost 1-best only as text
/// (`FinalPassTiming.rawPreBoostText`). The packet must tell the writer what was heard before
/// boosting — the booster's output is evidence, never the base text — so this puts the pre-boost
/// words back onto the boosted spans:
///
/// - a span whose words the alignment finds unchanged is kept as it is (confidence, audio range and
///   the decoder's alternates intact);
/// - a run of spans the booster changed becomes one span holding the pre-boost words of that run,
///   with the run's lowest confidence, its audio range, and the boosted text as its first alternate
///   (source `.biasing`), so the prompt shows `ALT: heard -> boosted`.
///
/// The spans entering the pipeline stay the boosted ones; only the packet's `heard` uses these.
/// No text is logged.
enum PreBoostSpans {
    /// The pre-boost spans for `boosted`, or `boosted` itself when `preBoostText` is nil, empty or
    /// the same words.
    static func reconstruct(boosted: [TranscriptSpan], preBoostText: String?) -> [TranscriptSpan] {
        guard let preBoostText else { return boosted }
        let pre = preBoostText.split(whereSeparator: \.isWhitespace).map(String.init)
        var post: [(text: String, span: Int)] = []
        for (i, span) in boosted.enumerated() {
            for w in span.text.split(whereSeparator: \.isWhitespace) { post.append((String(w), i)) }
        }
        guard !pre.isEmpty, pre != post.map(\.text) else { return boosted }
        let match = align(pre, post.map(\.text))   // post word index -> pre word index

        // A span is kept when every one of its words aligned (in order, contiguously).
        var firstWord = [Int?](repeating: nil, count: boosted.count)
        var lastWord = [Int?](repeating: nil, count: boosted.count)
        for (j, w) in post.enumerated() {
            if firstWord[w.span] == nil { firstWord[w.span] = j }
            lastWord[w.span] = j
        }
        func kept(_ i: Int) -> (start: Int, end: Int)? {
            guard let a = firstWord[i], let b = lastWord[i] else { return nil }
            var prev: Int?
            for j in a...b {
                guard let m = match[j] else { return nil }
                if let p = prev, m != p + 1 { return nil }
                prev = m
            }
            return (match[a]!, match[b]! + 1)
        }

        var out: [TranscriptSpan] = []
        var cursor = 0              // next pre-boost word not yet emitted
        var run: [Int] = []         // boosted spans changed since the last kept one
        func flush(until end: Int) {
            let words = cursor < end ? Array(pre[cursor..<end]) : []
            defer { cursor = max(cursor, end); run = [] }
            guard !words.isEmpty || !run.isEmpty else { return }
            let covered = run.map { boosted[$0] }
            let boostedText = covered.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard !words.isEmpty else { return }   // the booster added words: the recogniser heard none
            let confidence = covered.map(\.confidence).min() ?? out.last?.confidence ?? 1
            let lower = covered.first?.audioRange.lowerBound ?? out.last?.audioRange.upperBound ?? 0
            let upper = covered.last?.audioRange.upperBound ?? lower
            var alternates: [Alternate] = []
            if !boostedText.isEmpty, boostedText != words.joined(separator: " ") {
                alternates.append(Alternate(text: boostedText, score: 1, source: .biasing))
            }
            if covered.count == 1 { alternates += covered[0].alternates }
            out.append(TranscriptSpan(text: words.joined(separator: " "), confidence: confidence,
                                      audioRange: lower...max(lower, upper), alternates: alternates,
                                      provenance: [.asr]))
        }
        for i in boosted.indices {
            if boosted[i].text.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if let k = kept(i) {
                flush(until: k.start)
                out.append(boosted[i])
                cursor = k.end
            } else {
                run.append(i)
            }
        }
        flush(until: pre.count)
        return out
    }

    /// Longest common subsequence of exact words: for each `b` word, the `a` word it matches.
    static func align(_ a: [String], _ b: [String]) -> [Int?] {
        let n = a.count, m = b.count
        guard n > 0, m > 0 else { return [Int?](repeating: nil, count: m) }
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var out = [Int?](repeating: nil, count: m)
        var i = 0, j = 0
        while i < n, j < m {
            if a[i] == b[j] { out[j] = i; i += 1; j += 1 }
            else if dp[i + 1][j] >= dp[i][j + 1] { i += 1 }
            else { j += 1 }
        }
        return out
    }

    /// The pre-boost text of the final pass that produced `spans`: the engine's last
    /// `FinalPassTiming`, used only when its final text is these spans' text (a latch segment or a
    /// later pass never lends its text to another landing) and boosting changed something.
    static func preBoostText(_ timing: FinalPassTiming?, for spans: [TranscriptSpan]) -> String? {
        guard let timing, timing.wasBoosted else { return nil }
        func words(_ s: String) -> [Substring] { s.split(whereSeparator: \.isWhitespace) }
        guard words(timing.finalText) == spans.flatMap({ words($0.text) }) else { return nil }
        let raw = timing.rawPreBoostText.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }
}
