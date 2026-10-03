import Engine
import Foundation
import Shared

/// Wraps any `RecognizerProvider` and keeps the resolved final recognizers so a fresh
/// per-utterance vocabulary booster (V5 B1, CTC boosting) can be installed on their decoders before
/// every utterance. Apple Speech has no decoder, so boosting is silently a no-op there.
///
/// H20 — wrong-instance fix. Every `inner.resolve()` builds a *new* recogniser, and `resolve()` has
/// several callers (the engine's prewarm / cold start, the code-switch router, correction
/// re-recognition, meetings). Until H20 only the most recently resolved instance received the
/// booster, so any other caller's resolve moved the booster off the instance `RealEngine` holds and
/// its final pass ran with no booster at all. Now the booster goes on every live decoder-backed
/// recogniser this provider has handed out (held weakly), and a recogniser resolved *after* the
/// install (cold start, model revision change) receives the current booster as it is handed out.
public final class BiasingRecognizerProvider: RecognizerProvider, @unchecked Sendable {
    private struct WeakRecognizer { weak var value: DecoderFinalRecognizer? }

    private let inner: RecognizerProvider
    private let lock = NSLock()
    private var final: FinalRecognizer?
    private var handedOut: [WeakRecognizer] = []
    private var current: VocabularyBooster?
    public private(set) var boostingInstalled = false
    /// H20 — how many live decoder-backed recognisers carry the current booster (diagnostics/tests).
    public private(set) var boostTargetCount = 0

    public init(inner: RecognizerProvider) { self.inner = inner }

    public func resolve() async throws -> (final: FinalRecognizer, preview: PreviewRecognizer?) {
        let r = try await inner.resolve()
        let decoderBacked = r.final as? DecoderFinalRecognizer
        let booster: VocabularyBooster? = lock.withLock {
            final = r.final
            guard let decoderBacked else { return nil }
            handedOut.removeAll { $0.value == nil }
            if !handedOut.contains(where: { $0.value === decoderBacked }) { handedOut.append(WeakRecognizer(value: decoderBacked)) }
            return current
        }
        if let decoderBacked, let booster {
            let ok = decoderBacked.installBooster(booster)
            lock.withLock {
                if ok { boostingInstalled = true }
                boostTargetCount = handedOut.filter { $0.value != nil }.count
            }
        }
        return r
    }

    public var finalRecognizerName: String? { lock.withLock { final?.name } }

    /// Installs (or clears, when nil) the final-pass booster on every live decoder-backed recognizer.
    public func install(_ booster: VocabularyBooster?) {
        let targets: [DecoderFinalRecognizer] = lock.withLock {
            current = booster
            handedOut.removeAll { $0.value == nil }
            return handedOut.compactMap(\.value)
        }
        var installed = 0
        for t in targets where t.installBooster(booster) { installed += 1 }
        lock.withLock {
            boostingInstalled = installed > 0
            boostTargetCount = booster == nil ? 0 : installed
        }
        if let booster, installed == 0 {
            // Not an error before the first resolve: the booster is handed to the recogniser the
            // engine resolves next. Notice-level so a turn that never boosts can be explained.
            Log.engine.notice("boost: \(booster.terms.count) terms held — no decoder-backed recogniser resolved yet")
        }
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
    /// - Parameter manager: reuse an existing `ModelManager` (a rebuild after a download must not
    ///   fork a second view of the models directory); nil creates one.
    public static func make(environment: [String: String] = ProcessInfo.processInfo.environment,
                            manager existing: ModelManager? = nil) async -> Built {
        if let fixture = mockFixtureName(environment: environment) { return makeMock(fixture: fixture) }

        let manager = existing ?? ModelManager()
        let choice = await RecognizerFactory.chooseFinal(manager: manager)
        guard let choice else {
            Log.engine.error("no ASR model on disk and Apple Speech unavailable; dictation disabled")
            return makeUnavailable(manager: manager)
        }

        let vad = await VADFactory.make(manager: manager)   // V5 C6: Silero via ModelManager.locate first
        // R1.4 — the shipping capture graph, chosen by measurement. `CoreAudioCaptureSource` is a
        // plain tap (its graph line reads `vp=false`) and `.default` is now the profile that matches
        // it: no spectral gate, no echo cancellation, pre-roll only. Profile and graph therefore
        // agree, and `AcousticCaptureSource.effectiveAEC` reports the graph's fact into the recorder
        // manifest — ending the `aec=appleVoiceProcessing` beside `vp=false` contradiction that the
        // twenty real-room manifests were filed with. To run Apple's AEC instead, both halves must
        // move together: `VoiceProcessingCaptureSource` + `.voiceProcessing` (see --mic-selftest-vp).
        // Evidence: Engine/Audio/Robustness/SUITES.md, "Measured: which capture chain should ship?".
        //
        // V5 C1/C1b — Settings › Voice "Noise and echo reduction" picks the graph; `CaptureGraphPlan`
        // moves source and profile together. Default `.off` (the R1.4 plain tap) until the V1 gate.
        let enhancement = CaptureEnhancement.current(environment: environment)
        let localVQE = enhancement == .localVQE ? await LocalVQEStage.loadIfAvailable() : nil
        let plan = CaptureGraphPlan.plan(for: enhancement, localVQEAvailable: localVQE != nil)
        let capture = plan.makeCaptureSource(plainTap: { CoreAudioCaptureSource() },
                                             voiceProcessing: { VoiceProcessingCaptureSource() },
                                             neuralStage: localVQE,
                                             installsRecordingHooks: true)   // V5 F3
        Log.engine.info("\(plan.logLine)")
        var options = plan.apply(to: AudioPipeline.Options())
        // V5 C4 — Smart Turn ends a latched segment at a finished sentence (≥ 400 ms pause) instead of
        // waiting out the whole pause setting. Off when the CoreML export is not installed.
        options.turnPredictor = await SmartTurnModel.loadIfAvailable()
        let pipeline = AudioPipeline(source: capture, vad: vad, options: options)
        let audio = PipelineAudioSource(pipeline: pipeline)
        // V5 G1/G2 — the LANG1 languages route the final pass (Hinglish / Nemotron when installed).
        let routed = LanguageASRRouting.provider(inner: ModelManagerRecognizerProvider(manager: manager), manager: manager)
        let provider = BiasingRecognizerProvider(inner: routed)
        let engine = RealEngine(audio: audio, provider: provider)
        let name: String
        switch choice {
        case .ultra: name = "Parakeet Ultra"              // V5 B5
        case .tdtV3: name = "Parakeet TDT 0.6B v3"
        case .redux: name = "Parakeet Redux"              // V5 B5
        case .tiny: name = "Parakeet TDT-CTC 110M"
        case .appleSpeech: name = "Apple Speech (on-device)"
        }
        Log.engine.info("real engine: \(name), vad=\(vad.name)")
        var built = Built(engine: engine, kind: .real(recognizer: name), audio: audio, provider: provider, modelManager: manager)
        // P6.3 — code-switch router over the same final recognizer; the Indic backend loads
        // only when its CoreML weights are installed (otherwise routing reports why).
        let indicStatus = IndicASRAvailability.check(modelsDirectory: ModelCatalog.modelsRoot())
        built.codeSwitch = CodeSwitchRouter(primary: LazyProviderFinalRecognizer(provider: provider),
                                            indic: LanguageASRRouting.shared.hinglish()   // V5 G1 (X7)
                                                ?? UnavailableIndicBackend(status: indicStatus))
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
