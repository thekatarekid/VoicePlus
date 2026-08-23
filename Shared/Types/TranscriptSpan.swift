import Foundation

/// An alternate hypothesis for a span, produced by beam search / confusion networks.
public struct Alternate: Codable, Equatable, Hashable, Sendable {
    public enum Source: String, Codable, Sendable {
        case beam
        case confusionNetwork
        case biasing
        case userDictionary
        case repair
    }

    public var text: String
    /// Relative score; higher is better. Not necessarily a probability.
    public var score: Float
    public var source: Source

    public init(text: String, score: Float, source: Source) {
        self.text = text
        self.score = score
        self.source = source
    }
}

/// The core shared type (Build doc §2). Every pipeline stage receives `[TranscriptSpan]`
/// and returns `[TranscriptSpan]`; confidence, audioRange and provenance must survive.
public struct TranscriptSpan: Codable, Equatable, Hashable, Sendable {
    public var text: String
    /// 0…1 from the decoder. Clamped on init.
    public var confidence: Float
    /// Audio time range (seconds from utterance start) that produced this span.
    public var audioRange: ClosedRange<TimeInterval>
    /// May be empty; filled by beam/confusion net.
    public var alternates: [Alternate]
    /// Every pipeline stage that touched it, in order.
    public var provenance: [StageID]
    /// Set by a stage instead of rewriting a low-confidence span (Bet 9).
    public var needsRepair: Bool

    public init(
        text: String,
        confidence: Float,
        audioRange: ClosedRange<TimeInterval>,
        alternates: [Alternate] = [],
        provenance: [StageID] = [],
        needsRepair: Bool = false
    ) {
        self.text = text
        self.confidence = min(max(confidence, 0), 1)
        self.audioRange = audioRange
        self.alternates = alternates
        self.provenance = provenance
        self.needsRepair = needsRepair
    }

    /// Confidence below which a stage must flag instead of rewrite.
    public static let lowConfidenceThreshold: Float = 0.5

    public var isLowConfidence: Bool { confidence < Self.lowConfidenceThreshold }

    /// Returns a copy with `stage` appended to provenance.
    public func touched(by stage: StageID) -> TranscriptSpan {
        var copy = self
        copy.provenance.append(stage)
        return copy
    }

    /// Returns a copy with new text, provenance appended. Callers must check
    /// `isLowConfidence` first — see `ConfidenceContract`.
    public func rewritten(_ newText: String, by stage: StageID) -> TranscriptSpan {
        var copy = touched(by: stage)
        copy.text = newText
        return copy
    }

    /// Returns a copy flagged for repair, provenance appended.
    public func flaggedForRepair(by stage: StageID) -> TranscriptSpan {
        var copy = touched(by: stage)
        copy.needsRepair = true
        return copy
    }

    enum CodingKeys: String, CodingKey {
        case text, confidence, audioStart, audioEnd, alternates, provenance, needsRepair
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let start = try c.decode(TimeInterval.self, forKey: .audioStart)
        let end = try c.decode(TimeInterval.self, forKey: .audioEnd)
        self.init(
            text: try c.decode(String.self, forKey: .text),
            confidence: try c.decode(Float.self, forKey: .confidence),
            audioRange: min(start, end)...max(start, end),
            alternates: try c.decodeIfPresent([Alternate].self, forKey: .alternates) ?? [],
            provenance: try c.decodeIfPresent([StageID].self, forKey: .provenance) ?? [],
            needsRepair: try c.decodeIfPresent(Bool.self, forKey: .needsRepair) ?? false
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text)
        try c.encode(confidence, forKey: .confidence)
        try c.encode(audioRange.lowerBound, forKey: .audioStart)
        try c.encode(audioRange.upperBound, forKey: .audioEnd)
        try c.encode(alternates, forKey: .alternates)
        try c.encode(provenance, forKey: .provenance)
        try c.encode(needsRepair, forKey: .needsRepair)
    }
}

public extension Array where Element == TranscriptSpan {
    /// Plain text of the spans, space-joined.
    var joinedText: String { map(\.text).joined(separator: " ") }
}
