import Combine
import Engine
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// R3 — every row of V3 §8, plus the regression that made the whole item necessary.
///
/// | Mode / event | Covered by |
/// |---|---|
/// | Hold | `holdFinalizesAndNeverLatches`, `holdDoesNotDeliverTheKeyReleaseSegmentTwice` |
/// | Latch | `latchSurvivesEveryFinalizeAndDeliversSegmentsInOrder`, `singleTapStopsAndFinalizes` |
/// | Focus change while latched | `focusChangeWhileLatchedHoldsAndNamesTheTarget`, `resumptionRequiresANamedTarget` |
/// | Speaker mismatch / uncertain, filtering on | `speakerMismatchSuppressesInsertion`, `uncertainSpeakerSuppressesInsertion` |
/// | Ambient enabled | `ambientSpeechOnlyEverReachesTheTranscript` |
/// | Lock / sleep | `lockStopsCaptureAndNeverResumes`, `sleepStopsCaptureAndNeverResumes` |
/// | Hard mute | `hardMuteStopsCaptureCancelsPendingAndRefusesToStart` |
///
/// Everything here runs against protocols and a scripted engine: this machine has no microphone,
/// no window server and no TCC grants, so "did the text really appear in Mail" is an owner check.
/// What is locked in is the *decision* each row makes.
@Suite("Latch, mute and the session coordinator")
struct LatchBehaviourTests {

    // MARK: A scripted engine with R2.2's segment surface

    /// `EngineProtocol` plus `SegmentSessionEngine`, so the latch can be driven one endpoint at a
    /// time. Mirrors `RealEngine`'s contract in the two ways that matter: a closure while capture
    /// continues is `.committed`/`.endpoint`, and the segment that ends the session is
    /// `.final`/`.keyRelease` and is returned from `stop()` rather than delivered twice.
    final class SegmentedEngine: EngineProtocol, SegmentSessionEngine, @unchecked Sendable {
        private let lock = NSLock()
        private let subject = CurrentValueSubject<EngineState, Never>(.idle)
        private let broadcaster = EngineEventBroadcaster()
        private let segments = SegmentEventBroadcaster()
        let sessionID = UUID()

        private(set) var listening = false
        private(set) var starts = 0
        private(set) var stops = 0
        private(set) var cancels = 0
        private var index = 0
        /// Text the next closure commits.
        var segmentText = "one"
        var finalText = "the last one"

        var state: EngineState { subject.value }
        var statePublisher: AnyPublisher<EngineState, Never> { subject.eraseToAnyPublisher() }
        func events() -> AsyncStream<EngineEvent> { broadcaster.subscribe() }
        func segmentEvents() -> AsyncStream<SegmentEvent> { segments.subscribe() }
        func prewarm() async throws {}

        func start(prewarm: Bool) async throws {
            lock.withLock { starts += 1 }
            if lock.withLock({ listening }) { throw EngineError.alreadyListening }
            lock.withLock { listening = true; index = 0 }
            segments.send(.opened(SegmentID(sessionID: sessionID, index: 0)))
            subject.send(.listening(level: 0))
        }

        func stop() async throws -> [TranscriptSpan] {
            lock.withLock { stops += 1 }
            guard lock.withLock({ let was = listening; listening = false; return was }) else {
                throw EngineError.notListening
            }
            let id = lock.withLock { SegmentID(sessionID: sessionID, index: index) }
            let spans = [Self.span(finalText, stability: .final)]
            // The session-ending segment. R2.2 emits this too; the latch must ignore it, because
            // `DictationCoordinator.finalize()` is what lands it.
            segments.send(.closed(segment: id, spans: spans, stability: .final, reason: .keyRelease))
            subject.send(.idle)
            return spans
        }

        func cancel() async {
            lock.withLock { cancels += 1; listening = false }
            subject.send(.idle)
        }

