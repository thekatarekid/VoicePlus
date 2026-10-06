import Foundation
import Shared
import Testing
@testable import Engine

/// Launch fix (2026-10-06 investigation, RC2/RC4) — the first launch after an update spends 40–50 s
/// recompiling the CoreML stack. A press in that window must record exactly the hold, close the
/// microphone at key-up, and never hold the next press behind a model wait nobody needs any more.
@Suite("RealEngine — a press while the model is still loading")
struct RealEngineLaunchColdTests {
    /// A provider whose load finishes only when the test says so (no wall-clock sleeps).
    final class GatedProvider: RecognizerProvider, @unchecked Sendable {
        let final: ScriptedFinal
        let preview: PreviewRecognizer?
        private let lock = NSLock()
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var open = false
        private var _resolves = 0
        var resolves: Int { lock.withLock { _resolves } }

        init(final: ScriptedFinal, preview: PreviewRecognizer? = nil) { self.final = final; self.preview = preview }

        func release() {
            let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                open = true
                defer { waiters.removeAll() }
                return waiters
            }
            pending.forEach { $0.resume() }
        }

        func resolve() async throws -> (final: FinalRecognizer, preview: PreviewRecognizer?) {
            lock.withLock { _resolves += 1 }
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let ready = lock.withLock { () -> Bool in
                    if open { return true }
                    waiters.append(c)
                    return false
                }
                if ready { c.resume() }
            }
            return (final, preview)
        }
    }

    /// Counts starts/stops and pushes audio only while open, like a real microphone.
    final class Mic: AudioSource, @unchecked Sendable {
        var sink: ((UnsafeBufferPointer<Float>) -> Void)?
        private let lock = NSLock()
        private var _starts = 0, _stops = 0, running = false
        var starts: Int { lock.withLock { _starts } }
        var stops: Int { lock.withLock { _stops } }
        func prewarm() throws {}
        func start() throws { lock.withLock { _starts += 1; running = true } }
        func stop() { lock.withLock { _stops += 1; running = false } }
        func speak(seconds: Double) {
            guard lock.withLock({ running }) else { return }
            let block = [Float](repeating: 0.2, count: Int(seconds * 16_000))
            block.withUnsafeBufferPointer { sink?($0) }
        }
    }

    /// A preview recognizer whose `feed` blocks until released — the 30 s warm-up backlog.
    final class StuckPreview: PreviewRecognizer, @unchecked Sendable {
        private let lock = NSLock()
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var open = false
        private var _feeds = 0
        var feeds: Int { lock.withLock { _feeds } }
        func release() {
            let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                open = true
                defer { waiters.removeAll() }
                return waiters
            }
            pending.forEach { $0.resume() }
        }
        func feed(_ samples: [Float]) async throws -> String {
            lock.withLock { _feeds += 1 }
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let ready = lock.withLock { () -> Bool in
                    if open { return true }
                    waiters.append(c)
                    return false
                }
                if ready { c.resume() }
            }
            return "words"
        }
        func reset() async {}
    }

    static let hello = [TranscriptSpan(text: "hello", confidence: 0.9, audioRange: 0...1, provenance: [.asr])]

    /// 2026-10-04 00:13:47 — a 1.9 s hold recorded 25.9 s of a background video, because the
    /// microphone stayed open until the model resolved. The key-up closes it now; the final pass
    /// waits for the model and decodes exactly the hold.
    @Test func keyUpClosesTheMicrophoneWhileTheModelIsStillLoading() async throws {
        let final = ScriptedFinal(spans: Self.hello)
        let provider = GatedProvider(final: final)
        let mic = Mic()
        let engine = RealEngine(audio: mic, provider: provider)

        try await engine.start(prewarm: true)          // returns with the model still loading
        #expect(mic.starts == 1)
        mic.speak(seconds: 1.0)                        // the hold
        let stop = Task { try await engine.stop() }   // key-up
        try await waitFor { mic.stops == 1 }
        #expect(!engine.isModelLoaded, "the microphone closed before the model landed")
        mic.speak(seconds: 5.0)                        // the room after key-up: never recorded
        provider.release()
        let spans = try await stop.value
        #expect(spans.renderedText == "hello")
        #expect(final.received.count == 16_000, "the final pass must decode exactly the hold, nothing after key-up")
        #expect(provider.resolves == 1)
    }

    /// A press during the launch preload joins that load instead of starting a second one.
    @Test func aPressDuringTheLaunchPreloadJoinsIt() async throws {
        let provider = GatedProvider(final: ScriptedFinal(spans: Self.hello))
        let mic = Mic()
        let engine = RealEngine(audio: mic, provider: provider)
        let preload = Task { await engine.preloadModel() }
        try await waitFor { provider.resolves == 1 }
        #expect(engine.isModelLoading)
        try await engine.start(prewarm: true)
        mic.speak(seconds: 0.5)
        provider.release()
        #expect(await preload.value)
        _ = try await engine.stop()
        #expect(provider.resolves == 1, "the press resolved the models a second time, concurrently")
        #expect(!engine.isModelLoading)
    }

    /// RC4 — the turn was cancelled while its final pass waited for the model: `stop()` lets go at
    /// once, the load carries on, and the next press opens capture without waiting for it.
    @Test func abandoningReleasesAStopWaitingForTheModel() async throws {
        let provider = GatedProvider(final: ScriptedFinal(spans: Self.hello))
        let mic = Mic()
        let engine = RealEngine(audio: mic, provider: provider)
        try await engine.start(prewarm: true)
        mic.speak(seconds: 1.0)
        let stop = Task { try await engine.stop() }
        try await waitFor { mic.stops == 1 }
        // Not yet abandoned: the stop is still waiting.
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(engine.abandonPendingFinal())
        let spans = try await stop.value
        #expect(spans.isEmpty, "an abandoned wait returns no text")
        #expect(engine.isModelLoading, "the load itself carries on — the next press needs it")

        // The next press opens capture straight away, model or not.
        try await engine.start(prewarm: true)
        #expect(mic.starts == 2)
        mic.speak(seconds: 0.5)
        provider.release()
        try await waitFor { engine.isModelLoaded }
        let next = try await engine.stop()
        #expect(next.renderedText == "hello")
        #expect(provider.resolves == 1)
    }

    /// Nothing to abandon outside a waiting `stop()`: a warm stop or an idle engine is untouched.
    @Test func abandonDoesNothingWithoutAWaitingStop() async throws {
        let engine = RealEngine(audio: Mic(), provider: StaticRecognizerProvider(final: ScriptedFinal(spans: Self.hello)))
        #expect(!engine.abandonPendingFinal())
        try await engine.start(prewarm: true)
        #expect(!engine.abandonPendingFinal(), "a warm session has no model wait to abandon")
        await engine.cancel()
    }

    /// A silent cold hold does not wait for the model at all: the gates that need no model decide.
    @Test func aTooShortColdHoldDoesNotWaitForTheModel() async throws {
        let provider = GatedProvider(final: ScriptedFinal(spans: Self.hello))
        let mic = Mic()
        let engine = RealEngine(audio: mic, provider: provider)
        try await engine.start(prewarm: true)
        mic.speak(seconds: 0.1)
        let spans = try await engine.stop()            // would hang if it waited for the gate
        #expect(spans.isEmpty)
        #expect(engine.lastStopReason == .tooShort)
        provider.release()
    }

    /// The key-up never sits behind a preview backlog (10:16:47.9 → 52.7 on 2026-10-06, for a final
    /// pass whose own stages took 987 ms): the drain is bounded, the final pass runs.
    @Test func keyUpDoesNotWaitForAStuckPreview() async throws {
        let final = ScriptedFinal(spans: Self.hello)
        let preview = StuckPreview()
        let mic = Mic()
        let engine = RealEngine(audio: mic, provider: StaticRecognizerProvider(final: final, preview: preview))
        try await engine.start(prewarm: true)
        mic.speak(seconds: 1.0)
        try await waitFor { preview.feeds >= 1 }
        let t0 = Date()
        let spans = try await engine.stop()
        #expect(spans.renderedText == "hello")
        #expect(Date().timeIntervalSince(t0) < 5, "key-up waited for the preview backlog")
        preview.release()
    }

    private func waitFor(timeoutMs: Int = 30_000, _ condition: @Sendable () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        Issue.record("timed out waiting for a condition")
    }
}
