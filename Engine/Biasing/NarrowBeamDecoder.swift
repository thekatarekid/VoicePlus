import Foundation

/// Optional narrow beam (width 2–4) over a `StepwiseDecoder`, applying the biaser inside the
/// beam. Greedy+boost is the default; install this only when the Lab shows it pays (P1.5 T3).
public final class NarrowBeamBiasedDecoder: Decoder, @unchecked Sendable {
    public let name: String
    public let width: Int
    private let inner: StepwiseDecoder
    private let lock = NSLock()
    private var _biaser: LogitBiaser?

    public var biaser: LogitBiaser? {
        get { lock.withLock { _biaser } }
        set { lock.withLock { _biaser = newValue } }
    }

    public init(inner: StepwiseDecoder, width: Int = 3) {
        self.inner = inner
        self.width = min(max(width, 2), 4)
        self.name = "beam\(self.width)(\(inner.name))"
    }

    private struct Hyp { var ids: [Int]; var tokens: [DecodedToken]; var score: Float; var biased: Float }

    public func decode(encoderFrames: EncoderFrames) async throws -> DecodeResult {
        let biaser = lock.withLock { _biaser }
        var beam = [Hyp(ids: [], tokens: [], score: 0, biased: 0)]
        var step = 0
        while true {
            var next: [Hyp] = []
            var any = false
            for h in beam {
                guard let cand = inner.candidates(step: step, prefix: h.ids, frames: encoderFrames) else { next.append(h); continue }
                any = true
                let lps = cand.logSoftmax()
                let state = PrefixState(tokenIds: h.ids, text: h.tokens.renderedText, frameIndex: step)
                let bonus = biaser?.boost(tokenIds: cand.ids, prefixState: state) ?? [:]
                for (i, id) in cand.ids.enumerated() {
                    let tok = DecodedToken(tokenId: id, text: inner.pieceText(for: id), logProb: lps[i], startTime: cand.startTime, endTime: cand.endTime)
                    next.append(Hyp(ids: h.ids + [id], tokens: h.tokens + [tok], score: h.score + lps[i], biased: h.biased + lps[i] + (bonus[id] ?? 0)))
                }
            }
            if !any { break }
            // Merge identical prefixes, keep top `width` by biased score.
            var best: [[Int]: Hyp] = [:]
            for h in next where (best[h.ids]?.biased ?? -.infinity) < h.biased { best[h.ids] = h }
            beam = Array(best.values.sorted { $0.biased > $1.biased }.prefix(width))
            step += 1
        }
        let top = beam.max { $0.biased < $1.biased } ?? Hyp(ids: [], tokens: [], score: 0, biased: 0)
        return DecodeResult(tokens: top.tokens, score: top.score)
    }

    public func reset() async { await inner.reset() }
}
