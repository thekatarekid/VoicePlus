import Combine
import Engine
import Foundation
import Injection
import Pipeline
import Shared
import Testing
@testable import VoicePlusApp

/// Regression cover for the fabricated-transcript bug.
///
/// `EngineFactory.make()` used to fall back to `MockEngine(fixture: "email_reply")` whenever no ASR
/// model was on disk and Apple Speech was unavailable — i.e. on every fresh install, during
/// onboarding. The mock replayed its fixture on a timer with no microphone input, the pill showed
/// it as a preview, and on hotkey release `UtteranceLander` **typed it into the user's frontmost
/// app**: "Hi Priya, thanks for the update. Let's sync with TeamViewer tomorrow."
///
/// The rule these tests lock in: the mock engine is reachable only by explicit developer opt-in.
@Suite("No recognizer → an honestly-unavailable engine, never the mock")
struct UnavailableEngineTests {
    /// Text from `Fixtures/transcripts/email_reply.json`. If any of it can reach a transcript or an
    /// injector without an env opt-in, the bug is back.
    static let fabricated = "TeamViewer"

    // MARK: The engine itself emits nothing

    @Test("start/stop produce no spans and no transcript events")
    func unavailableEngineIsSilent() async throws {
        let engine = UnavailableEngine(lingerMs: 0)
        let events = engine.events()
        // The publisher can deliver on another thread, so the states are collected under a lock
        // (an unguarded array crashed a full --no-parallel run in Array._checkSubscript).
        let box = SeenStates()
        let states = engine.statePublisher.sink { box.append($0) }
        defer { states.cancel() }

        try await engine.prewarm()
        try await engine.start(prewarm: true)
        // Long enough that any fixture-style timer would have fired several spans.
        try? await Task.sleep(nanoseconds: 250_000_000)
        let spans = try await engine.stop()
        let seen = box.snapshot

        #expect(spans.isEmpty, "an unavailable engine must never produce transcript spans")
        #expect(seen.contains(.unavailable(engine.reason)))
        #expect(!seen.contains { $0.caseName == "previewing" }, "no fabricated preview text")
        #expect(!seen.contains { $0.caseName == "listening" }, "it is not listening to anything")

        // Nothing on the event channel but state changes: no `.partial`, no `.final`.
        var transcriptEvents = 0
        let drain = Task {
            for await event in events {
                switch event {
                case .partial, .final: transcriptEvents += 1
                case .state, .micQuality: break
                }
            }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        drain.cancel()
        #expect(transcriptEvents == 0)
    }

    @Test("cancel returns to idle without emitting anything")
    func cancelIsClean() async throws {
        let engine = UnavailableEngine(lingerMs: 0)
        try await engine.start(prewarm: true)
        await engine.cancel()
        #expect(engine.state == .idle)
    }

    // MARK: Nothing reaches the injector

    @Test("an unavailable engine's output never reaches the injector")
    func nothingIsInjected() async throws {
        let system = MockSystemAccess()
        let injector = TextInjector(system: system)
        let lander = UtteranceLander(pipeline: PipelineRunner.standard(), injector: injector, system: system,
                                     repair: nil, flags: .inMemory(), database: nil)

        let built = EngineFactory.makeUnavailable()
        try await built.engine.start(prewarm: true)
        try? await Task.sleep(nanoseconds: 200_000_000)
        let spans = try await built.engine.stop()

        let result = await lander.land(spans, startedAt: Date(), focus: system.frontmost)
        #expect(spans.isEmpty)
        #expect(result.text.isEmpty)
        #expect(result.injection == nil, "no injection may be attempted with no recognizer")
        #expect(system.field.value.isEmpty, "nothing may be typed into the frontmost app")
        #expect(!system.field.value.contains(Self.fabricated))
    }

    // MARK: The factory

    @Test("no env opt-in means no mock engine")
    func factoryDoesNotOptIntoTheMock() {
        #expect(EngineFactory.mockFixtureName(environment: [:]) == nil)
        #expect(EngineFactory.mockFixtureName(environment: ["VOICEPLUS_ENGINE": "real"]) == nil)
        #expect(EngineFactory.mockFixtureName(environment: ["VOICEPLUS_FIXTURE": ""]) == nil)

        let built = EngineFactory.makeUnavailable()
        #expect(built.engine is UnavailableEngine)
        #expect(built.kind == .unavailable(reason: EngineFactory.noRecognizerReason))
    }

    @Test("VOICEPLUS_ENGINE=mock still selects the mock engine")
    func explicitOptInStillWorks() async {
        #expect(EngineFactory.mockFixtureName(environment: ["VOICEPLUS_ENGINE": "mock"]) == "email_reply")
        #expect(EngineFactory.mockFixtureName(environment: ["VOICEPLUS_FIXTURE": "code_comment"]) == "code_comment")

        let built = await EngineFactory.make(environment: ["VOICEPLUS_ENGINE": "mock"])
        #expect(built.kind == .mock(fixture: "email_reply"))
        #expect(built.engine is MockEngine)
    }

    // MARK: The pill says so, honestly

    @Test("the pill gets its own state, never fake preview text")
    func pillShowsAnHonestNotice() {
        var reducer = PillStateReducer()
        let state = reducer.reduce(.unavailable("No speech model installed"))
        #expect(state == .unavailable(reason: "No speech model installed"))
        #expect(state.caseName == "unavailable")
        if case .preview = state { Issue.record("the notice must not be dressed up as transcript text") }
    }
}

/// Lock-guarded state log for `unavailableEngineIsSilent`.
private final class SeenStates: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [EngineState] = []
    func append(_ s: EngineState) { lock.lock(); states.append(s); lock.unlock() }
    var snapshot: [EngineState] { lock.lock(); defer { lock.unlock() }; return states }
}
