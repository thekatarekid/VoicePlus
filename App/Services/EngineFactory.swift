import Engine
import Foundation
import Shared

/// Wraps any `RecognizerProvider` and keeps the resolved final recognizer so a fresh
/// `ShallowFusionBiaser` (Bet 2) can be installed on its decoder before every utterance.
/// Apple Speech has no decoder hook, so biasing is silently a no-op there.
public final class BiasingRecognizerProvider: RecognizerProvider, @unchecked Sendable {
    private let inner: RecognizerProvider
    private let lock = NSLock()
    private var final: FinalRecognizer?
    public private(set) var biasingInstalled = false

    public init(inner: RecognizerProvider) { self.inner = inner }

    public func resolve() async throws -> (final: FinalRecognizer, preview: PreviewRecognizer?) {
        let r = try await inner.resolve()
        lock.withLock { final = r.final }
        return r
    }

    public var finalRecognizerName: String? { lock.withLock { final?.name } }

    /// Installs (or clears, when nil) the biaser on the decoder-backed recognizer.
    public func install(_ biaser: LogitBiaser?) {
        let recognizer = lock.withLock { final }
        guard let decoderBacked = recognizer as? DecoderFinalRecognizer else {
            lock.withLock { biasingInstalled = false }
            return
        }
        decoderBacked.decoder.biaser = biaser
        lock.withLock { biasingInstalled = biaser != nil }
    }
}

/// Picks the engine for this launch. `RealEngine` over the live audio stack with the best
/// recognizer on disk, falling back to Apple's on-device Speech until a Parakeet model lands.
///
/// The mock engine is reachable **only** by explicit developer opt-in (`VOICEPLUS_ENGINE=mock` /
/// `VOICEPLUS_FIXTURE`). When no recognizer exists at all the factory returns `UnavailableEngine`,
/// which emits no transcript ever. Until 1.6.9 it silently substituted the `email_reply` fixture
/// here, so a fresh install would preview and *type* fabricated sentences the user never said.
public enum EngineFactory {
    public enum Kind: Equatable, Sendable {
        case mock(fixture: String)
        case real(recognizer: String)
        case unavailable(reason: String)
    }

    public struct Built {
        public var engine: any EngineProtocol
        public var kind: Kind
        public var audio: PipelineAudioSource?
        public var provider: BiasingRecognizerProvider?
        public var modelManager: ModelManager?
        /// P6.3 — script-aware routing over the final recognizer (nil under the mock engine).
        public var codeSwitch: CodeSwitchRouter?
    }

    public static func mockFixtureName(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let f = environment["VOICEPLUS_FIXTURE"], !f.isEmpty { return f }
        if environment["VOICEPLUS_ENGINE"] == "mock" { return "email_reply" }
        return nil
    }

    public static func makeMock(fixture name: String) -> Built {
        let engine: MockEngine
        if let m = try? MockEngine(fixtureNamed: name) {
            engine = m
        } else {
            engine = MockEngine(fixture: TranscriptFixture(name: "inline", spans: [
                .init(text: "Hello from VoicePlus.", confidence: 0.95, audioStart: 0, audioEnd: 1, delayMs: 300),
            ]))
        }
        return Built(engine: engine, kind: .mock(fixture: name), audio: nil, provider: nil, modelManager: nil)
    }

    public static let noRecognizerReason = "No speech model installed"

    /// The engine used when nothing on this machine can recognise speech. Never emits transcript.
    public static func makeUnavailable(reason: String = noRecognizerReason, manager: ModelManager? = nil) -> Built {
        Built(engine: UnavailableEngine(reason: reason), kind: .unavailable(reason: reason),
              audio: nil, provider: nil, modelManager: manager)
    }

    /// Real stack, or an honestly-unavailable engine when nothing can recognise speech here.
    public static func make(environment: [String: String] = ProcessInfo.processInfo.environment) async -> Built {
        if let fixture = mockFixtureName(environment: environment) { return makeMock(fixture: fixture) }

        let manager = ModelManager()
        let choice = await RecognizerFactory.chooseFinal(manager: manager)
        guard let choice else {
            Log.engine.error("no ASR model on disk and Apple Speech unavailable; dictation disabled")
            return makeUnavailable(manager: manager)
        }

        let vad = await VADFactory.make()
        let capture = AcousticCaptureSource(wrapping: CoreAudioCaptureSource(), profile: .default)
        let pipeline = AudioPipeline(source: capture, vad: vad)
        let audio = PipelineAudioSource(pipeline: pipeline)
        let provider = BiasingRecognizerProvider(inner: ModelManagerRecognizerProvider(manager: manager))
        let engine = RealEngine(audio: audio, provider: provider)
        let name: String
        switch choice {
        case .tdtV3: name = "Parakeet TDT 0.6B v3"
        case .tiny: name = "Parakeet TDT-CTC 110M"
        case .appleSpeech: name = "Apple Speech (on-device)"
        }
        Log.engine.info("real engine: \(name), vad=\(vad.name)")
        var built = Built(engine: engine, kind: .real(recognizer: name), audio: audio, provider: provider, modelManager: manager)
        // P6.3 — code-switch router over the same final recognizer; the Indic backend loads
        // only when its CoreML weights are installed (otherwise routing reports why).
        let indicStatus = IndicASRAvailability.check(modelsDirectory: ModelCatalog.modelsRoot())
        built.codeSwitch = CodeSwitchRouter(primary: LazyProviderFinalRecognizer(provider: provider),
                                            indic: UnavailableIndicBackend(status: indicStatus))
        if case .available(let path) = indicStatus { Log.engine.info("indic ASR weights present at \(path) (backend pending)") }
        return built
    }
}

/// P6.3 — `FinalRecognizer` face over the lazily-resolved provider recognizer, so the
/// `CodeSwitchRouter` can be built before the model finishes loading.
public final class LazyProviderFinalRecognizer: FinalRecognizer, @unchecked Sendable {
    public let name = "provider-final"
    private let provider: BiasingRecognizerProvider
    public init(provider: BiasingRecognizerProvider) { self.provider = provider }
    public func recognize(_ samples: [Float]) async throws -> [TranscriptSpan] {
        try await provider.resolve().final.recognize(samples)
    }
}
