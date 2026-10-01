import Foundation

// V5 K8 — the V1 LibriSpeech-PC gate's metric: punctuation F1 over {, . ?} after aligning the
// hypothesis words to the reference words (case- and punctuation-insensitive LCS), plus the
// punctuation-blind word sequence so "WER unchanged" can be checked on the same pair.

public enum PunctuationF1 {
    public static let marks: [Character] = [",", ".", "?"]

    public struct Counts: Equatable, Sendable {
        public var tp = 0, fp = 0, fn = 0
        public init(tp: Int = 0, fp: Int = 0, fn: Int = 0) { self.tp = tp; self.fp = fp; self.fn = fn }
        public var precision: Double { tp + fp == 0 ? 0 : Double(tp) / Double(tp + fp) }
        public var recall: Double { tp + fn == 0 ? 0 : Double(tp) / Double(tp + fn) }
        public var f1: Double { precision + recall == 0 ? 0 : 2 * precision * recall / (precision + recall) }
        public static func + (a: Counts, b: Counts) -> Counts { Counts(tp: a.tp + b.tp, fp: a.fp + b.fp, fn: a.fn + b.fn) }
    }

    /// (bare word, the mark after it if any). "!" counts as ".", ";"/":" as ",".
    static func tokens(_ text: String) -> [(word: String, mark: Character?)] {
        text.split(whereSeparator: \.isWhitespace).compactMap { raw in
            var w = String(raw)
            var mark: Character?
            while let c = w.last, c.isPunctuation, c != "'" {
                switch c {
                case ".", "!", "…": mark = mark ?? "."
                case "?": mark = "?"
                case ",", ";", ":": mark = mark ?? ","
                default: break
                }
                w.removeLast()
            }
            w = w.lowercased().trimmingCharacters(in: .punctuationCharacters)
            return w.isEmpty ? nil : (w, mark)
        }
    }

    public static func words(_ text: String) -> [String] { tokens(text).map(\.word) }

    /// Counts over aligned words only (an unaligned word's mark is not judged — that is WER's job).
    public static func score(reference: String, hypothesis: String) -> Counts {
        let r = tokens(reference), h = tokens(hypothesis)
        let n = r.count, m = h.count
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    dp[i][j] = r[i].word == h[j].word ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }
        var c = Counts()
        var i = 0, j = 0
        while i < n, j < m {
            if r[i].word == h[j].word {
                let isLast = i == n - 1   // the final mark is the formatter's, not prosody's
                if !isLast {
                    switch (r[i].mark, h[j].mark) {
                    case let (a?, b?) where a == b: c.tp += 1
                    case (_?, _?): c.fp += 1; c.fn += 1
                    case (_?, nil): c.fn += 1
                    case (nil, _?): c.fp += 1
                    default: break
                    }
                }
                i += 1; j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] { i += 1 } else { j += 1 }
        }
        return c
    }

    /// The gate: F1 strictly up and the punctuation-blind words identical (so WER cannot move).
    public static func gatePasses(baseline: Counts, candidate: Counts, wordsUnchanged: Bool) -> Bool {
        wordsUnchanged && candidate.f1 > baseline.f1
    }
}
