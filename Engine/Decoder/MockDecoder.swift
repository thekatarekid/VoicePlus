import Foundation

/// Replays scripted tokens; used by tests and the Lab. Like `FluidAudioTDTDecoder` it accepts and
/// ignores `biaser` (V5 A1), and applies an installed final-pass `booster` (V5 B1) to each chunk
/// (samples are `encoderFrames.values`).
public final class MockDecoder: Decoder, VocabularyBoostable, @unchecked Sendable {
    public let name = "mock"
    private let lock = NSLock()
    private var _biaser: LogitBiaser?
    private var _booster: VocabularyBooster?
    private var script: [DecodedToken]
    private var emitted: [DecodedToken] = []
    public private(set) var decodeCalls = 0

    public var biaser: LogitBiaser? {
        get { lock.lock(); defer { lock.unlock() }; return _biaser }
        set { lock.lock(); _biaser = newValue; lock.unlock() }
    }

    public var booster: VocabularyBooster? {
        get { lock.withLock { _booster } }
        set { lock.withLock { _booster = newValue } }
    }

    public init(script: [DecodedToken]) { self.script = script }

    public func decode(encoderFrames: EncoderFrames) async throws -> DecodeResult {
        let result = decodeSync(encoderFrames)
        guard let booster, let boosted = await booster.boost(tokens: result.tokens, samples: encoderFrames.values) else {
            return result
        }
        return DecodeResult(tokens: boosted.tokens)
    }

    private func decodeSync(_ encoderFrames: EncoderFrames) -> DecodeResult {
        lock.lock(); defer { lock.unlock() }
        decodeCalls += 1
        // Emit the tokens that fall inside this chunk's time window.
        let start = encoderFrames.timeOffset
        let end = start + Double(encoderFrames.frameCount) * encoderFrames.frameDuration
        let chunk = script.filter { $0.startTime >= start && $0.startTime < end && !emitted.contains($0) }
        emitted.append(contentsOf: chunk)
        return DecodeResult(tokens: chunk)
    }

    public func reset() async {
        lock.withLock { emitted.removeAll() }
    }
}
