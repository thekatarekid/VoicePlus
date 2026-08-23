import Foundation
import Shared

/// Pure copy of the macOS `RepairFanoutModel` (App/Repair) minus AppKit geometry: which word
/// is focused and its numbered alternates. Kept separate so the App module is untouched.
public struct KeyboardRepairFanout: Equatable, Sendable {
    public struct Item: Equatable, Sendable, Identifiable {
        public var id: Int { number }
        public var number: Int
        public var text: String
        public var source: Alternate.Source
        public init(number: Int, text: String, source: Alternate.Source) {
            self.number = number; self.text = text; self.source = source
        }
    }

    public static let maxItems = 5
    public var spanIndex: Int
    public var word: String
    public var confidence: Float
    public var items: [Item]

    public init?(span: TranscriptSpan, index: Int) {
        guard !span.alternates.isEmpty else { return nil }
        var seen = Set<String>()
        let alts = span.alternates.sorted { $0.score > $1.score }
            .filter { seen.insert($0.text.lowercased()).inserted }.prefix(Self.maxItems)
        guard !alts.isEmpty else { return nil }
        spanIndex = index; word = span.text; confidence = span.confidence
        items = alts.enumerated().map { Item(number: $0.offset + 1, text: $0.element.text, source: $0.element.source) }
    }

    /// Fan-out for the lowest-confidence span that has alternates, if any is below threshold
    /// or flagged `needsRepair`.
    public static func lowestConfidence(in spans: [TranscriptSpan]) -> KeyboardRepairFanout? {
        let candidates = spans.indices.filter { !spans[$0].alternates.isEmpty && (spans[$0].isLowConfidence || spans[$0].needsRepair) }
        guard let i = candidates.min(by: { spans[$0].confidence < spans[$1].confidence }) else { return nil }
        return KeyboardRepairFanout(span: spans[i], index: i)
    }

    public func alternateIndex(forNumber n: Int) -> Int? {
        items.indices.contains(n - 1) ? n - 1 : nil
    }
}