        @discardableResult
        func closeSegmentAtEndpoint() async -> SegmentID? {
            guard lock.withLock({ listening }) else { return nil }
            let (closed, opened, text) = lock.withLock { () -> (SegmentID, SegmentID, String) in
                let closed = SegmentID(sessionID: sessionID, index: index)
                index += 1
                return (closed, SegmentID(sessionID: sessionID, index: index), segmentText)
            }
            segments.send(.closed(segment: closed, spans: [Self.span(text, stability: .committed)],
                                  stability: .committed, reason: .endpoint))
            segments.send(.opened(opened))
            return closed
        }

        static func span(_ text: String, stability: Stability) -> TranscriptSpan {
            TranscriptSpan(text: text, confidence: 0.9, audioRange: 0...1, provenance: [.asr], stability: stability)
        }
    }

    // MARK: A delivery spy

    /// Stands in for `LanderLatchDelivery` (pipeline → injector → `FocusGuard`'s held queue).
    final class SpyDelivery: LatchDelivering, @unchecked Sendable {
        private let lock = NSLock()
        private var _inserted: [String] = []
        private var _held: [(text: String, reason: String)] = []
        private var _entered = 0
        var destination = "Notes"
        var deliverSucceeds = true
        /// Closed → `deliver` suspends, so a test can cancel work that is genuinely pending.
        private var gateOpen = true
        private var waiters: [CheckedContinuation<Void, Never>] = []

        var inserted: [String] { lock.withLock { _inserted } }
        var held: [(text: String, reason: String)] { lock.withLock { _held } }
        var enteredDeliver: Int { lock.withLock { _entered } }

        func closeGate() { lock.withLock { gateOpen = false } }
        func openGate() {
            let pending: [CheckedContinuation<Void, Never>] = lock.withLock {
                gateOpen = true
                let w = waiters
                waiters = []
                return w
            }
            pending.forEach { $0.resume() }
        }

        func deliver(_ spans: [TranscriptSpan], segment: SegmentID) async -> Bool {
            lock.withLock { _entered += 1 }
            if !lock.withLock({ gateOpen }) {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    lock.withLock { waiters.append(c) }
                }
            }
            guard deliverSucceeds else { return false }
            lock.withLock { _inserted.append(spans.joinedText) }
            return true
        }

        func hold(_ spans: [TranscriptSpan], segment: SegmentID, reason: String) -> String {
            lock.withLock { _held.append((spans.joinedText, reason)) }
            return destination
        }

