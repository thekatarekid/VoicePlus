import Foundation

/// A ranked term ready for the prefix tree. `weight` in 0…1 scales the per-token boost.
public struct BiasEntry: Hashable, Sendable {
    public var text: String
    public var weight: Float
    public var sources: Set<ContextSourceKind>
    public init(text: String, weight: Float, sources: Set<ContextSourceKind> = []) {
        self.text = text; self.weight = weight; self.sources = sources
    }
}

/// Scores harvested entries by source weight × recency × salience, merges duplicates across
/// sources (bonus for multi-source agreement) and applies the **hard cap** (Bet 2 constraint 3).
public struct Ranker: Sendable {
    public var cap: Int
    public var halfLife: TimeInterval
    public var sourceWeights: [ContextSourceKind: Double]

    public static let defaultSourceWeights: [ContextSourceKind: Double] = [
        .corrections: 1.0, .dictionary: 1.0, .participants: 0.9, .axTree: 0.85,
        .codeSymbols: 0.8, .recentWords: 0.6, .contacts: 0.4,
    ]

    public init(cap: Int = 400, halfLife: TimeInterval = 15 * 60, sourceWeights: [ContextSourceKind: Double] = Ranker.defaultSourceWeights) {
        self.cap = max(1, cap)
        self.halfLife = halfLife
        self.sourceWeights = sourceWeights
    }

    public func score(_ e: ContextEntry, now: Date) -> Double {
        let age = max(0, now.timeIntervalSince(e.observedAt))
        // Corrections/dictionary are timeless; everything else decays.
        let decay: Double = (e.source == .corrections || e.source == .dictionary) ? 1.0 : pow(0.5, age / halfLife)
        return (sourceWeights[e.source] ?? 0.5) * decay * max(0.05, e.salience)
    }

    public func rank(_ entries: [ContextEntry], now: Date = Date()) -> [BiasEntry] {
        struct Acc { var text: String; var score: Double; var sources: Set<ContextSourceKind> }
        var merged: [String: Acc] = [:]
        for e in entries {
            let key = e.text.lowercased()
            let s = score(e, now: now)
            if var a = merged[key] {
                a.score = max(a.score, s) + 0.25 * min(a.score, s)  // agreement bonus
                a.sources.insert(e.source)
                if e.text.first?.isUppercase == true { a.text = e.text }
                merged[key] = a
            } else {
                merged[key] = Acc(text: e.text, score: s, sources: [e.source])
            }
        }
        let sorted = merged.values.sorted { $0.score == $1.score ? $0.text < $1.text : $0.score > $1.score }
        let top = sorted.prefix(cap)
        let maxScore = top.first?.score ?? 1
        return top.map { BiasEntry(text: $0.text, weight: Float(min(1, $0.score / max(maxScore, 1e-9))), sources: $0.sources) }
    }
}
