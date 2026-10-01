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
    /// V5 B3 — natural-log probability of this alternate under the recogniser (≤ 0), when it came
    /// from real decoder candidates (joint top-K). nil for generated alternates (dictionary, repair).
    public var logProb: Float?

    public init(text: String, score: Float, source: Source) {
        self.init(text: text, score: score, source: source, logProb: nil)
    }

    public init(text: String, score: Float, source: Source, logProb: Float?) {
        self.text = text
        self.score = score
        self.source = source
        self.logProb = logProb
    }
}

/// R2.1 — how settled a piece of text is (Build doc §2).
///
/// - `provisional`: preview words shown in the pill. Free to change or disappear.
/// - `committed`: final text for one segment, sent to the destination once, never retracted.
/// - `final`: the whole utterance is closed; nothing further will arrive for it.
///
/// Ordered `provisional < committed < final`: a span may only ever move forward.
public enum Stability: String, Codable, Sendable, Equatable, Hashable, CaseIterable, Comparable, CustomStringConvertible {
    case provisional
    case committed
    case final

    /// Monotonic rank. Only ever increases over the life of a span.
    public var rank: Int {
        switch self {
        case .provisional: return 0
        case .committed: return 1
        case .final: return 2
        }
    }

    public static func < (lhs: Stability, rhs: Stability) -> Bool { lhs.rank < rhs.rank }

    /// True when text at this stability may still be rewritten in place.
    public var isMutable: Bool { self == .provisional }

    public var description: String { rawValue }
}

/// G0.1 — where a span's punctuation came from (V4.1). Model punctuation is provisional: a
/// caret-aware stage may strip it mid-sentence and keep it at the end of one. Spoken punctuation
/// ("comma", "full stop") is what the user asked for and is never stripped for context.
///
/// - `model`: the recogniser produced it (or the span carries none). The default.
/// - `spoken`: the user dictated it; set by spoken-punctuation handling.
/// - `stage`: a pipeline stage added it (terminal period, list punctuation, number formatting).
public enum PunctuationOrigin: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case model
    case spoken
    case stage

    /// True when context-sensitive stages may remove it.
    public var isProvisional: Bool { self == .model }
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
    /// R2.1 — how settled this span is. Defaults to `.final` so every pre-R2.1
    /// initializer call site and every pre-R2.1 JSON payload keeps working.
    public var stability: Stability
    /// G0.1 — where this span's punctuation came from. Defaults to `.model` so every earlier
    /// initializer call site and every earlier JSON payload keeps working.
    public var punctuationOrigin: PunctuationOrigin

    public init(
        text: String,
        confidence: Float,
        audioRange: ClosedRange<TimeInterval>,
        alternates: [Alternate] = [],
        provenance: [StageID] = [],
        needsRepair: Bool = false,
        stability: Stability = .final,
        punctuationOrigin: PunctuationOrigin = .model
    ) {
        self.text = text
        self.confidence = min(max(confidence, 0), 1)
        self.audioRange = audioRange
        self.alternates = alternates
        self.provenance = provenance
        self.needsRepair = needsRepair
        self.stability = stability
        self.punctuationOrigin = punctuationOrigin
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

    /// Returns a copy at `stability`, provenance untouched. Stability only ever moves
    /// forward: asking for a lower stability than the span already has is a no-op.
    public func stabilized(_ stability: Stability) -> TranscriptSpan {
        guard stability > self.stability else { return self }
        var copy = self
        copy.stability = stability
        return copy
    }

    /// True while this span is preview text that may still change.
    public var isProvisional: Bool { stability == .provisional }

    /// Returns a copy flagged for repair, provenance appended.
    public func flaggedForRepair(by stage: StageID) -> TranscriptSpan {
        var copy = touched(by: stage)
        copy.needsRepair = true
        return copy
    }

    enum CodingKeys: String, CodingKey {
        case text, confidence, audioStart, audioEnd, alternates, provenance, needsRepair, stability
        case punctuationOrigin
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
            needsRepair: try c.decodeIfPresent(Bool.self, forKey: .needsRepair) ?? false,
            stability: try c.decodeIfPresent(Stability.self, forKey: .stability) ?? .final,
            punctuationOrigin: try c.decodeIfPresent(PunctuationOrigin.self, forKey: .punctuationOrigin) ?? .model
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
        try c.encode(stability, forKey: .stability)
        try c.encode(punctuationOrigin, forKey: .punctuationOrigin)
    }
}

public extension Array where Element == TranscriptSpan {
    /// Plain text of the spans, space-joined — empty spans included, so a blanked span leaves a
    /// double or leading space. **Tests and diagnostics only**; text that reaches a destination or
    /// the pill uses `renderedText`.
    var joinedText: String { map(\.text).joined(separator: " ") }
}

public extension Sequence where Element == TranscriptSpan {
    /// G0.1 — the text of the spans as it should be inserted or shown (V4.13).
    ///
    /// - Empty and space-only spans are skipped (a filler or number the formatter blanked leaves
    ///   no stray space).
    /// - Spans join with one space, except next to a line break.
    /// - Runs of spaces collapse to one; spaces at either end and before a line break are dropped.
    ///   Indentation right after a line break is kept (code, nested lists).
    ///
    /// Leading/trailing spacing against the destination is the continuation planner's job, never
    /// this join's. The one join for every module: `Pipeline`'s older `Array` copy was removed at
    /// the wave 0 gate. Declared on `Sequence`; a second `Array` overload elsewhere would shadow it.
    var renderedText: String {
        var joined = ""
        for span in self {
            let text = span.text
            guard text.contains(where: { $0 != " " }) else { continue }
            if !joined.isEmpty, !joined.hasSuffix("\n"), !text.hasPrefix("\n") { joined += " " }
            joined += text
        }
        return TranscriptSpan.collapsingSpaces(joined)
    }
}

extension TranscriptSpan {
    /// Collapses runs of U+0020 per line; see `renderedText`. Other whitespace is left alone.
    static func collapsingSpaces(_ text: String) -> String {
        guard text.contains("  ") || text.hasPrefix(" ") || text.hasSuffix(" ") || text.contains(" \n") else {
            return text
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var out: [String] = []
        out.reserveCapacity(lines.count)
        for (index, line) in lines.enumerated() {
            // The first line's leading spaces are edge padding; later lines' are indentation.
            let indent = index == 0 ? "" : String(line.prefix { $0 == " " })
            var body = ""
            var pendingSpace = false
            for ch in line.dropFirst(indent.count) {
                if ch == " " {
                    pendingSpace = true
                } else {
                    if pendingSpace, !body.isEmpty { body.append(" ") }
                    pendingSpace = false
                    body.append(ch)
                }
            }
            out.append(body.isEmpty ? "" : indent + body)
        }
        return out.joined(separator: "\n")
    }
}
