import Foundation
import Shared

/// A contiguous region of low-confidence words inside one decode pass.
public struct LowConfidenceRegion: Equatable, Sendable {
    /// Indices into `WordConfidence.aggregate` output.
    public var wordRange: ClosedRange<Int>
    public var timeRange: ClosedRange<TimeInterval>
    public var greedyText: String
    /// Tokens the greedy pass emitted for this region.
    public var greedyTokens: [DecodedToken]
}

/// Runs a beam search (width `width`) over one region. The real backend re-runs the
/// transducer joint over the region's encoder frames with the greedy prefix; that needs
/// the FluidAudio fork hook (README §Implementations), so the backend is a protocol and
/// the shipped implementations are the fork-hook adapter placeholder and `ScriptedBeamBackend`.
public protocol BeamSearchBackend: Sendable {
    func hypotheses(for region: LowConfidenceRegion, frames: EncoderFrames, width: Int, biaser: LogitBiaser?) async throws -> [BeamHypothesis]
}

/// Synthetic backend for tests/Lab: keyed by the greedy text of the region (normalised).
/// Missing keys return only the greedy hypothesis (beam "weak" → enrichment kicks in).
public final class ScriptedBeamBackend: BeamSearchBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var table: [String: [BeamHypothesis]]
    public private(set) var calls: [LowConfidenceRegion] = []

    public init(_ table: [String: [BeamHypothesis]] = [:]) {
        var t: [String: [BeamHypothesis]] = [:]
        for (k, v) in table { t[WordConfusionNetwork.normalize(k)] = v }
        self.table = t
    }

    public func hypotheses(for region: LowConfidenceRegion, frames: EncoderFrames, width: Int, biaser: LogitBiaser?) async throws -> [BeamHypothesis] {
        lock.lock(); defer { lock.unlock() }
        calls.append(region)
        let scripted = table[WordConfusionNetwork.normalize(region.greedyText)] ?? []
        let greedy = BeamHypothesis(tokens: region.greedyTokens)
        return Array(([greedy] + scripted).sorted { $0.score > $1.score }.prefix(width))
    }
}

/// T1 — `Decoder` that stays greedy everywhere and opens a beam (width 4 by default) only
/// over low-confidence words. Beam candidates are collapsed through `WordConfusionNetwork`
/// into distinct alternates attached to the word spans. Greedy tokens/confidences are
/// never altered: the beam adds alternates, it does not overrule the greedy text (Bet 9 —
/// the on-screen word must keep its honest confidence).
public final class SelectiveBeamDecoder: Decoder, @unchecked Sendable {
    public let name: String
    public let base: any Decoder
    public let backend: any BeamSearchBackend
    public let width: Int
    public let threshold: Float
    /// Merge adjacent low-confidence words into one region when their gap is ≤ this (seconds).
    public let mergeGap: TimeInterval

    private let lock = NSLock()
    private var lastSpans: [TranscriptSpan] = []
    public private(set) var regionsDecoded = 0

    public var biaser: LogitBiaser? {
        get { base.biaser }
        set { base.biaser = newValue }
    }

    public init(base: any Decoder, backend: any BeamSearchBackend, width: Int = 4,
                threshold: Float = TranscriptSpan.lowConfidenceThreshold, mergeGap: TimeInterval = 0.16) {
        self.base = base
        self.backend = backend
        self.width = max(1, width)
        self.threshold = threshold
        self.mergeGap = mergeGap
        self.name = "selective-beam(\(base.name), w=\(width))"
    }

    /// Frozen-protocol entry point: returns the greedy tokens unchanged. Use `decodeSpans`
    /// (or `spansFromLastDecode`) to get the alternates.
    public func decode(encoderFrames: EncoderFrames) async throws -> DecodeResult {
        let result = try await base.decode(encoderFrames: encoderFrames)
        let spans = try await enrich(result.tokens, frames: encoderFrames)
        lock.withLock { lastSpans = spans }
        return result
    }

    /// Decode one chunk and return word spans with alternates on the low-confidence ones.
    public func decodeSpans(encoderFrames: EncoderFrames) async throws -> [TranscriptSpan] {
        _ = try await decode(encoderFrames: encoderFrames)
        return lock.withLock { lastSpans }
    }

    public var spansFromLastDecode: [TranscriptSpan] { lock.withLock { lastSpans } }

    public func reset() async {
        await base.reset()
        lock.withLock { lastSpans = [] }
    }

    // MARK: - Region detection

    public static func regions(in words: [ScoredWord], threshold: Float, mergeGap: TimeInterval) -> [LowConfidenceRegion] {
        var out: [LowConfidenceRegion] = []
        var i = 0
        while i < words.count {
            guard words[i].confidence < threshold else { i += 1; continue }
            var j = i
            while j + 1 < words.count, words[j + 1].confidence < threshold, words[j + 1].startTime - words[j].endTime <= mergeGap { j += 1 }
            let slice = words[i...j]
            out.append(LowConfidenceRegion(
                wordRange: i...j,
                timeRange: slice.first!.startTime...max(slice.first!.startTime, slice.map(\.endTime).max()!),
                greedyText: slice.map(\.text).joined(separator: " "),
                greedyTokens: slice.flatMap(\.tokens)))
            i = j + 1
        }
        return out
    }

    private func enrich(_ tokens: [DecodedToken], frames: EncoderFrames) async throws -> [TranscriptSpan] {
        let words = WordConfidence.aggregate(tokens)
        var spans = WordConfidence.spans(from: tokens)
        let regions = Self.regions(in: words, threshold: threshold, mergeGap: mergeGap)
        for region in regions {
            let hyps = try await backend.hypotheses(for: region, frames: frames, width: width, biaser: base.biaser)
            lock.withLock { regionsDecoded += 1 }
            let alternates = WordConfusionNetwork.collapse(hyps, excluding: region.greedyText)
            guard !alternates.isEmpty else { continue }
            if region.wordRange.count == 1 {
                spans[region.wordRange.lowerBound].alternates = alternates
            } else {
                // Multi-word region: the alternates describe the whole phrase; attach the
                // phrase-level alternates to the first word and per-word slices where the
                // alternate has the same word count.
                for (offset, idx) in region.wordRange.enumerated() {
                    let perWord = alternates.compactMap { alt -> Alternate? in
                        let parts = alt.text.split(separator: " ").map(String.init)
                        guard parts.count == region.wordRange.count, offset < parts.count,
                              WordConfusionNetwork.normalize(parts[offset]) != WordConfusionNetwork.normalize(words[idx].text) else { return nil }
                        return Alternate(text: parts[offset], score: alt.score, source: alt.source)
                    }
                    var seen = Set<String>()
                    spans[idx].alternates = perWord.filter { seen.insert(WordConfusionNetwork.normalize($0.text)).inserted }
                    if offset == 0, spans[idx].alternates.isEmpty { spans[idx].alternates = alternates }
                }
            }
        }
        return spans
    }
}
