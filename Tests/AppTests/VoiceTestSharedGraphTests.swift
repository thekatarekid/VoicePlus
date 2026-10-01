import Engine
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// V5 O1 (§10) — the voice test, the onboarding meter and diagnostics join the app's one capture
/// graph (`AppCaptureGraph`) instead of opening their own microphone.
@Suite("V5 O1 meters on the shared capture graph")
struct VoiceTestSharedGraphTests {
    typealias CountingSource = SharedCaptureGraphTests.CountingSource

    private func graph() -> (PipelineAudioSource, CountingSource) {
        let source = CountingSource()
        var options = AudioPipeline.Options()
        options.noAudioTimeout = 0
        options.digitalSilenceTimeout = 0
        let audio = PipelineAudioSource(pipeline: AudioPipeline(source: source, vad: EnergyVAD(), options: options))
        audio.requireMicrophonePermission = false
        return (audio, source)
    }

    private func eventually(_ cond: () -> Bool) async {
        for _ in 0..<400 where !cond() { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    private func tone(_ n: Int = 1_600) -> [Float] {
        (0..<n).map { 0.1 * sin(Float($0) * 2 * .pi * 440 / 16_000) }
    }

    @Test("the registry hands out the engine graph when there is one")
    func engineGraphWins() {
        let (engine, _) = graph()
        var built = 0
        let registry = AppCaptureGraph(makeFallback: { built += 1; return self.graph().0 })
        registry.provider = { engine }
        #expect(registry.shared() === engine)
        #expect(registry.shared() === engine)
        #expect(built == 0)
    }

    @Test("without an engine graph there is exactly one fallback graph, dropped once the engine's exists")
    func oneFallback() {
        var built = 0
        let registry = AppCaptureGraph(makeFallback: { built += 1; return self.graph().0 })
        let a = registry.shared()
        let b = registry.shared()
        #expect(a === b)
        #expect(built == 1)
        #expect(registry.isFallback(a))
        let (engine, _) = graph()
        registry.provider = { engine }
        #expect(registry.shared() === engine)
        #expect(!registry.isFallback(a))
    }

    @Test("a voice test during a meeting joins the running graph: one HAL open, both hear the audio")
    func voiceTestJoinsRecorder() async throws {
        let (engine, source) = graph()
        let registry = AppCaptureGraph(makeFallback: { Issue.record("no fallback expected"); return engine })
        registry.provider = { engine }
        let meeting = try engine.attachRecorder(.meeting)
        #expect(source.starts == 1)

        let test = LiveVoiceTestCapture(registry: registry)
        let events = test.open()
        await eventually { engine.currentOwner == .meter }
        #expect(engine.currentOwner == .meter)
        #expect(source.starts == 1)   // joined, not reopened

        let heard = SharedCaptureGraphTests.Samples()
        let reader = Task {
            var started = false
            for await e in events {
                if case .started = e { started = true }
                if case .audio(let s, _) = e { heard.append(s) }
            }
            return started
        }
        let meetingHeard = SharedCaptureGraphTests.Samples()
        let meetingReader = Task {
            for await e in meeting.events { if case .audio(let s, _) = e { meetingHeard.append(s) } }
        }
        source.push(tone())
        await eventually { heard.count >= 1_600 && meetingHeard.count >= 1_600 }
        #expect(heard.count >= 1_600)
        #expect(meetingHeard.count >= 1_600)

        // Stop testing ends the meter's claim; the meeting keeps the graph (no HAL stop).
        test.release()
        #expect(engine.currentOwner == nil)
        #expect(source.stops == 0)
        #expect(await reader.value)   // a joined test still reports `.started`
        engine.detachRecorder(meeting)
        meetingReader.cancel()
    }

    @Test("alone, the voice test opens the shared graph and Stop closes it")
    func voiceTestAlone() async {
        let (engine, source) = graph()
        let registry = AppCaptureGraph()
        registry.provider = { engine }
        let test = LiveVoiceTestCapture(registry: registry)
        _ = test.open()
        await eventually { engine.currentOwner == .meter }
        #expect(source.starts == 1)
        test.release()
        await eventually { source.stops >= 1 }
        #expect(source.stops >= 1)
        #expect(!engine.isCapturing)
    }

    @Test("the onboarding meter reads its own subscription and ends it at stop")
    func onboardingMeterSubscription() async {
        let (engine, _) = graph()
        let before = engine.pipeline.subscriberCount
        let meter = PipelineMicLevelPublisher(audio: engine)
        meter.startMonitoring()
        await eventually { engine.currentOwner == .meter }
        #expect(engine.pipeline.subscriberCount > before)
        meter.stopMonitoring()
        await eventually { engine.pipeline.subscriberCount == before }
        #expect(engine.pipeline.subscriberCount == before)
    }
}
