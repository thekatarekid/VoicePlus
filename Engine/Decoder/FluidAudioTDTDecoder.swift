import FluidAudio
import Foundation

/// Adapter over FluidAudio's greedy TDT path (`AsrManager`). See README §Implementations for
/// the `EncoderFrames` convention: because upstream runs preprocessor+encoder+decoder as one
/// unit, this adapter consumes *packed 16 kHz samples* (`hiddenSize == 1`,
/// `frameDuration == 1/16000`) built by `frames(fromSamples:)`.
///
/// V5 B1 — two `AsrManager`s share one `AsrModels` (the MLModels are shared, not duplicated):
/// - **streaming** (`decodePreview`) — the polling preview; never boosted, so the pill never shows a
///   term the CTC pass has not confirmed and the preview stays as fast as it was;
/// - **final** (`decode`) — the utterance's final pass; when a `booster` is installed its tokens are
///   rescored against CTC keyword evidence (`CTCVocabularyBooster`).
/// The legacy `biaser` (decode-time `LogitBiaser`) is accepted for protocol conformance and ignored:
/// it could only re-score the chosen token and never changed a word (V5 A1).
public final class FluidAudioTDTDecoder: Decoder, VocabularyBoostable, PreviewDecoding, @unchecked Sendable {
    public static let sampleRate = 16_000
    public let name: String

    private let finalManager: AsrManager
    private let streamingManager: AsrManager
    private let language: Language?
    private let lock = NSLock()
    private var _biaser: LogitBiaser?
    private var _booster: VocabularyBooster?
    private var _lastBoost: BoostOutcome?
    private var state: TdtDecoderState
    private let decoderLayers: Int

    public var biaser: LogitBiaser? {
        get { lock.withLock { _biaser } }
        set { lock.withLock { _biaser = newValue } }
    }

    public var booster: VocabularyBooster? {
        get { lock.withLock { _booster } }
        set { lock.withLock { _booster = newValue } }
    }

    /// What the last boosted final pass changed (nil when unboosted / nothing found). Lab + logs.
    public var lastBoost: BoostOutcome? { lock.withLock { _lastBoost } }

    /// - Parameter models: already-loaded `AsrModels` (v3, ultra, redux or tdtCtc110m). Loading is the
    ///   `ModelManager`'s job so warm-start and unload live in one place.
    public init(models: AsrModels, name: String = "fluidaudio.tdt", language: Language? = .english) async throws {
        self.name = name
        self.language = language
        self.finalManager = AsrManager(config: .default, models: nil)
        self.streamingManager = AsrManager(config: .default, models: nil)
        try await finalManager.loadModels(models)
        try await streamingManager.loadModels(models)
        self.decoderLayers = models.version.decoderLayers
        self.state = try TdtDecoderState(decoderLayers: models.version.decoderLayers)
    }

    /// Pack raw 16 kHz mono samples into the adapter's `EncoderFrames` convention.
    public static func frames(fromSamples samples: [Float], timeOffset: TimeInterval = 0) -> EncoderFrames {
        EncoderFrames(values: samples, frameCount: samples.count, hiddenSize: 1,
                      frameDuration: 1.0 / Double(sampleRate), timeOffset: timeOffset)
    }

    /// Final pass: greedy TDT, then CTC vocabulary boosting when a booster is installed.
    public func decode(encoderFrames: EncoderFrames) async throws -> DecodeResult {
        precondition(encoderFrames.hiddenSize == 1, "FluidAudioTDTDecoder expects packed samples (see README)")
        let (st0, booster) = lock.withLock { (state, _booster) }
        var st = st0
        let result = try await finalManager.transcribe(encoderFrames.values, decoderState: &st, language: language)
        var tokens = Self.tokens(from: result.tokenTimings ?? [], timeOffset: encoderFrames.timeOffset)
        let newState = st
        var outcome: BoostOutcome?
        if let booster {
            // Rescorer works on chunk-local time (zero = first sample of `values`).
            let local = tokens.map { Self.shift($0, by: -encoderFrames.timeOffset) }
            if let o = await booster.boost(tokens: local, samples: encoderFrames.values) {
                outcome = o
                tokens = o.tokens.map { Self.shift($0, by: encoderFrames.timeOffset) }
            }
        }
        lock.withLock { state = newState; _lastBoost = outcome }
        return DecodeResult(tokens: tokens)
    }

    /// Preview pass on the streaming manager: never boosted, never touches the final pass's state.
    public func decodePreview(encoderFrames: EncoderFrames) async throws -> DecodeResult {
        precondition(encoderFrames.hiddenSize == 1, "FluidAudioTDTDecoder expects packed samples (see README)")
        var st = try TdtDecoderState(decoderLayers: decoderLayers)
        let result = try await streamingManager.transcribe(encoderFrames.values, decoderState: &st, language: language)
        return DecodeResult(tokens: Self.tokens(from: result.tokenTimings ?? [], timeOffset: encoderFrames.timeOffset))
    }

    public func reset() async {
        let fresh = (try? TdtDecoderState(decoderLayers: decoderLayers)) ?? TdtDecoderState.make(decoderLayers: decoderLayers)
        lock.withLock { state = fresh; _lastBoost = nil }
        await finalManager.reset()
    }

    static func shift(_ t: DecodedToken, by dt: TimeInterval) -> DecodedToken {
        guard dt != 0 else { return t }
        return DecodedToken(tokenId: t.tokenId, text: t.text, logProb: t.logProb,
                            startTime: t.startTime + dt, endTime: t.endTime + dt)
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
