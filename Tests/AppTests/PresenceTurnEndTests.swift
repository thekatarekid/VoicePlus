import Combine
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// FX2 — the presence chin stuck on "VoicePlus · Working…" after fn release (1.11.0 / 1.11.1).
///
/// The chin used to take its engine states from the pill, and since S3 the pill only gets what the
/// turn controller admits: after key-up it holds back `.finalizing`, `.landed` and `.idle`. So for a
/// hold turn with speech the last state the chin heard was `.previewing`, which it reduces to
/// "Working…" — and there it sat, once the pill had gone, until the next press. Nothing tested a
/// real turn end to end: the reducer tests were table tests, the controller tests never looked at
/// the chin.
///
/// These run the whole hold turn — key down, speech, key up, final pass, preview, write — through
/// `DictationCoordinator` + `TurnController` (the S3 harness: production lander and injector on
/// `MockSystemAccess`) with an engine that publishes exactly what `RealEngine` publishes, and read
/// the chin through the same `PresenceIndicatorController.bind` the app uses. No panel is ordered in.
@Suite("Presence chin comes back to rest when a turn ends (FX2)")
struct PresenceTurnEndTests {

    // MARK: - An engine shaped like RealEngine

    /// `RealEngine`'s state sequence: `.listening(level:)` while capturing, `.previewing` once words
    /// arrive (and no more level states after that), then on `stop()` `.finalizing` → `.landed` →
    /// `.idle` (or `.error` and a throw); `cancel()` ends on `.idle`.
    final class TurnShapedEngine: EngineProtocol, @unchecked Sendable {
        enum Ending { case speech, silence, failure, neverAtRest }

        private let lock = NSLock()
        private let subject = CurrentValueSubject<EngineState, Never>(.idle)
        private let broadcaster = EngineEventBroadcaster()
        private var capturing = false
        var ending: Ending = .speech
        var words = "hello there"

        var state: EngineState { subject.value }
        var statePublisher: AnyPublisher<EngineState, Never> { subject.eraseToAnyPublisher() }
        func events() -> AsyncStream<EngineEvent> { broadcaster.subscribe() }
        func prewarm() async throws {}

        func start(prewarm: Bool) async throws {
            guard lock.withLock({ () -> Bool in defer { capturing = true }; return !capturing }) else {
                throw EngineError.alreadyListening
            }
            subject.send(.listening(level: 0))
        }

        func level(_ level: Float) { subject.send(.listening(level: level)) }
        func say(_ text: String) { subject.send(.previewing(text: text)) }

        func stop() async throws -> [TranscriptSpan] {
            guard lock.withLock({ () -> Bool in defer { capturing = false }; return capturing }) else {
                throw EngineError.notListening
            }
            subject.send(.finalizing)
            switch ending {
            case .speech:
                subject.send(.landed)
                subject.send(.idle)
                return TurnControllerTests.words(words)
            case .silence:
                subject.send(.landed)
                subject.send(.idle)
                return []
            case .failure:
                subject.send(.error("final pass failed"))
                throw EngineError.modelUnavailable("final")
            case .neverAtRest:
                // An engine that never says it is done: only the turn's end can bring the chin back.
                return TurnControllerTests.words(words)
            }
        }

        func cancel() async {
            lock.withLock { capturing = false }
            subject.send(.idle)
        }
    }

    // MARK: - Rig

