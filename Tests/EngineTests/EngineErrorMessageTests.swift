import Foundation
import Shared
import Testing
@testable import Engine

/// A `LocalizedError` shaped exactly like FluidAudio's `ASRError`: a Swift enum whose *case name* is
/// terse and whose `errorDescription` is the sentence a person should read.
private enum StubASRError: LocalizedError, Equatable {
    case invalidAudioData
    var errorDescription: String? { "Invalid audio data provided. Must be at least 300ms of 16kHz audio." }
}

/// A plain Swift enum with no descriptions at all — the case where bridging to `NSError` yields the
/// contentless "The operation couldn't be completed."
private enum BareError: Error { case somethingSpecific }

@Suite("Engine errors reach the user as sentences, not enum case names")
struct EngineErrorMessageTests {
    /// The 1.6.6 pill read "⚠︎ invalidAudioData" because `RealEngine` published `"\(error)"`, and
    /// interpolating a Swift enum prints the case name however good its `errorDescription` is.
    @Test func aLocalizedErrorContributesItsOwnSentence() {
        #expect(EngineMessage.describe(StubASRError.invalidAudioData)
                == "Invalid audio data provided. Must be at least 300ms of 16kHz audio.")
        #expect(!EngineMessage.describe(StubASRError.invalidAudioData).contains("invalidAudioData"))
        #expect("\(StubASRError.invalidAudioData)" == "invalidAudioData",
                "the failing interpolation this replaces")
    }

    @Test func engineErrorsGetPlainLanguageOfTheirOwn() {
        #expect(EngineMessage.describe(EngineError.modelUnavailable("tdt-v3")) == "No speech model is ready yet (tdt-v3).")
        #expect(EngineMessage.describe(EngineError.notListening) == "VoicePlus wasn't recording when it was asked to stop.")
        for error in [EngineError.notListening, .alreadyListening, .modelUnavailable("x"),
                      .fixtureNotFound("y"), .fixtureInvalid("z")] {
            let message = EngineMessage.describe(error)
            #expect(message.hasSuffix("."), "\(error) has no readable sentence")
            #expect(message.contains(" "), "\(message) is still a bare identifier")
            #expect(message != "\(error)", "\(message) is just the interpolated enum")
        }
    }

    /// A Cocoa error keeps its own localized description rather than losing it to `String(describing:)`.
    @Test func cocoaErrorsKeepTheirLocalizedDescription() {
        let url = URLError(.notConnectedToInternet)
        #expect(EngineMessage.describe(url) == url.localizedDescription)
        #expect(!EngineMessage.describe(url).isEmpty)
    }

    /// And an error with nothing to say falls back to the case name, which still beats the generic
    /// "The operation couldn't be completed" the NSError bridge would produce.
    @Test func abareErrorFallsBackToTheCaseNameNotAGenericBridgeString() {
        let described = EngineMessage.describe(BareError.somethingSpecific)
        #expect(described == "somethingSpecific")
        #expect(!described.contains("couldn't be completed"))
    }
}

@Suite("RealEngine refuses a final pass it knows will fail")
struct ShortUtteranceTests {
    /// The direct cause of `invalidAudioData`: fewer than 300 ms of audio reaching a decoder whose
    /// documented floor is 300 ms. `stop()` now returns nothing instead of surfacing the throw, so
    /// a stray tap of the key cannot paint a red error over the pill.
    @Test func belowTheFloorTheRecognizerIsNeverCalled() async throws {
        let audio = ManualAudioSource()
        let final = ScriptedFinal(spans: [TranscriptSpan(text: "should not happen", confidence: 1, audioRange: 0...1)])
        let engine = RealEngine(audio: audio, provider: StaticRecognizerProvider(final: final))
        try await engine.start(prewarm: true)
        audio.push([Float](repeating: 0.2, count: 3_200))     // 0.2 s — under the 0.3 s floor
        for _ in 0..<200 where await engine.bufferedSampleCount() < 3_200 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let spans = try await engine.stop()
        #expect(spans.isEmpty)
        #expect(final.received.isEmpty, "the decoder must not be handed audio that is too short for it")
        #expect(engine.state == .idle, "a too-short tap is normal, not an error state")
    }

    @Test func aboveTheFloorTheFinalPassRunsAsBefore() async throws {
        let audio = ManualAudioSource()
        let final = ScriptedFinal(spans: [TranscriptSpan(text: "hello", confidence: 1, audioRange: 0...1)])
        let engine = RealEngine(audio: audio, provider: StaticRecognizerProvider(final: final))
        try await engine.start(prewarm: true)
        audio.push([Float](repeating: 0.2, count: 8_000))     // 0.5 s
        for _ in 0..<200 where await engine.bufferedSampleCount() < 8_000 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let spans = try await engine.stop()
        #expect(spans.map(\.text) == ["hello"])
        #expect(final.received.count == 8_000)
    }

    /// `CapturedAudioReporting` is what lets a caller (the onboarding dictation test) say
    /// "I didn't hear anything" in its own words before finalising.
    @Test func theEngineReportsHowMuchAudioItIsHolding() async throws {
        let audio = ManualAudioSource()
        let engine = RealEngine(audio: audio, provider: StaticRecognizerProvider(final: ScriptedFinal(spans: [])))
        let reporting: CapturedAudioReporting = engine
        #expect(reporting.minimumUtteranceSeconds == 0.3)
        try await engine.start(prewarm: true)
        #expect(await reporting.capturedSeconds == 0)
        audio.push([Float](repeating: 0.1, count: 16_000))
        for _ in 0..<200 where await engine.bufferedSampleCount() < 16_000 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(await reporting.capturedSeconds == 1)
        await engine.cancel()
    }
}

@Suite("A model that lands mid-session is picked up without a relaunch")
struct RecognizerRevisionTests {
    /// `RealEngine` cached the resolved recognizer pair for the life of the process, so the Apple
    /// Speech fallback chosen at first launch stayed in place after a 900 MB download finished —
    /// exactly the "I picked Best and waited" case, and flatly against this file's own header.
    private struct CountingProvider: RecognizerProvider {
        let box: Box
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var _revision = 0
            private var _resolves = 0
            var revision: Int {
                get { lock.withLock { _revision } }
                set { lock.withLock { _revision = newValue } }
            }
            var resolves: Int { lock.withLock { _resolves } }
            func noteResolve() { lock.withLock { _resolves += 1 } }
        }
        func resolve() async throws -> (final: FinalRecognizer, preview: PreviewRecognizer?) {
            box.noteResolve()
            return (ScriptedFinal(spans: []), nil)
        }
        func revision() async -> Int { box.revision }
    }

    @Test func aChangedRevisionReResolvesTheRecognizers() async throws {
        let box = CountingProvider.Box()
        let engine = RealEngine(audio: ManualAudioSource(), provider: CountingProvider(box: box))
        try await engine.prewarm()
        try await engine.prewarm()
        #expect(box.resolves == 1, "an unchanged revision must not re-resolve on every utterance")

        box.revision = 42                                  // a download landed
        try await engine.prewarm()
        #expect(box.resolves == 2)
    }

    /// Providers that cannot get a better answer (a static pair in a test, a fixture) keep the
    /// default revision and are resolved exactly once.
    @Test func aStaticProviderIsStillResolvedOnce() async throws {
        let engine = RealEngine(audio: ManualAudioSource(),
                                provider: StaticRecognizerProvider(final: ScriptedFinal(spans: [])))
        try await engine.prewarm()
        try await engine.prewarm()
        #expect(engine.state == .idle)
    }
}
