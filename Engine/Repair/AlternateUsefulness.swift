import Foundation
import Shared

/// T6 — Lab metric for Bet 3: of the low-confidence words whose landed text is wrong, how
/// often does the true word appear in the top-3 alternates ("alternate usefulness").
/// Kill criterion (PRODUCT-SPEC Part 5): < 40 % → `voiceRepair` flag goes default-off.
/// Pure value type so the Lab can compute it from stored spans without Engine runtime.
public struct AlternateUsefulness: Equatable, Sendable {
    public var evaluated: Int
    public var hits: Int
    public var topK: Int
    public var hitRate: Double { evaluated == 0 ? 0 : Double(hits) / Double(evaluated) }
    public var meetsTarget: Bool { hitRate >= 0.6 }
    public var belowKill: Bool { evaluated > 0 && hitRate < 0.4 }

    public init(evaluated: Int = 0, hits: Int = 0, topK: Int = 3) {
        self.evaluated = evaluated
        self.hits = hits
        self.topK = topK
    }

    /// `pairs` are (span as landed, true word). Only low-confidence *wrong* spans count: a
    /// low-confidence span that was already right needs no alternate, and a high-confidence
    /// wrong span never gets a fan-out in the UI, so neither is a fair test of the alternates.
    public static func measure(_ pairs: [(span: TranscriptSpan, truth: String)], topK: Int = 3) -> AlternateUsefulness {
        var m = AlternateUsefulness(topK: topK)
        for (span, truth) in pairs {
            let truthKey = WordConfusionNetwork.normalize(truth)
            guard span.isLowConfidence, WordConfusionNetwork.normalize(span.text) != truthKey else { continue }
            m.evaluated += 1
            if span.alternates.prefix(topK).contains(where: { WordConfusionNetwork.normalize($0.text) == truthKey }) { m.hits += 1 }
        }
        return m
    }

    public var summary: String {
        "alternate usefulness: \(hits)/\(evaluated) low-confidence errors had the truth in top-\(topK) (\(Int((hitRate * 100).rounded()))%)"
    }
}
