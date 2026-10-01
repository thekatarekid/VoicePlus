import Foundation
import Shared

/// V5 B3 — one of the joint network's other top-K candidates at a token's emission step.
public struct TokenAlternative: Equatable, Hashable, Sendable, Codable {
    public var tokenId: Int
    /// Raw vocabulary piece ("▁" marks a word start, as in `DecodedToken.text`).
    public var text: String
    /// Natural log of its full-vocabulary probability at that step (≤ 0), on the same scale as
    /// the chosen token's `DecodedToken.logProb`.
    public var logProb: Float

    public init(tokenId: Int, text: String, logProb: Float) {
        self.tokenId = tokenId
        self.text = text
        self.logProb = logProb
    }

    public var isWordStart: Bool { text.hasPrefix("\u{2581}") || text.first?.isWhitespace == true }

    public var strippedText: String {
        var s = text
        if s.hasPrefix("\u{2581}") { s.removeFirst() }
        return s.trimmingCharacters(in: .whitespaces)
    }
}

/// V5 B3 — produces per-token top-K candidates for an already-decoded token sequence.
/// `tokens` are chunk-local (time zero = first sample of `samples`); the result is parallel to
/// `tokens` (one list per token, best first, never the chosen token or blank).
public protocol TokenAlternativesProviding: Sendable {
    func alternatives(for tokens: [DecodedToken], samples: [Float], k: Int) async throws -> [[TokenAlternative]]
}

/// V5 B3 — word-level alternates from per-token joint candidates (`TranscriptSpan.alternates`).
///
/// For each token of a word, each of its candidates is substituted in place of the chosen token
/// (a word-start candidate only at the word's first token, a continuation candidate only after it,
/// so a candidate never merges or splits words). The alternate's logProb is the word's summed
/// token logProb with that one token swapped; score is its probability. Alternates equal to the
/// top word (case/punctuation-insensitive) or below `minLogProb` are dropped, the rest deduplicated,
/// best first.
public enum WordAlternates {
    public static let defaultLimit = 4
    /// Alternates less likely than this (ln 0.001) are noise, not candidates worth a repair slot.
    public static let defaultMinLogProb: Float = -6.9

    public static func alternates(for wordTokens: [DecodedToken], limit: Int = defaultLimit,
                                  minLogProb: Float = defaultMinLogProb) -> [Alternate] {
        guard limit > 0, wordTokens.contains(where: { !$0.alternatives.isEmpty }) else { return [] }
        let pieces = wordTokens.map(\.strippedText)
        let top = pieces.joined()
        let topKey = WordConfusionNetwork.normalize(top)
        let total = wordTokens.reduce(Float(0)) { $0 + $1.logProb }
        var best: [String: Alternate] = [:]
        for (j, token) in wordTokens.enumerated() {
            for alt in token.alternatives {
                let firstOfWord = j == 0 && token.isWordStart
                guard alt.isWordStart == firstOfWord else { continue }
                var swapped = pieces
                swapped[j] = alt.strippedText
                let text = swapped.joined()
                let key = WordConfusionNetwork.normalize(text)
                guard !key.isEmpty, key != topKey else { continue }
                let lp = min(0, total - token.logProb + alt.logProb)
                guard lp >= minLogProb else { continue }
                if let have = best[key], (have.logProb ?? -.infinity) >= lp { continue }
                best[key] = Alternate(text: text, score: exp(lp), source: .beam, logProb: lp)
            }
        }
        return best.values.sorted { ($0.logProb ?? -.infinity) > ($1.logProb ?? -.infinity) }
            .prefix(limit).map { $0 }
    }
}
