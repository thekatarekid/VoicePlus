import Combine
import Engine
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// Regression cover for the 1.7.3 "VoicePlus is already recording." wedge.
///
/// Three reports, one bug. Onboarding's "Dictate now" worked once and then refused forever; the real
/// hotkey showed an error on key *release*; after a handful of presses the hotkey produced no
/// listening state at all, only a flash of the notch on release. All three are a recording session
/// that was never released:
///
/// 1. `RealEngine.start(prewarm:)` set `listening = true` before opening capture and did not roll it
///    back when `audio.start()` threw. The flag then outlived the session it described, and every
///    later start threw `alreadyListening` for the rest of the process.
/// 2. `DictationCoordinator` ran start / finalize / cancel as three independent `Task`s, so a key
///    released during warm-up ran `stop()` *before* its own `start()` finished: the stop threw
///    `notListening` and was swallowed, the start then succeeded, and the engine was left recording
///    with nobody left to stop it.
///
/// What is locked in here: one owner of session state, teardown on every exit path, and a wedge that
/// clears itself rather than requiring a relaunch.
@Suite("A dictation session is always released")
struct DictationSessionLifecycleTests {

    // MARK: A scriptable engine

    /// Counts what the coordinator actually asked the engine to do, and can be made to fail the way
    /// a real microphone fails.
    final class ScriptedEngine: EngineProtocol, @unchecked Sendable {
        enum Failure: Equatable { case none, startThrows(EngineError), stopThrows(EngineError) }

        private let lock = NSLock()
        private let subject = CurrentValueSubject<EngineState, Never>(.idle)
        private let broadcaster = EngineEventBroadcaster()

        /// The flag the bug was about: set by a successful `start()`, cleared by `stop()`/`cancel()`.
        private(set) var listening = false
        private(set) var starts = 0
        private(set) var stops = 0
        private(set) var cancels = 0
        var failure: Failure = .none
        /// How long `start()` spends "warming up", so a release can be made to race it.
        var startDelayMs: UInt64 = 0
        var spans: [TranscriptSpan] = [TranscriptSpan(text: "hello", confidence: 0.9, audioRange: 0...1, provenance: [.asr])]

        var state: EngineState { subject.value }
        var statePublisher: AnyPublisher<EngineState, Never> { subject.eraseToAnyPublisher() }
        func events() -> AsyncStream<EngineEvent> { broadcaster.subscribe() }
        func prewarm() async throws {}

        func start(prewarm: Bool) async throws {
            lock.withLock { starts += 1 }
            if lock.withLock({ listening }) { throw EngineError.alreadyListening }
            if startDelayMs > 0 { try? await Task.sleep(nanoseconds: startDelayMs * 1_000_000) }
            // Deliberately mirrors `RealEngine`: the flag goes up, and *then* capture is opened. A
            // failure after this point is exactly the leak the fix is about.
            lock.withLock { listening = true }
            if case .startThrows(let error) = failure {
                // The engine's own rollback (RealEngine does this now). The coordinator must not
                // depend on it — see `aFailedStartIsAlwaysTornDown`.
                throw error
            }
            subject.send(.listening(level: 0))
        }

        func stop() async throws -> [TranscriptSpan] {
            lock.withLock { stops += 1 }
            guard lock.withLock({ let was = listening; listening = false; return was }) else {
                throw EngineError.notListening
            }
            if case .stopThrows(let error) = failure { throw error }
            subject.send(.idle)
            return spans
        }

        func cancel() async {
            lock.withLock { cancels += 1; listening = false }
            subject.send(.idle)
        }
    }

    @MainActor private static func coordinator(_ engine: any EngineProtocol) -> DictationCoordinator {
        DictationCoordinator(engine: engine, database: nil, pill: PillPanelController())
    }

    // MARK: S2 — a second dictation after a first that completed

    @Test("a second utterance starts cleanly after the first completed")
    @MainActor func secondUtteranceAfterASuccess() async {
        let engine = ScriptedEngine()
        let coordinator = Self.coordinator(engine)

        coordinator.start()
        coordinator.finalize()
        await coordinator.settle()
        #expect(!engine.listening, "the first utterance left the engine recording")
        #expect(!coordinator.isSessionHeld)

        coordinator.start()
        await coordinator.settle()
        #expect(engine.listening, "the second press did not open a session")
        #expect(engine.starts == 2, "the second start was refused: \(engine.starts) start(s) reached the engine")
        coordinator.finalize()
        await coordinator.settle()
        #expect(!coordinator.isSessionHeld)
    }

    // MARK: S2/S5 — after a failure, a new utterance can still start

    @Test("a failed start is torn down, and the next press works")
    @MainActor func aFailedStartIsAlwaysTornDown() async {
        let engine = ScriptedEngine()
        engine.failure = .startThrows(.modelUnavailable("no mic"))
        let coordinator = Self.coordinator(engine)
        var reported: Error?
        coordinator.onStartFailure = { reported = $0 }

        coordinator.start()
        await coordinator.settle()
        #expect(reported != nil, "a start that never opened capture must be reported")
        #expect(engine.cancels == 1, "a failed start must be torn down, not left to leak")
        #expect(!engine.listening, "the engine was left recording after a failed start")
        #expect(!coordinator.isSessionHeld)

        // The release that follows the dead press must land nothing and must not throw the state
        // machine off — this is the "broken notch animation" at the end of a dead press.
        coordinator.finalize()
        await coordinator.settle()

        engine.failure = .none
        coordinator.start()
        await coordinator.settle()
        #expect(engine.listening, "dictation stayed dead after one failure")
    }