        func insertHeld(into target: String) -> Int {
            let items: [(text: String, reason: String)] = lock.withLock {
                let all = _held
                _held = []
                return all
            }
            lock.withLock { _inserted.append(contentsOf: items.map(\.text)) }
            return items.count
        }
    }

    // MARK: Fixtures

    @MainActor
    struct Rig {
        let engine: SegmentedEngine
        let dictation: DictationCoordinator
        let latch: LatchRuntime
        let spy: SpyDelivery
        let mute: MuteController
        let store: InMemoryMuteStore
        let session: SessionCoordinator

        init(muted: Bool = false) {
            engine = SegmentedEngine()
            dictation = DictationCoordinator(engine: engine, database: nil, pill: PillPanelController())
            spy = SpyDelivery()
            latch = LatchRuntime(delivery: spy)
            store = InMemoryMuteStore(muted: muted)
            mute = MuteController(store: store)
            session = SessionCoordinator(dictation: dictation, mute: mute, latch: latch)
            latch.attach(segments: engine)
        }

        /// The double-tap, through the real gesture recogniser.
        func doubleTap(_ machine: inout HotkeyStateMachine) {
            for action in machine.keyDown(at: 0) { session.handle(action) }
            for action in machine.keyUp(at: 0.05) { session.handle(action) }
            for action in machine.keyDown(at: 0.2) { session.handle(action) }
            for action in machine.keyUp(at: 0.25) { session.handle(action) }
        }

        func settle() async {
            await dictation.settle()
            await latch.settle()
        }

        /// Segment events cross a task boundary, so "did the latch see it yet" is a wait, not an
        /// assumption. Bounded so a failure is a failed expectation and not a hung suite.
        func wait(outcomes count: Int) async {
            var spins = 0
            while latch.outcomes.count < count, spins < 200_000 {
                await Task.yield()
                spins += 1
            }
            await settle()
        }

        /// Waits until `count` deliveries have *started* — used with a closed gate, where the
        /// outcome cannot arrive until the test opens it.
        func wait(entered count: Int) async {
            var spins = 0
            while spy.enteredDeliver < count, spins < 200_000 {
                await Task.yield()
                spins += 1
            }
        }
    }

    // MARK: §8 — Hold

    @Test("Hold: capture only while the key is down, and the release finalizes")
    @MainActor func holdFinalizesAndNeverLatches() async {
        let rig = Rig()
        var machine = HotkeyStateMachine()
        for action in machine.keyDown(at: 0) { rig.session.handle(action) }
        await rig.settle()
        #expect(rig.engine.listening)
        #expect(rig.session.mode == .hold)
        #expect(!rig.dictation.latched)

        for action in machine.keyUp(at: 0.4) { rig.session.handle(action) }
        await rig.settle()
        #expect(!rig.engine.listening)
        #expect(rig.engine.stops == 1)
        #expect(rig.session.mode == .idle)
        #expect(!rig.dictation.latched, "a hold must never leave the app latched")
    }

    @Test("Hold: the segment that ended the session is landed once, not twice")
    @MainActor func holdDoesNotDeliverTheKeyReleaseSegmentTwice() async {
        let rig = Rig()
        rig.session.start(.hotkey)
        await rig.settle()
        rig.session.stop()
        await rig.settle()
        // `.closed(reason: .keyRelease)` reached the runtime; it must not have delivered it —
        // `DictationCoordinator.finalize()` lands that one through the lander.
        #expect(rig.spy.inserted.isEmpty, "the key-release segment was delivered twice: \(rig.spy.inserted)")
        #expect(rig.latch.outcomes.isEmpty)
    }

    // MARK: §8 — Latch. This is the V3 §2.3 regression.

    @Test("Latch: endpoints close segments, listening continues, and the mode survives every finalize")
    @MainActor func latchSurvivesEveryFinalizeAndDeliversSegmentsInOrder() async {
        let rig = Rig()
        var machine = HotkeyStateMachine()
        rig.doubleTap(&machine)
        await rig.settle()
        #expect(rig.dictation.latched)
        #expect(rig.session.mode == .latched)
        #expect(machine.phase == .latched)

        // The line `finalize()` used to open with — `handsFree = false` — is what made latch
        // impossible: one finalize anywhere dropped the mode. Prove it cannot happen again.
        rig.dictation.finalize()
        await rig.settle()
        #expect(rig.dictation.latched, "a finalize cleared the latch — this is the V3 §2.3 bug")

        rig.session.start(.hotkey, mode: .latched)
        await rig.settle()
        #expect(rig.engine.listening)
        let stopsBefore = rig.engine.stops

        rig.engine.segmentText = "first sentence"
        await rig.engine.closeSegmentAtEndpoint()
        await rig.wait(outcomes: 1)
        rig.engine.segmentText = "second sentence"
        await rig.engine.closeSegmentAtEndpoint()
        await rig.wait(outcomes: 2)

        #expect(rig.spy.inserted == ["first sentence", "second sentence"], "\(rig.spy.inserted)")
        #expect(rig.engine.listening, "an endpoint must not end capture while latched")
        #expect(rig.engine.stops == stopsBefore, "an endpoint ended the session")
        #expect(rig.dictation.latched)
    }

    @Test("Latch: a single tap stops and finalizes")
    @MainActor func singleTapStopsAndFinalizes() async {
        let rig = Rig()
        var machine = HotkeyStateMachine()
        rig.doubleTap(&machine)
        rig.session.start(.hotkey, mode: .latched)
        await rig.settle()

        // One tap: key-down while latched is the stop (and the key-up after it emits nothing).
        let actions = machine.keyDown(at: 1.0)
        #expect(actions == [.finalize])
        for action in actions { rig.session.handle(action) }
        await rig.settle()
        #expect(!rig.dictation.latched)
        #expect(rig.session.mode == .idle)
        #expect(rig.engine.stops == 1)
        #expect(!rig.engine.listening)
    }

    @Test("Latch: the endpointer asks R2.2 to close a segment, it never segments audio itself")
    @MainActor func trailingSilenceClosesASegmentThroughR22() async {
        let rig = Rig()
        rig.dictation.handle(.enterLatch)
        rig.session.start(.hotkey, mode: .latched)
        await rig.settle()
        rig.latch.sessionStarted(at: 0)

        rig.latch.noteVAD(.speechStart(at: 0.2))
        rig.latch.noteVAD(.speechEnd(at: 1.0))
        rig.latch.tick(at: 1.5)                   // inside the trailing silence
        #expect(rig.latch.endpointClosures == 0)
        rig.latch.tick(at: 2.4)                   // past it
        #expect(rig.latch.endpointClosures == 1)
        await rig.wait(outcomes: 1)
        #expect(rig.engine.listening, "closing a segment at an endpoint must leave capture open")
        #expect(rig.spy.inserted.count == 1)
    }

    // MARK: §8 — Focus change while latched

    @Test("Focus change while latched: delivery pauses, text is held, and the target is named")
    @MainActor func focusChangeWhileLatchedHoldsAndNamesTheTarget() async {
        let rig = Rig()
        rig.spy.destination = "Notes"
        rig.dictation.handle(.enterLatch)
        rig.session.start(.hotkey, mode: .latched)
        await rig.settle()

        rig.engine.segmentText = "before the switch"
        await rig.engine.closeSegmentAtEndpoint()
        await rig.wait(outcomes: 1)
        #expect(rig.spy.inserted == ["before the switch"])

        rig.session.focusChanged(to: "Mail")
        #expect(rig.latch.deliveryPaused)

        rig.engine.segmentText = "after the switch"
        await rig.engine.closeSegmentAtEndpoint()
        await rig.wait(outcomes: 2)
        #expect(rig.spy.inserted == ["before the switch"], "text was typed into a window the user had left")
        #expect(rig.spy.held.map(\.text) == ["after the switch"])
        #expect(rig.spy.held.first?.reason == LatchReason.awaitingNamedDestination)
        // The held row names where it was going, which is what the user has to name to resume.
        #expect(rig.latch.outcomes.last?.outcome == .held(destination: "Notes",
                                                          reason: LatchReason.awaitingNamedDestination))
        #expect(rig.engine.listening, "a focus change pauses delivery, it does not stop listening")
    }

    @Test("Resumption requires an explicit, named target")
    @MainActor func resumptionRequiresANamedTarget() async {
        let rig = Rig()
        rig.dictation.handle(.enterLatch)
        rig.session.start(.hotkey, mode: .latched)
        await rig.settle()
        rig.session.focusChanged(to: "Mail")
        rig.engine.segmentText = "held words"
        await rig.engine.closeSegmentAtEndpoint()
        await rig.wait(outcomes: 1)

        #expect(rig.session.resumeDelivery(into: "   ") == 0, "an unnamed target resumed delivery")
        #expect(rig.latch.deliveryPaused, "delivery resumed without a named target")
        #expect(rig.spy.inserted.isEmpty)

        #expect(rig.session.resumeDelivery(into: "Mail") == 1)
        #expect(!rig.latch.deliveryPaused)
        #expect(rig.spy.inserted == ["held words"])
    }

    // MARK: §4.3 — Escape

    @Test("Escape cancels pending work and keeps every character already inserted")
    @MainActor func escapeCancelsPendingAndKeepsInsertedText() async {
        let rig = Rig()
        rig.dictation.handle(.enterLatch)
        rig.session.start(.hotkey, mode: .latched)
        await rig.settle()

        // One segment lands normally.
        rig.engine.segmentText = "this one landed"
        await rig.engine.closeSegmentAtEndpoint()
        await rig.wait(outcomes: 1)
        #expect(rig.spy.inserted == ["this one landed"])

        // A second is in flight (delivery suspended) and a third is queued behind it.
        rig.spy.closeGate()
        rig.engine.segmentText = "in flight"
        await rig.engine.closeSegmentAtEndpoint()
        await rig.wait(entered: 2)
        rig.engine.segmentText = "never delivered"
        await rig.engine.closeSegmentAtEndpoint()

        let dropped = rig.session.escape()
        rig.spy.openGate()
        await rig.wait(outcomes: 3)

        #expect(dropped >= 1, "Escape dropped nothing that was pending")
        #expect(rig.spy.inserted.contains("this one landed"), "Escape retracted text that had landed")
        #expect(!rig.spy.inserted.contains("never delivered"), "Escape let queued text through")
        #expect(rig.latch.cancelledSegments >= 1)
        #expect(!rig.dictation.latched)
        #expect(rig.engine.cancels >= 1)
    }

    // MARK: §8 — Speaker mismatch / uncertain, filtering on

    @Test("Speaker mismatch with filtering on suppresses insertion")
    @MainActor func speakerMismatchSuppressesInsertion() async {
        let rig = Rig()
        rig.latch.speakerGuard = { .suppress(.mismatch) }
        rig.dictation.handle(.enterLatch)
        rig.session.start(.hotkey, mode: .latched)
        await rig.settle()
        await rig.engine.closeSegmentAtEndpoint()
        await rig.wait(outcomes: 1)
        #expect(rig.spy.inserted.isEmpty, "another person's speech was inserted")
        #expect(rig.spy.held.isEmpty, "another person's speech was kept")
        #expect(rig.latch.outcomes.last?.outcome == .suppressed(.mismatch))
    }

    @Test("An uncertain speaker result with filtering on suppresses insertion")
    @MainActor func uncertainSpeakerSuppressesInsertion() async {
        let rig = Rig()
        rig.latch.speakerGuard = { .suppress(.uncertain) }
        rig.dictation.handle(.enterLatch)
        rig.session.start(.hotkey, mode: .latched)
        await rig.settle()
        await rig.engine.closeSegmentAtEndpoint()
        await rig.wait(outcomes: 1)
        #expect(rig.spy.inserted.isEmpty)
        #expect(rig.latch.outcomes.last?.outcome == .suppressed(.uncertain))
    }

    @Test("With the embedding weights absent the reason is honest, not an identification")
    @MainActor func absentWeightsSuppressWithAnHonestReason() async {
        let rig = Rig()
        let filter = SpeakerFilter(isOn: true, gate: SpeakerGate(profile: nil), canIdentify: false)
        rig.latch.speakerGuard = { filter.decide(.unknown) }
        rig.dictation.handle(.enterLatch)
        rig.session.start(.hotkey, mode: .latched)
        await rig.settle()
        await rig.engine.closeSegmentAtEndpoint()
        await rig.wait(outcomes: 1)
        #expect(rig.latch.outcomes.last?.outcome == .suppressed(.modelUnavailable))
        #expect(filter.status.message == SpeakerFilter.modelUnavailableMessage)
    }

    // MARK: §8 — Ambient enabled

    @Test("Ambient speech only ever reaches the transcript — never a field, never an action")
    @MainActor func ambientSpeechOnlyEverReachesTheTranscript() async {
        let rig = Rig()
        var transcript: [String] = []
        rig.latch.source = .ambient
        rig.latch.onTranscript = { text, _ in transcript.append(text) }
        rig.dictation.handle(.enterLatch)
        rig.session.start(.hotkey, mode: .latched)
        await rig.settle()
        rig.engine.segmentText = "someone said something near the mic"
        await rig.engine.closeSegmentAtEndpoint()
        await rig.wait(outcomes: 1)
        #expect(transcript == ["someone said something near the mic"])
        #expect(rig.spy.inserted.isEmpty, "ambient speech was typed")
        #expect(rig.spy.held.isEmpty, "ambient speech was queued for typing")
        #expect(rig.latch.outcomes.last?.outcome == .transcript("someone said something near the mic"))
    }

    // MARK: §8 — Lock / sleep

    @Test("Lock stops capture, cancels pending insertion, and never resumes on unlock")
    @MainActor func lockStopsCaptureAndNeverResumes() async {
        let rig = Rig()
        rig.dictation.handle(.enterLatch)
        rig.session.start(.hotkey, mode: .latched)
        await rig.settle()
        let startsBefore = rig.engine.starts

        rig.session.screenDidLock()
        await rig.settle()
        #expect(rig.engine.cancels >= 1, "the microphone stayed open across a lock")
        #expect(!rig.dictation.latched, "the latch survived a lock")
        #expect(rig.session.mode == .idle)
        #expect(rig.session.needsExplicitRestart)

        rig.session.screenDidUnlock()
        await rig.settle()
        #expect(rig.engine.starts == startsBefore, "capture resumed by itself after an unlock")
        #expect(rig.session.mode == .idle)
        #expect(rig.session.needsExplicitRestart, "unlocking silently cleared the restart requirement")
    }

    @Test("Sleep stops capture and waking is not a resume")
    @MainActor func sleepStopsCaptureAndNeverResumes() async {
        let rig = Rig()
        rig.dictation.handle(.enterLatch)
        rig.session.start(.hotkey, mode: .latched)
        await rig.settle()
        rig.engine.segmentText = "half a sentence"
        rig.spy.closeGate()
        await rig.engine.closeSegmentAtEndpoint()
        await rig.wait(entered: 1)
        rig.engine.segmentText = "queued behind it"
        await rig.engine.closeSegmentAtEndpoint()

        rig.session.systemWillSleep()
        rig.spy.openGate()
        await rig.wait(outcomes: 2)
        #expect(!rig.spy.inserted.contains("queued behind it"), "pending insertion survived sleep")
        #expect(rig.engine.cancels >= 1)
        #expect(!rig.dictation.latched)

        let startsBefore = rig.engine.starts
        rig.session.systemDidWake()
        await rig.settle()
        #expect(rig.engine.starts == startsBefore, "capture resumed by itself on wake")
        #expect(rig.session.needsExplicitRestart)
    }

    // MARK: §8 / §4.4 — Hard mute

    @Test("Hard mute stops every capture path, cancels pending insertion, and refuses to start")
    @MainActor func hardMuteStopsCaptureCancelsPendingAndRefusesToStart() async {
        let rig = Rig()
        rig.session.observeMute()
        rig.dictation.handle(.enterLatch)
        rig.session.start(.hotkey, mode: .latched)
        await rig.settle()

        rig.spy.closeGate()
        rig.engine.segmentText = "in flight when muted"
        await rig.engine.closeSegmentAtEndpoint()
        await rig.wait(entered: 1)
        rig.engine.segmentText = "queued when muted"
        await rig.engine.closeSegmentAtEndpoint()

        rig.mute.mute()
        rig.spy.openGate()
        await rig.wait(outcomes: 2)

        #expect(rig.dictation.paused, "hard mute did not pause the coordinator")
        #expect(rig.engine.cancels >= 1, "hard mute left a capture path open")
        #expect(!rig.dictation.latched, "the latch survived a hard mute")
        #expect(!rig.spy.inserted.contains("queued when muted"), "pending insertion survived a hard mute")
        #expect(rig.session.mode == .idle)

        // Nothing opens the microphone while muted, from any requester.
        var refusals: [SessionCoordinator.Refusal] = []
        rig.session.onRefusal = { _, refusal in refusals.append(refusal) }
        for requester in SessionCoordinator.Requester.allCases {
            #expect(rig.session.start(requester) == .refused(.muted), "\(requester) started while muted")
        }
        #expect(refusals.count == SessionCoordinator.Requester.allCases.count)
        #expect(rig.engine.starts == 1, "a muted app opened capture")

        // Unmuting makes the microphone available again; it never starts anything.
        let startsBefore = rig.engine.starts
        rig.mute.unmute()
        await rig.settle()
        #expect(!rig.dictation.paused)
        #expect(rig.engine.starts == startsBefore, "unmuting started a session by itself")
        #expect(rig.session.mode == .idle)
    }

    // MARK: R3.3 — the latch gate's own filter, on this machine

    @Test("with filtering on and no embedding weights the gate refuses and says why")
    func filteringOnWithNoWeightsRefusesHonestly() throws {
        let flags = FeatureFlagService.inMemory(["directedSpeech": true])
        let controller = LatchController(flags: flags, mute: MuteController(store: InMemoryMuteStore()),
                                         embedder: MFCCEmbedder(),
                                         profiles: SpeakerProfileStore(url: FileManager.default.temporaryDirectory
                                            .appendingPathComponent("r3-profile-\(UUID()).json")))
        controller.detector.classifier.threshold = 0
        controller.isLatched = { true }
        var captures = 0
        controller.onShouldCapture = { _ in captures += 1 }

        // Filtering off (the default): the gate behaves as it always did.
        #expect(!controller.speakerFilteringEnabled, "speaker filtering must be off until it is asked for")
        let tone = (0..<16_000).map { 0.4 * sin(2 * .pi * 220 * Float($0) / 16_000) }
        controller.appendAudio(tone)
        controller.handle(.speechStart(at: 0))
        #expect(controller.handle(.speechEnd(at: 1), utteranceSamples: tone))
        #expect(captures == 1)

        // Filtering on, and this machine has no WeSpeaker weights (V3 §2.3): suppress, and say the
        // model is unavailable rather than "that wasn't you".
        controller.speakerFilteringEnabled = true
        guard !FluidSpeakerEmbedder.isAvailable else { return }   // owner machine with weights
        #expect(controller.speakerFilter.status == .modelUnavailable)
        #expect(controller.speakerFilterMessage == SpeakerFilter.modelUnavailableMessage)
        controller.appendAudio(tone)
        controller.handle(.speechStart(at: 1))
        #expect(!controller.handle(.speechEnd(at: 2), utteranceSamples: tone))
        #expect(captures == 1, "speech was captured with no way to tell who was speaking")
        #expect(controller.lastRejection == SpeakerFilter.SuppressionReason.modelUnavailable.rawValue)
    }

    // MARK: §4.6 — one coordinator, one microphone

    @Test("The hotkey outranks onboarding and the loser is told")
    @MainActor func rankedArbitrationPreemptsAndReportsIt() async {
        let rig = Rig()
        var stoodDown: [SessionCoordinator.Requester] = []
        rig.session.onStandDown = { stoodDown.append($0) }

        #expect(rig.session.start(.onboarding) == .granted)
        #expect(rig.session.activeRequester == .onboarding)
        #expect(rig.session.start(.hotkey) == .preempted(.onboarding))
        #expect(stoodDown == [.onboarding], "the displaced owner was not told")
        #expect(rig.session.activeRequester == .hotkey)
        await rig.settle()
    }

    @Test("A lower-ranked requester is refused while the hotkey holds the microphone")
    @MainActor func lowerRankedRequestersAreRefusedNotSilentlyDropped() async {
        let rig = Rig()
        var refusals: [(SessionCoordinator.Requester, SessionCoordinator.Refusal)] = []
        rig.session.onRefusal = { refusals.append(($0, $1)) }
        rig.session.start(.hotkey)
        await rig.settle()

        #expect(rig.session.start(.meeting) == .refused(.busy(.hotkey)))
        #expect(rig.session.start(.onboarding) == .refused(.busy(.hotkey)))
        #expect(refusals.map(\.0) == [.meeting, .onboarding])
        #expect(rig.session.activeRequester == .hotkey)
        #expect(rig.engine.starts == 1, "a refused requester still opened capture")
    }

    @Test("Every requester maps onto the capture graph's existing ranked ownership")
    func requesterRanksAgreeWithTheAudioGraph() {
        // The two rankings must never disagree about who beats whom: the graph's `.engine` owner
        // outranks the meter, and every dictation-shaped requester here maps to `.engine`.
        for requester in SessionCoordinator.Requester.allCases {
            if requester.dictates {
                #expect(requester.audioOwner == .engine)
            } else {
                #expect(requester.audioOwner != .engine || requester == .meeting)
            }
        }
        #expect(SessionCoordinator.Requester.hotkey.rank > SessionCoordinator.Requester.onboarding.rank)
        #expect(SessionCoordinator.Requester.onboarding.audioOwner == .meter)
        #expect(SessionCoordinator.Requester.diagnostics.audioOwner == .diagnostics)
    }
}
