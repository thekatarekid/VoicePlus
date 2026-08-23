import Foundation
import Shared

/// One beam-search hypothesis over a low-confidence region.
public struct BeamHypothesis: Equatable, Sendable {
    public var tokens: [DecodedToken]
    /// Total log-prob of the hypothesis (≤ 0). Blank/duration emissions are already
    /// folded in by the backend; only non-blank tokens are listed.
    public var score: Float

    public init(tokens: [DecodedToken], score: Float? = nil) {
        self.tokens = tokens
        self.score = score ?? tokens.reduce(0) { $0 + $1.logProb }
    }

    public var text: String { tokens.renderedText }
}

/// Collapses raw transducer beam candidates into a **word-level confusion network**
/// (Bet 3). Raw TDT beam entries differ mostly in blank/duration paths and SentencePiece
/// segmentation (`▁Koth ari` vs `▁Ko thari`), which render to the same word. Those are
/// merged (log-sum-exp over their scores) so the user only sees *semantically distinct*
/// alternates, ranked by posterior mass.
public enum WordConfusionNetwork {
    /// Key used to decide two hypotheses are "the same word(s)". Case/punctuation-insensitive.
    public static func normalize(_ text: String) -> String {
        text.lowercased()
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "'" }
            .map(String.init)
            .joined()
            .split(separator: " ")
            .joined(separator: " ")
    }

    /// Collapse hypotheses into distinct alternates. `excluding` (the greedy/current text)
    /// is removed so the alternates list never repeats what is already on screen.
    /// Returned scores are posterior probabilities (0…1) over the surviving distinct forms;
    /// `source` is `.confusionNetwork` when ≥2 raw hypotheses were merged, `.beam` otherwise.
    public static func collapse(_ hypotheses: [BeamHypothesis], excluding current: String? = nil, limit: Int = 5) -> [Alternate] {
        guard !hypotheses.isEmpty else { return [] }
        struct Bucket { var display: String; var scores: [Float]; var bestScore: Float }
        var buckets: [String: Bucket] = [:]
        var order: [String] = []
        for h in hypotheses {
            let display = h.text.trimmingCharacters(in: .whitespaces)
            let key = normalize(display)
            if key.isEmpty { continue }
            if var b = buckets[key] {
                b.scores.append(h.score)
                if h.score > b.bestScore { b.bestScore = h.score; b.display = display }
                buckets[key] = b
            } else {
                buckets[key] = Bucket(display: display, scores: [h.score], bestScore: h.score)
                order.append(key)
            }
        }
        // log-sum-exp per bucket, then normalise over all buckets (softmax in log space).
        let merged: [(key: String, display: String, logMass: Float, merged: Bool)] = order.map { key in
            let b = buckets[key]!
            let m = b.scores.max()!
            let lse = m + log(b.scores.reduce(0) { $0 + exp($1 - m) })
            return (key, b.display, lse, b.scores.count > 1)
        }
        let top = merged.map(\.logMass).max()!
        let z = merged.reduce(0 as Float) { $0 + exp($1.logMass - top) }
        let currentKey = current.map(normalize)
        return merged
            .filter { $0.key != currentKey }
            .map { Alternate(text: $0.display, score: exp($0.logMass - top) / z, source: $0.merged ? .confusionNetwork : .beam) }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }
}
