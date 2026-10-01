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
/// V5 B3 — the final pass also attaches real N-best candidates: when any token is uncertain
/// (probability < `alternativesBelowProbability`), `alternativesProvider` (by default a
/// `JointTopKReplayer` over the same models) fills each token's `alternatives` with the joint's
/// top-K (K = `alternativesK`). The preview pass never does.
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
    private var _alternativesProvider: TokenAlternativesProviding?
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

    /// V5 B3 — per-token top-K source for the final pass (nil = no alternates).
    public var alternativesProvider: TokenAlternativesProviding? {
        get { lock.withLock { _alternativesProvider } }
        set { lock.withLock { _alternativesProvider = newValue } }
    }

    /// Candidates per token (V5 B3: K = 4).
    public var alternativesK = 4
    /// Replay only when some token's probability is below this (confident utterances skip the cost).
    public var alternativesBelowProbability: Float = 0.9

    /// What the last boosted final pass changed (nil when unboosted / nothing found). Lab + logs.
    public var lastBoost: BoostOutcome? { lock.withLock { _lastBoost } }

    /// - Parameter models: already-loaded `AsrModels` (v3, ultra, redux or tdtCtc110m). Loading is the
    ///   `ModelManager`'s job so warm-start and unload live in one place.
    /// - Parameter alternatives: install a `JointTopKReplayer` over `models` (V5 B3) when the joint exposes top-K.
    public init(models: AsrModels, name: String = "fluidaudio.tdt", language: Language? = .english,
                alternatives: Bool = true) async throws {
        self.name = name
        self._alternativesProvider = alternatives ? JointTopKReplayer(models: models) : nil
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
        let (st0, booster, provider) = lock.withLock { (state, _booster, _alternativesProvider) }
        var st = st0
        let result = try await finalManager.transcribe(encoderFrames.values, decoderState: &st, language: language)
        var tokens = Self.tokens(from: result.tokenTimings ?? [], timeOffset: encoderFrames.timeOffset)
        let newState = st
        if let provider {
            tokens = await Self.attachAlternatives(tokens, samples: encoderFrames.values, timeOffset: encoderFrames.timeOffset,
                                                   provider: provider, k: alternativesK,
                                                   belowProbability: alternativesBelowProbability)
        }
        var outcome: BoostOutcome?
        if let booster {
            // Rescorer works on chunk-local time (zero = first sample of `values`).
            let local = tokens.map { Self.shift($0, by: -encoderFrames.timeOffset) }
            if let o = await booster.boost(tokens: local, samples: encoderFrames.values) {
                outcome = o
                tokens = Self.carryAlternatives(from: tokens,
                                                to: o.tokens.map { Self.shift($0, by: encoderFrames.timeOffset) })
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
                            startTime: t.startTime + dt, endTime: t.endTime + dt, alternatives: t.alternatives)
    }

    /// V5 B3 — fill `alternatives` from `provider` when some token is below `belowProbability`.
    /// Provider failures leave the tokens as they were (alternates are an extra, never a blocker).
    static func attachAlternatives(_ tokens: [DecodedToken], samples: [Float], timeOffset: TimeInterval,
                                   provider: TokenAlternativesProviding, k: Int,
                                   belowProbability: Float) async -> [DecodedToken] {
        guard k > 0, tokens.contains(where: { $0.probability < belowProbability }) else { return tokens }
        let local = tokens.map { shift($0, by: -timeOffset) }
        guard let alts = try? await provider.alternatives(for: local, samples: samples, k: k),
              alts.count == tokens.count else { return tokens }
        var out = tokens
        for i in out.indices {
            out[i].alternatives = alts[i].filter { $0.tokenId != out[i].tokenId }.prefix(k).map { $0 }
        }
        return out
    }

    /// Keeps each unchanged token's alternatives across a boost (matched on id + start time); a
    /// token the booster swapped in gets none (its candidates were for the replaced piece).
    static func carryAlternatives(from before: [DecodedToken], to after: [DecodedToken]) -> [DecodedToken] {
        func key(_ t: DecodedToken) -> String { "\(t.tokenId)@\(Int((t.startTime * 1000).rounded()))" }
        var map: [String: [TokenAlternative]] = [:]
        for t in before where !t.alternatives.isEmpty { map[key(t)] = t.alternatives }
        guard !map.isEmpty else { return after }
        return after.map { t in
            var t = t
            if t.alternatives.isEmpty, let a = map[key(t)] { t.alternatives = a }
            return t
        }
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
