import Foundation
import Testing
import Shared
@testable import Engine

final class ScriptedFinal: FinalRecognizer, @unchecked Sendable {
    let name = "scripted"
    var received: [Float] = []
    let spans: [TranscriptSpan]
    init(spans: [TranscriptSpan]) { self.spans = spans }
    func recognize(_ samples: [Float]) async throws -> [TranscriptSpan] { received = samples; return spans }
}

final class ScriptedPreview: PreviewRecognizer, @unchecked Sendable {
    var fed = 0
    func feed(_ samples: [Float]) async throws -> String { fed += samples.count; return "heard \(fed / 1600)" }
    func reset() async { fed = 0 }
}

@Suite("RealEngine span emission (T4/T5)")
struct ASRRealEngineTests {
    @Test func streamsPreviewThenFinalReplacesIt() async throws {
        let samples = [Float](repeating: 0.1, count: 16_000)   // 1 s
        let audio = SampleAudioSource(samples: samples, blockDuration: 0.05)
        let finalSpans = [TranscriptSpan(text: "hello", confidence: 0.9, audioRange: 0...0.4, provenance: [.asr]),
                          TranscriptSpan(text: "world", confidence: 0.4, audioRange: 0.5...0.9, provenance: [.asr])]
        let final = ScriptedFinal(spans: finalSpans)
        let preview = ScriptedPreview()
        let engine = RealEngine(audio: audio, provider: StaticRecognizerProvider(final: final, preview: preview))
        let events = engine.events()
        var states: [String] = []
        var partials: [[TranscriptSpan]] = []
        var finals: [[TranscriptSpan]] = []
        let collector = Task {
            for await e in events {
                switch e {
                case .state(let s): states.append(s.caseName)
                case .partial(let p): partials.append(p)
                case .final(let f): finals.append(f)
                case .micQuality: break
                }
            }
        }

        try await engine.start(prewarm: true)
        #expect(engine.state.caseName == "listening")
        await #expect(throws: EngineError.alreadyListening) { try await engine.start(prewarm: false) }
        // Wait for the fixture source to deliver everything.
        for _ in 0..<100 where await engine.bufferedSampleCount() < samples.count { try await Task.sleep(nanoseconds: 10_000_000) }
        let result = try await engine.stop()
        try await Task.sleep(nanoseconds: 20_000_000)
        collector.cancel()

        #expect(result == finalSpans)
        #expect(finals == [finalSpans])
        #expect(final.received.count == samples.count)
        #expect(!partials.isEmpty)
        #expect(partials.allSatisfy { $0.allSatisfy { $0.provenance == [.asr] } })
        #expect(states.first == "prewarming")
        #expect(states.contains("previewing") && states.contains("finalizing") && states.contains("landed"))
        #expect(states.last == "idle")
        await #expect(throws: EngineError.notListening) { _ = try await engine.stop() }
    }

    @Test func cancelProducesNothingAndResets() async throws {
        let audio = SampleAudioSource(samples: [Float](repeating: 0, count: 8000))
        let final = ScriptedFinal(spans: [])
        let engine = RealEngine(audio: audio, provider: StaticRecognizerProvider(final: final))
        try await engine.start()
        await engine.cancel()
        #expect(engine.state == .idle)
        #expect(final.received.isEmpty)
        try await engine.start()   // can start again after cancel
        _ = try await engine.stop()
    }

    @Test func providerFailureSurfacesAsError() async throws {
        struct Failing: RecognizerProvider {
            func resolve() async throws -> (final: FinalRecognizer, preview: PreviewRecognizer?) { throw EngineError.modelUnavailable("none") }
        }
        let engine = RealEngine(audio: SampleAudioSource(samples: []), provider: Failing())
        await #expect(throws: EngineError.modelUnavailable("none")) { try await engine.prewarm() }
        #expect(engine.state.caseName == "error")
    }

    @Test func pollingPreviewRunsFinalRecognizerPeriodically() async throws {
        let final = ScriptedFinal(spans: [TranscriptSpan(text: "x", confidence: 1, audioRange: 0...1)])
        let p = PollingPreviewRecognizer(recognizer: final, interval: 0.5)
        #expect(try await p.feed([Float](repeating: 0, count: 4000)) == "")
        #expect(try await p.feed([Float](repeating: 0, count: 4000)) == "x")
        #expect(final.received.count == 8000)
    }

    @Test func fixtureWavLoadsAs16k() throws {
        guard let fixtures = AppPaths.fixturesDirectory() else { return }
        let url = fixtures.appendingPathComponent("audio/clean/clean_01_samantha.wav")
        let s = try SampleAudioSource.load16k(url: url)
        #expect(s.count > 16_000 && s.count < 16_000 * 15)
        #expect(s.map { abs($0) }.max()! > 0.05)
    }
}