    final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [EngineState] = []
        func append(_ state: EngineState) { lock.withLock { items.append(state) } }
        var names: [String] { lock.withLock { items.map(\.caseName) } }
    }

    @MainActor
    final class Rig {
        let h = TurnControllerTests.Harness()
        let engine = TurnShapedEngine()
        let coordinator: DictationCoordinator
        let presence = PresenceIndicatorController()
        /// What the pill was fed (the turn controller's admitted stream).
        let pillSaw = Seen()
        /// What the engine actually published.
        let engineSaid = Seen()
        private var bag = Set<AnyCancellable>()

        var pill: PillViewModel { coordinator.pill.model }
        var chin: PresenceState { presence.reducedState }

        init() {
            coordinator = DictationCoordinator(engine: engine, database: nil, pill: PillPanelController())
            coordinator.turns = h.controller
            let model = coordinator.pill.model
            // The app's `TurnWiring` draws the turn's own rows on the pill; the harness's `ui` runs
            // them wherever the controller is, so hop to main the way the app's `ui` does.
            let shown = h.controller.onPresent
            h.controller.onPresent = { state in
                shown?(state)
                DispatchQueue.main.async { model.present(state) }
            }
            presence.bind(pill: model, engineStates: coordinator.engineStates,
                          turnEnded: coordinator.turnEnded, mute: nil)
            model.onEngineState = { [pillSaw] in pillSaw.append($0) }
            coordinator.engineStates.sink { [engineSaid] in engineSaid.append($0) }.store(in: &bag)
        }

        /// Lets every `receive(on: .main)` hop queued so far run (the pill's visibility is two hops).
        func drain() async {
            for _ in 0..<6 {
                await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                    DispatchQueue.main.async { done.resume() }
                }
            }
        }

        /// Key down, capture open, a level tick and (optionally) words.
        func pressAndSpeak(_ words: String?) async throws -> TurnID {
            coordinator.start()
            await coordinator.settle()
            let id = try #require(coordinator.currentTurn, "key down began a turn")
            #expect(h.controller.stage(of: id) == .listening)
            engine.level(0.4)
            if let words { engine.say(words) }
            await drain()
            return id
        }

        func ended(_ id: TurnID) -> TurnStage? { h.events.ended.first { $0.0 == id }?.1 }

        /// The pill's clock, moved past every dwell each time the pill is taken down.
        private var skew: TimeInterval = 0

        /// The outcome row's dwell ran out — or, for a row that waits for the user (an error), the
        /// user dismissed it: the pill goes, and the chin is all that is left.
        func pillRetracts() async {
            await drain()
            skew += 3600
            let skew = self.skew
            pill.now = { Date().addingTimeInterval(skew) }
            pill.hide()
            pill.flushPillHold()
            if pill.state.isVisible { pill.dismissNotice() }
            await drain()
        }
    }

    enum Outcome: String, CaseIterable { case landed, held, failed, cancelled, silent }

    // MARK: - The turn, end to end

    @Test("a hold turn ends — landed, held, failed, cancelled or silent — and the chin is back at rest",
          arguments: Outcome.allCases)
    @MainActor func chinRestsAfterEveryTurnEnd(_ outcome: Outcome) async throws {
        let rig = Rig()
        let h = rig.h
        rig.engine.ending = outcome == .failed ? .failure : outcome == .silent ? .silence : .speech
        let id = try await rig.pressAndSpeak(outcome == .silent ? nil : "hello there")

        // While the pill shows the turn, the chin stands down — the pill says it all, louder.
        #expect(rig.presence.currentInputs.pillVisible, "the pill is up while capturing")
        #expect(rig.chin == .off)

        switch outcome {
        case .cancelled:
            rig.coordinator.cancel()
            await rig.coordinator.settle()
        case .landed, .held:
            rig.coordinator.finalize()
            await rig.coordinator.settle()
            #expect(h.controller.stage(of: id) == .finalPreview, "the payload is previewed before it is written")
            h.controller.finalRendered(id)
            if outcome == .held { h.system.frontmost = TurnControllerTests.mail }
            h.clock.advance(1.0)
        case .failed, .silent:
            rig.coordinator.finalize()
            await rig.coordinator.settle()
        }
        let expected: TurnStage = [.landed: .landed, .held: .held, .failed: .failed,
                                   .cancelled: .cancelled, .silent: .empty][outcome]!
        #expect(await h.wait { rig.ended(id) != nil }, "the turn ended")
        #expect(rig.ended(id) == expected)
        if outcome == .landed { #expect(h.system.postCount == 1, "the words were written once") }

        await rig.pillRetracts()
        #expect(!rig.presence.currentInputs.pillVisible, "the pill still shows \(rig.pill.state)")
        #expect(!PresenceStateReducer.isTurnScoped(rig.presence.currentInputs.engine),
                "the chin still holds '\(rig.presence.currentInputs.engine.caseName)' from a turn that is over")
        #expect(rig.chin == .ready, "after a \(outcome.rawValue) turn the chin must rest, not show \(rig.chin.caseName)")
    }

    @Test("the chin hears the engine's own states; the pill stays on the turn controller's admitted stream")
    @MainActor func feedsAreSeparate() async throws {
        let rig = Rig()
        let id = try await rig.pressAndSpeak("hello there")
        rig.coordinator.finalize()
        await rig.coordinator.settle()
        await rig.drain()
        // Mid-turn — the payload is still dwelling in its preview, the turn has not ended — and the
        // chin already knows the engine is at rest. Only the unfiltered feed can have told it.
        #expect(rig.h.controller.stage(of: id) == .finalPreview)
        #expect(rig.presence.currentInputs.engine == .idle,
                "the chin heard '\(rig.presence.currentInputs.engine.caseName)', not the engine's own .idle")
        rig.h.controller.finalRendered(id)
        rig.h.clock.advance(1.0)
        #expect(await rig.h.wait { rig.ended(id) == .landed })
        await rig.drain()

        let said = rig.engineSaid.names
        #expect(said.suffix(3) == ["finalizing", "landed", "idle"], "the engine said the turn was over: \(said)")
        #expect(rig.presence.currentInputs.engine == .idle, "the chin heard it")
        // The pill is not told what would contradict the turn's own Finishing… / preview rows.
        #expect(!rig.pillSaw.names.contains("finalizing"), "pill saw \(rig.pillSaw.names)")
        #expect(!rig.pillSaw.names.contains("landed"), "pill saw \(rig.pillSaw.names)")
    }

    @Test("an engine that never says it is at rest still cannot outlive the turn on the chin")
    @MainActor func turnEndIsTheBackstop() async throws {
        let rig = Rig()
        rig.engine.ending = .neverAtRest
        let id = try await rig.pressAndSpeak("hello there")
        rig.coordinator.finalize()
        await rig.coordinator.settle()
        #expect(rig.engineSaid.names.last == "finalizing")
        rig.h.controller.finalRendered(id)
        rig.h.clock.advance(1.0)
        #expect(await rig.h.wait { rig.ended(id) == .landed })
        await rig.pillRetracts()
        #expect(rig.presence.currentInputs.engine == .idle, "the turn's end reset the chin's engine phase")
        #expect(rig.chin == .ready)
    }

    @Test("two turns in a row: the second press finds the chin at rest, and ends at rest")
    @MainActor func consecutiveTurns() async throws {
        let rig = Rig()
        for words in ["first turn", "second turn"] {
            let id = try await rig.pressAndSpeak(words)
            rig.coordinator.finalize()
            await rig.coordinator.settle()
            rig.h.controller.finalRendered(id)
            rig.h.clock.advance(1.0)
            #expect(await rig.h.wait { rig.ended(id) == .landed })
            await rig.pillRetracts()
            #expect(rig.chin == .ready, "after '\(words)'")
        }
    }

    // MARK: - The chin's own guarantees

    @Test("a turn's end leaves the engine's standing conditions alone (no model, an error)")
    @MainActor func turnEndKeepsStandingConditions() async {
        let presence = PresenceIndicatorController()
        presence.setEngine(.unavailable("no model"))
        presence.noteTurnEnded(.empty)
        #expect(presence.reducedState == .blocked(.modelMissing), "no model is still no model")
        presence.setEngine(.error("invalidAudioData"))
        presence.noteTurnEnded(.failed)
        #expect(presence.currentInputs.engine == .error("invalidAudioData"))
        presence.setEngine(.previewing(text: "hi"))
        presence.noteTurnEnded(.landed)
        #expect(presence.currentInputs.engine == .idle)
    }
}

