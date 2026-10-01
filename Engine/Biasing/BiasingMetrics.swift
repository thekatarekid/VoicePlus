import Foundation
import Shared

/// Lab-facing numbers for entity boosting (P1.5 T4; V5 B1 gate): entity recall, false insertions,
/// added latency.
public struct BiasingMetrics: Sendable, Equatable, Codable {
    public var entitiesExpected = 0
    public var entitiesRecalled = 0
    /// Bias-list entries that appear in the hypothesis but not in the reference.
    public var falseInsertions = 0
    public var hypothesisWords = 0
    public var utterances = 0
    /// Wall-clock added by the boosted decode vs. the unboosted one (ms, summed).
    public var addedLatencyMs: Double = 0

    public init() {}

    public var entityRecall: Double { entitiesExpected == 0 ? 0 : Double(entitiesRecalled) / Double(entitiesExpected) }
    public var falseInsertionRate: Double { hypothesisWords == 0 ? 0 : Double(falseInsertions) / Double(hypothesisWords) }
    public var meanAddedLatencyMs: Double { utterances == 0 ? 0 : addedLatencyMs / Double(utterances) }

    /// Scores one utterance. `entities` = bias terms the reference actually contains;
    /// `biasList` = every term that was biased (for false-insertion counting).
    public mutating func record(reference: String, hypothesis: String, entities: [String], biasList: [String], addedLatencyMs: Double = 0) {
        let refWords = Set(Self.words(reference))
        let hypWords = Self.words(hypothesis)
        let hypSet = Set(hypWords)
        let hypLower = " " + hypWords.joined(separator: " ") + " "
        let refLower = " " + Self.words(reference).joined(separator: " ") + " "
        for e in entities {
            entitiesExpected += 1
            if hypLower.contains(" " + Self.words(e).joined(separator: " ") + " ") { entitiesRecalled += 1 }
        }
        for b in biasList {
            let bw = Self.words(b)
            guard !bw.isEmpty else { continue }
            let phrase = " " + bw.joined(separator: " ") + " "
            if hypLower.contains(phrase), !refLower.contains(phrase) {
                // Count only if the word isn't otherwise legitimately in the reference.
                if bw.count > 1 || (hypSet.contains(bw[0]) && !refWords.contains(bw[0])) { falseInsertions += 1 }
            }
        }
        hypothesisWords += hypWords.count
        utterances += 1
        self.addedLatencyMs += addedLatencyMs
    }

    /// Relative recall improvement of `self` over `baseline` (0.3 == +30 %).
    public func relativeRecallGain(over baseline: BiasingMetrics) -> Double {
        guard baseline.entityRecall > 0 else { return entityRecall > 0 ? .infinity : 0 }
        return (entityRecall - baseline.entityRecall) / baseline.entityRecall
    }

    static func words(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "_" && $0 != "." }).map(String.init)
    }
}
