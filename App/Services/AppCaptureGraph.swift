import Engine
import Foundation
import Shared

/// V5 O1 (§10) — where every microphone consumer outside the engine gets its audio: the app's one
/// capture graph, `AppContainer.audio` (`AudioPipeline` + its `Broadcaster`), joined as a
/// `PipelineAudioSource.Owner` (`.meter`, `.diagnostics`) with a `Broadcaster` subscription of its
/// own. Nothing here opens a second HAL client beside dictation.
///
/// Only when the app has no engine graph (a fresh install with no ASR model: `EngineFactory` builds
/// `UnavailableEngine`, `AppContainer.audio == nil`) does this build one — **one** fallback graph per
/// process, cached, the shipping plain-tap chain minus the recognizer. When the engine graph appears
/// later, the idle fallback is released and every caller moves to the engine's graph.
///
/// The voice test (Settings › Voice), the onboarding mic meter and `--mic-selftest` go through here
/// instead of each building `CoreAudioCaptureSource()` themselves.
public final class AppCaptureGraph: @unchecked Sendable {
    /// The app's registry. `AppContainer` registers its graph on it.
    public static let app = AppCaptureGraph()

    private let lock = NSLock()
    private var _provider: (() -> PipelineAudioSource?)?
    private var fallback: PipelineAudioSource?
    private let makeFallback: () -> PipelineAudioSource

    /// `makeFallback` builds the graph used when no engine graph exists (tests inject a fixture-fed one).
    public init(makeFallback: @escaping () -> PipelineAudioSource = { AppCaptureGraph.makeStandalone().audio }) {
        self.makeFallback = makeFallback
    }

    /// The engine's graph on the app registry. `AppContainer` sets `{ self.audio }` at init.
    public static var provider: (() -> PipelineAudioSource?)? {
        get { app.provider }
        set { app.provider = newValue }
    }

    /// The app's one graph (`app.shared()`).
    public static func shared() -> PipelineAudioSource { app.shared() }

    /// True when `audio` is the app registry's fallback graph.
    public static func isFallback(_ audio: PipelineAudioSource) -> Bool { app.isFallback(audio) }

    public var provider: (() -> PipelineAudioSource?)? {
        get { lock.withLock { _provider } }
        set { lock.withLock { _provider = newValue } }
    }

    /// The one graph: the engine's when it exists, else the cached fallback.
    public func shared() -> PipelineAudioSource {
        let (engine, staleFallback) = lock.withLock { () -> (PipelineAudioSource?, PipelineAudioSource?) in
            guard let engine = _provider?() else { return (nil, nil) }
            // The engine graph exists now: an idle fallback must not stay prepared beside it.
            guard let old = fallback, !old.isCapturing else { return (engine, nil) }
            fallback = nil
            return (engine, old)
        }
        if let staleFallback {
            staleFallback.pipeline.source.release(reason: .idle)
            Log.app.info("capture graph: engine graph present; the standalone fallback was released")
        }
        if let engine { return engine }
        return lock.withLock {
            if let existing = fallback { return existing }
            let made = makeFallback()
            fallback = made
            Log.app.info("capture graph: no engine graph — one standalone capture graph (no recognizer)")
            return made
        }
    }

    /// True when `audio` is the fallback graph (not the engine's): a caller that stops using it may
    /// release it fully, which the engine's kept graph must not be (V4.7).
    public func isFallback(_ audio: PipelineAudioSource) -> Bool {
        lock.withLock { fallback === audio }
    }

    /// The pieces of a standalone graph, for `--mic-selftest`'s diagnostics.
    public struct Standalone {
        public let core: CoreAudioCaptureSource
        public let voiceProcessing: VoiceProcessingCaptureSource?
        public let capture: AcousticCaptureSource
        public let pipeline: AudioPipeline
        public let audio: PipelineAudioSource
    }

    /// The shipping capture chain minus the recognizer — `AcousticCaptureSource(wrapping:
    /// CoreAudioCaptureSource(), profile: .default)` → `AudioPipeline` → `PipelineAudioSource` — the
    /// same graph `EngineFactory` builds with enhancement off. Used for the fallback graph above and
    /// by `--mic-selftest`, which runs in its own process before any app graph exists.
    public static func makeStandalone(device: AudioDeviceInfo? = nil, policy: InputSelectionPolicy = InputSelectionPolicy(),
                                      voiceProcessing: Bool = false,
                                      options: AudioPipeline.Options = AudioPipeline.Options()) -> Standalone {
        let core = CoreAudioCaptureSource(device: device, policy: policy)
        let vp = voiceProcessing ? VoiceProcessingCaptureSource(device: device, policy: policy) : nil
        let capture = AcousticCaptureSource(wrapping: vp ?? core, profile: .default)
        let pipeline = AudioPipeline(source: capture, vad: EnergyVAD(), options: options)
        return Standalone(core: core, voiceProcessing: vp, capture: capture, pipeline: pipeline,
                          audio: PipelineAudioSource(pipeline: pipeline))
    }
}
