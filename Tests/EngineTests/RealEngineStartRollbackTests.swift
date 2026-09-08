import Foundation
import Testing
import Shared
@testable import Engine

/// An `AudioSource` whose `start()` fails the way a real microphone fails: a denied TCC grant, a HAL
/// start timeout, a format the device would not agree to.
final class RefusingAudioSource: AudioSource, @unchecked Sendable {
    var sink: ((UnsafeBufferPointer<Float>) -> Void)?
    var failStart = true
    private(set) var starts = 0
    private(set) var stops = 0
    func prewarm() throws {}
    func start() throws {
        starts += 1
        if failStart { throw AudioCaptureError.noInputDevice }
    }
    func stop() { stops += 1 }
}

/// The root of the 1.7.3 "VoicePlus is already recording." wedge.
///
/// `RealEngine.start(prewarm:)` raises `listening` *before* opening capture, because the audio sink
/// can fire from inside `audio.start()`. When that call threw, the flag was left up with no capture
/// behind it, so every later `start()` threw `alreadyListening` — for the rest of the process. Five
/// call sites shared this engine and not one of them called `cancel()` on a failed start.
@Suite("A start that could not open capture rolls itself back")
struct RealEngineStartRollbackTests {
    private func engine(_ audio: AudioSource) -> RealEngine {
        RealEngine(audio: audio, provider: StaticRecognizerProvider(final: ScriptedFinal(spans: [])))
    }

    @Test("a failed capture start does not leave the engine recording")
    func failedCaptureStartRollsBack() async throws {
        let audio = RefusingAudioSource()
        let engine = engine(audio)

        await #expect(throws: AudioCaptureError.self) { try await engine.start(prewarm: true) }
        // The observable proof: the *next* start reaches the audio source instead of being refused.
        await #expect(throws: AudioCaptureError.self) { try await engine.start(prewarm: true) }
        #expect(audio.starts == 2, "the second start never reached capture — the engine was wedged")
    }

    @Test("dictation recovers as soon as capture works again")
    func recoversWhenCaptureWorksAgain() async throws {
        let audio = RefusingAudioSource()
        let engine = engine(audio)
        await #expect(throws: AudioCaptureError.self) { try await engine.start(prewarm: true) }

        audio.failStart = false
        try await engine.start(prewarm: true)   // threw `alreadyListening` before the fix
        #expect(engine.state.caseName == "listening")
        _ = try await engine.stop()
    }
}