    @Test("a cancelled utterance releases the session")
    @MainActor func cancelReleasesTheSession() async {
        let engine = ScriptedEngine()
        let coordinator = Self.coordinator(engine)

        coordinator.start()
        await coordinator.settle()
        coordinator.cancel()
        await coordinator.settle()
        #expect(!engine.listening)
        #expect(!coordinator.isSessionHeld)

        coordinator.start()
        await coordinator.settle()
        #expect(engine.listening, "a cancelled utterance blocked the next one")
    }

    @Test("a stop that throws still tears the engine down")
    @MainActor func aFailedStopIsTornDown() async {
        let engine = ScriptedEngine()
        engine.failure = .stopThrows(.modelUnavailable("final"))
        let coordinator = Self.coordinator(engine)

        coordinator.start()
        coordinator.finalize()
        await coordinator.settle()
        #expect(engine.cancels == 1, "a stop that threw says nothing about whether capture is open")
        #expect(!coordinator.isSessionHeld)

        engine.failure = .none
        coordinator.start()
        await coordinator.settle()
        #expect(engine.listening, "a failed finalize wedged the next utterance")
    }

    // MARK: S4 — the key released before warm-up finished

    @Test("releasing the key during warm-up leaves nothing recording")
    @MainActor func releaseDuringWarmUpCleansUp() async {
        let engine = ScriptedEngine()
        engine.startDelayMs = 60
        let coordinator = Self.coordinator(engine)

        coordinator.start()
        // No wait: this is the tap that used to run `stop()` before its own `start()` returned.
        coordinator.finalize()
        await coordinator.settle()

        #expect(!engine.listening, "the engine kept recording after the key came back up")
        #expect(!coordinator.isSessionHeld)
        #expect(engine.stops + engine.cancels >= 1, "the session was never released")

        coordinator.start()
        await coordinator.settle()
        #expect(engine.listening, "the hotkey was dead after one early release")
    }

    /// A gate a preflight can block on until the test lets it through. Deterministic where a
    /// wall-clock bound is not: under a loaded test process the cooperative pool alone can account
    /// for seconds.
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var waiter: CheckedContinuation<Void, Never>?
        private var opened = false
        private var _passed = false
        /// Did anything actually get through? False means the preflight is still blocked.
        var passed: Bool { lock.withLock { _passed } }

        func wait() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if opened { lock.unlock(); continuation.resume() } else { waiter = continuation; lock.unlock() }
            }
            lock.withLock { _passed = true }
        }

        func open() {
            lock.lock()
            opened = true
            let waiter = self.waiter
            self.waiter = nil
            lock.unlock()
            waiter?.resume()
        }
    }

    @Test("a slow preflight cannot hold the utterance open")
    @MainActor func preflightIsBounded() async {
        let engine = ScriptedEngine()
        let coordinator = Self.coordinator(engine)
        coordinator.preflightTimeout = 0.05
        let gate = Gate()
        coordinator.preflight = { await gate.wait() }
        // Releases the preflight eventually, so a regression fails the expectation below instead of
        // hanging the suite.
        let release = Task.detached { try? await Task.sleep(nanoseconds: 3_000_000_000); gate.open() }

        coordinator.start()
        await coordinator.settle()
        #expect(engine.listening, "the utterance must start even when preflight overruns")
        #expect(!gate.passed, "capture waited for the preflight instead of starting without it")

        release.cancel()
        gate.open()
    }

    // MARK: Self-healing — the wedge clears itself

    @Test("an engine another owner left recording is reclaimed, not refused forever")
    @MainActor func aWedgedEngineIsReclaimed() async {
        let engine = ScriptedEngine()
        // Exactly the 1.7.3 state: onboarding's dictation test (or the act stack, or "train by
        // voice") started this engine and never released it.
        try? await engine.start(prewarm: true)
        #expect(engine.listening)

        let coordinator = Self.coordinator(engine)
        coordinator.start()
        await coordinator.settle()

        #expect(engine.listening, "the coordinator must recover the engine, not give up on it")
        #expect(engine.cancels >= 1, "the stale session was never torn down")
        #expect(coordinator.isSessionHeld, "the retry did not take ownership of the new session")
    }

    // MARK: Engine swap mid-utterance

    @Test("an engine swap mid-utterance leaves no session held")
    @MainActor func swapMidUtteranceReleasesTheSession() async {
        let first = ScriptedEngine()
        let swappable = SwappableEngine(first)
        let coordinator = Self.coordinator(swappable)

        coordinator.start()
        await coordinator.settle()
        #expect(coordinator.isSessionHeld)

        // The model finished downloading while the key was held.
        let second = ScriptedEngine()
        await swappable.swap(to: second)

        #expect(!first.listening, "the outgoing engine was left recording")
        #expect(!coordinator.isSessionHeld, "the claim on the outgoing engine outlived it")

        coordinator.finalize()
        await coordinator.settle()
        #expect(!second.listening)

        coordinator.start()
        await coordinator.settle()
        #expect(second.listening, "the swap wedged the next utterance")
    }

    @Test("swapping cancels an outgoing engine whose start failed part-way")
    func swapCancelsAnErroredOutgoingEngine() async {
        let first = ScriptedEngine()
        first.failure = .startThrows(.modelUnavailable("no mic"))
        let swappable = SwappableEngine(first)
        try? await swappable.start(prewarm: true)
        // `first.listening` is true with no capture behind it, and its published state is not
        // `.isActive` — which is why the swap used to skip the cancel entirely.
        #expect(first.listening)

        await swappable.swap(to: ScriptedEngine())
        #expect(!first.listening, "the swap left the outgoing engine holding the microphone")
    }
}