/// FX2 — the reducer half: with the microphone shut, the live-capture states cannot light the chin.
@Suite("Presence reducer: a closed microphone is never Working… (FX2)")
struct PresenceClosedMicrophoneTests {
    @Test("starting, listening and previewing with the microphone shut read as rest",
          arguments: [EngineState.starting, .listening(level: 0.6), .previewing(text: "hello there")])
    func liveCaptureStatesNeedAnOpenMicrophone(_ engine: EngineState) {
        // The exact 1.11.1 state: pill gone, microphone closed, last admitted state `.previewing`.
        #expect(PresenceStateReducer.reduce(PresenceInputs(engine: engine), microphone: .closed) == .ready)
        // The honest state under it is still chosen by the usual precedence.
        #expect(PresenceStateReducer.reduce(PresenceInputs(muted: true, engine: engine), microphone: .closed) == .muted)
        #expect(PresenceStateReducer.reduce(PresenceInputs(ambientProcessing: true, engine: engine),
                                            microphone: .closed) == .processing)
        // With the microphone really open it is listening, as before.
        #expect(PresenceStateReducer.reduce(PresenceInputs(engine: engine),
                                            microphone: MicrophoneOwnership(graphOwner: .engine)).reportsOpenMicrophone)
    }

    @Test("the final pass after the microphone closed is still honest work")
    func finalPassStillProcesses() {
        for engine: EngineState in [.finishing, .finalizing] {
            #expect(PresenceStateReducer.reduce(PresenceInputs(engine: engine), microphone: .closed) == .processing)
        }
        #expect(PresenceStateReducer.reduce(PresenceInputs(engine: .unavailable("x")), microphone: .closed)
                == .blocked(.modelMissing))
    }
}
