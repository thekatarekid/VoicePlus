import Foundation
import Shared
import Testing
@testable import Engine

/// 1.7.4 regression cover for the "Warming up…" hang.
///
/// `start(prewarm:)` used to resolve the recognizers *before* opening capture: on a cold CoreML
/// compile the pill sat on "Warming up…" with the microphone shut, and every word the user said
/// while waiting was gone. Capture now opens first and the samples are buffered while the model
/// loads. The state stays `.prewarming` — honest — but it is a *recording* warm-up, and it is
/// bounded by the resolve rather than open-ended.
@Suite("RealEngine cold start")
struct RealEngineColdStartTests {
    /// A provider that takes its time, the way a first CoreML load does.
    final class SlowProvider: RecognizerProvider, @unchecked Sendable {
        let final: ScriptedFinal
        let preview: ScriptedPreview?
        let delay: TimeInterval
        let started = Box(false)
        let error: Error?
        init(final: ScriptedFinal, preview: ScriptedPreview? = nil, delay: TimeInterval = 0.2, error: Error? = nil) {
            self.final = final; self.preview = preview; self.delay = delay; self.error = error
        }
        func resolve() async throws -> (final: FinalRecognizer, preview: PreviewRecognizer?) {
            started.value = true
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if let error { throw error }
            return (final, preview)
        }

        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var stored: Bool
            init(_ v: Bool) { stored = v }
            var value: Bool {
                get { lock.withLock { stored } }
                set { lock.withLock { stored = newValue } }
            }
        }
    }

    /// The words spoken during a cold start reach the final pass instead of being dropped.
    @Test func audioSpokenWhileTheModelLoadsIsKept() async throws {
        let final = ScriptedFinal(spans: [TranscriptSpan(text: "hi", confidence: 0.9, audioRange: 0...1, provenance: [.asr])])
        let audio = ManualAudioSource()
        let provider = SlowProvider(final: final, preview: ScriptedPreview(), delay: 0.3)
        let engine = RealEngine(audio: audio, provider: provider)

        // Launch fix (RC2): `start()` returns as soon as capture is open; the model keeps loading.
        try await engine.start(prewarm: true)
        #expect(audio.sink != nil, "capture must be open")
        #expect(!engine.isModelLoaded && engine.isModelLoading, "the model is still loading behind an open microphone")
        #expect(engine.state.caseName == "listening", "the microphone is recording: that is listening, not \"Starting…\"")
        audio.push([Float](repeating: 0.2, count: 8_000))   // 0.5 s spoken during warm-up

        try await waitForCondition { engine.isModelLoaded }
        audio.push([Float](repeating: 0.2, count: 8_000))
        _ = try await engine.stop()
        #expect(final.received.count == 16_000, "the words spoken during warm-up were dropped again")
    }

    /// Preview text for those words is not thrown away either — it is flushed once the recognizer
    /// exists, rather than discarded block by block while it was nil.
    @Test func previewOfWarmUpAudioIsFlushedOnceTheModelLands() async throws {
        let preview = ScriptedPreview()
        let audio = ManualAudioSource()
        let engine = RealEngine(audio: audio, provider: SlowProvider(final: ScriptedFinal(spans: []), preview: preview, delay: 0.3))
        try await engine.start(prewarm: true)
        audio.push([Float](repeating: 0.2, count: 8_000))
        try await waitForCondition { preview.fed > 0 }
        #expect(preview.fed == 8_000, "warm-up audio never reached the preview recognizer")
        await engine.cancel()
    }

    /// A cold start whose model never loads closes the microphone it opened. The session must not
    /// be left holding capture with no recognizer behind it, and the key-up reports the failure.
    @Test func aFailedColdStartReleasesCapture() async throws {
        struct Boom: Error {}
        let audio = CountingAudioSource()
        let engine = RealEngine(audio: audio, provider: SlowProvider(final: ScriptedFinal(spans: []), delay: 0.05, error: Boom()))
        try await engine.start(prewarm: true)
        try await waitForCondition { audio.stops == 1 }
        #expect(engine.state.caseName == "error")
        await #expect(throws: Boom.self) { try await engine.stop() }
        // And the session rolled back: a second start is not refused as `alreadyListening`.
        #expect(await engine.bufferedSampleCount() == 0)
        #expect(audio.stops == 1, "a cold start that failed left the microphone open, or closed it twice")
    }

    /// `preloadModel()` is the eager path the app runs at launch: it loads the model and publishes
    /// no state at all, so nothing appears on screen for work nobody asked for.
    @Test func preloadLoadsTheModelWithoutTouchingEngineState() async throws {
        let provider = SlowProvider(final: ScriptedFinal(spans: []), delay: 0.05)
        let engine = RealEngine(audio: ManualAudioSource(), provider: provider)
        #expect(!engine.isModelLoaded)
        #expect(await engine.preloadModel())
        #expect(engine.isModelLoaded)
        #expect(engine.state == .idle, "preload must not publish 'Warming up…' at launch")

        // And the press that follows is a warm one: it goes straight to listening.
        try await engine.start(prewarm: true)
        #expect(engine.state.caseName == "listening")
        await engine.cancel()
    }
}

/// Polls `condition` until it holds or the deadline passes. V5 J1: 90 s ceiling — a parallel
/// full-package run starved these waits past 20 s; it only costs time when the test fails anyway.
private func waitForCondition(timeoutMs: Int = 90_000, _ condition: @Sendable () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
    while Date() < deadline {
        if condition() { return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    Issue.record("timed out after \(timeoutMs) ms waiting for a condition")
}

/// An `AudioSource` that counts what the engine did to it.
final class CountingAudioSource: AudioSource, @unchecked Sendable {
    var sink: ((UnsafeBufferPointer<Float>) -> Void)?
    private let lock = NSLock()
    private var _stops = 0
    var stops: Int { lock.withLock { _stops } }
    func prewarm() throws {}
    func start() throws {}
    func stop() { lock.withLock { _stops += 1 } }
}
