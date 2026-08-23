import FluidAudio
import Foundation

/// Adapter over FluidAudio's greedy TDT path (`AsrManager`). See README §Implementations for
/// the `EncoderFrames` convention: because upstream runs preprocessor+encoder+decoder as one
/// unit, this adapter consumes *packed 16 kHz samples* (`hiddenSize == 1`,
/// `frameDuration == 1/16000`) built by `frames(fromSamples:)`.
public final class FluidAudioTDTDecoder: Decoder, @unchecked Sendable {
    public static let sampleRate = 16_000
    public let name: String

    private let manager: AsrManager
    private let language: Language?
    private let lock = NSLock()
    private var _biaser: LogitBiaser?
    private var state: TdtDecoderState
    private let decoderLayers: Int
    private var emitted: [DecodedToken] = []

    public var biaser: LogitBiaser? {
        get { lock.lock(); defer { lock.unlock() }; return _biaser }
        set { lock.lock(); _biaser = newValue; lock.unlock() }
    }

    /// - Parameter models: already-loaded `AsrModels` (v3 or tdtCtc110m). Loading is the
    ///   `ModelManager`'s job so warm-start and unload live in one place.
    public init(models: AsrModels, name: String = "fluidaudio.tdt", language: Language? = .english) async throws {
        self.name = name
        self.language = language
        self.manager = AsrManager(config: .default, models: nil)
        try await manager.loadModels(models)
        self.decoderLayers = models.version.decoderLayers
        self.state = try TdtDecoderState(decoderLayers: models.version.decoderLayers)
    }

    /// Pack raw 16 kHz mono samples into the adapter's `EncoderFrames` convention.
    public static func frames(fromSamples samples: [Float], timeOffset: TimeInterval = 0) -> EncoderFrames {
        EncoderFrames(values: samples, frameCount: samples.count, hiddenSize: 1,
                      frameDuration: 1.0 / Double(sampleRate), timeOffset: timeOffset)
    }

    public func decode(encoderFrames: EncoderFrames) async throws -> DecodeResult {
        precondition(encoderFrames.hiddenSize == 1, "FluidAudioTDTDecoder expects packed samples (see README)")
        let (st0, prefix, biaser) = lock.withLock { (state, emitted, _biaser) }
        var st = st0
        let result = try await manager.transcribe(encoderFrames.values, decoderState: &st, language: language)
        let tokens = Self.tokens(from: result.tokenTimings ?? [], timeOffset: encoderFrames.timeOffset)
        let biased = BiasRescorer.apply(biaser, to: tokens, prefix: prefix)
        let newState = st
        lock.withLock { state = newState; emitted.append(contentsOf: biased) }
        return DecodeResult(tokens: biased)
    }

    public func reset() async {
        let fresh = (try? TdtDecoderState(decoderLayers: decoderLayers)) ?? TdtDecoderState.make(decoderLayers: decoderLayers)
        lock.withLock { state = fresh; emitted.removeAll() }
        await manager.reset()
    }

    /// `TokenTiming.confidence` is the softmax probability of the chosen token (clamped by
    /// upstream to ≥ 0.1 for ASRResult.confidence; per-token values are raw). logProb = ln(p).
    public static func tokens(from timings: [TokenTiming], timeOffset: TimeInterval = 0) -> [DecodedToken] {
        timings.map { t in
            let p = min(max(t.confidence, Float.leastNormalMagnitude), 1)
            return DecodedToken(tokenId: t.tokenId, text: t.token, logProb: log(p),
                                startTime: t.startTime + timeOffset, endTime: t.endTime + timeOffset)
        }
    }
}
