import Foundation
import Shared
import Testing
@testable import Engine

/// V5 LR3 — lips-only engine: no microphone, crops → AVSRRecognizer(videoOnly:) → same span contract.
@Suite struct LipsOnlyEngineTests {
    final class Clock: @unchecked Sendable { var t: TimeInterval = 100 }
    final class Ended: @unchecked Sendable { var count = 0 }

    func make(face: Double, installed: Bool = true) -> (LipsOnlyEngine, AVSRRecognizerTests.MockModel, Clock, Ended) {
        let model = AVSRRecognizerTests.MockModel()
        if !installed { model.installed = [] }
        let clip = AVSRRecognizerTests.FixedClip(AVSRRecognizerTests.clip(seconds: 1.2, faceFraction: face))
        let clock = Clock(), ended = Ended()
        let engine = LipsOnlyEngine(recognizer: AVSRRecognizer(videoOnly: true, model: model, visual: clip),
                                    isModelInstalled: { [model] in model.isAvailable(.visualOnly) },
                                    clock: { clock.t }, onUtteranceEnd: { ended.count += 1 })
        return (engine, model, clock, ended)
    }

    @Test func silentDictationProducesSpans() async throws {
        let (engine, model, clock, ended) = make(face: 1)
        let events = engine.events()
        try await engine.start()
        #expect(engine.state == .listening(level: 0))
        clock.t += 1.2
        let spans = try await engine.stop()
        #expect(spans.map(\.text) == ["hello", "world"])
        #expect(spans.allSatisfy { $0.provenance == [.asr, AVSRRecognizer.lipsStage] })
        #expect(model.calls.count == 1 && model.calls[0].0 == .visualOnly && !model.calls[0].hasAudio,
                "the audio never reaches the model: the mic is muted")
        #expect(ended.count == 1, "crops cleared after the utterance")
        var sawFinal = false
        for await e in events { if case .final(let f) = e { sawFinal = f == spans; break } }
        #expect(sawFinal)
    }

    @Test func noFaceIsAnHonestErrorNotText() async throws {
        let (engine, _, clock, ended) = make(face: 0.2)
        try await engine.start()
        clock.t += 1
        #expect(try await engine.stop().isEmpty)
        #expect(engine.state == .error(LipsOnlyEngine.noFaceMessage))
        #expect(ended.count == 1)
    }

    @Test func modelMissingIsUnavailable() async {
        let (engine, _, _, _) = make(face: 1, installed: false)
        await #expect(throws: EngineError.modelUnavailable(LipsOnlyEngine.notInstalledMessage)) { try await engine.start() }
        #expect(engine.state == .unavailable(LipsOnlyEngine.notInstalledMessage))
    }

    @Test func stopWithoutStartAndCancel() async throws {
        let (engine, _, _, ended) = make(face: 1)
        await #expect(throws: EngineError.notListening) { _ = try await engine.stop() }
        try await engine.start()
        await #expect(throws: EngineError.alreadyListening) { try await engine.start(prewarm: false) }
        await engine.cancel()
        #expect(engine.state == .idle && ended.count == 1)
    }
}
