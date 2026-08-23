import Foundation

/// Replays scripted tokens; used by tests, the Lab, and P1.5/P1.6 while the real fork lands.
/// Honors `biaser` via the same post-hoc rescoring rule as `FluidAudioTDTDecoder`.
public final class MockDecoder: Decoder, @unchecked Sendable {
    public let name = "mock"
    private let lock = NSLock()
    private var _biaser: LogitBiaser?
    private var script: [DecodedToken]
    private var emitted: [DecodedToken] = []
    public private(set) var decodeCalls = 0

    public var biaser: LogitBiaser? {
        get { lock.lock(); defer { lock.unlock() }; return _biaser }
        set { lock.lock(); _biaser = newValue; lock.unlock() }
    }

    public init(script: [DecodedToken]) { self.script = script }

    public func decode(encoderFrames: EncoderFrames) async throws -> DecodeResult {
        decodeSync(encoderFrames)
    }

    private func decodeSync(_ encoderFrames: EncoderFrames) -> DecodeResult {
        lock.lock(); defer { lock.unlock() }
        decodeCalls += 1
        // Emit the tokens that fall inside this chunk's time window.
        let start = encoderFrames.timeOffset
        let end = start + Double(encoderFrames.frameCount) * encoderFrames.frameDuration
        let chunk = script.filter { $0.startTime >= start && $0.startTime < end && !emitted.contains($0) }
        let biased = BiasRescorer.apply(_biaser, to: chunk, prefix: emitted)
        emitted.append(contentsOf: chunk)
        return DecodeResult(tokens: biased)
    }

    public func reset() async {
        lock.withLock { emitted.removeAll() }
    }
}

/// Post-hoc application of a `LogitBiaser` when the decoder cannot re-pick tokens
/// (see README §Implementations). Bonus is added in log space and clamped to ≤ 0 so a
/// boosted token never reports >100% confidence. Shared by Mock and FluidAudio adapters.
public enum BiasRescorer {
    public static func apply(_ biaser: LogitBiaser?, to tokens: [DecodedToken], prefix: [DecodedToken]) -> [DecodedToken] {
        guard let biaser else { return tokens }
        var out: [DecodedToken] = []
        var ids = prefix.map(\.tokenId)
        var text = prefix.renderedText
        for (i, token) in tokens.enumerated() {
            let state = PrefixState(tokenIds: ids, text: text, frameIndex: i)
            let bonus = biaser.boost(tokenIds: [token.tokenId], prefixState: state)[token.tokenId] ?? 0
            var t = token
            t.logProb = min(0, token.logProb + bonus)
            out.append(t)
            ids.append(token.tokenId)
            text = (prefix + out).renderedText
        }
        return out
    }
}
