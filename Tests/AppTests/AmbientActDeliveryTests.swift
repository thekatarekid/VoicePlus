import Actions
import Combine
import Engine
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// V5 CU7 — ambient-driven computer use: the intent arbiter's `act` owner (Listen & act only) feeds
/// the same path as the act key; consent rules unchanged; ambient never confirms an irreversible step.
@Suite("V5 CU7 ambient-driven CUA")
struct AmbientActDeliveryTests {
    private final class IdleEngine: EngineProtocol, @unchecked Sendable {
        private let subject = CurrentValueSubject<EngineState, Never>(.idle)
        var state: EngineState { subject.value }
        var statePublisher: AnyPublisher<EngineState, Never> { subject.eraseToAnyPublisher() }
        func events() -> AsyncStream<EngineEvent> { AsyncStream { $0.finish() } }
        func prewarm() async throws {}
        func start(prewarm: Bool) async throws {}
        func stop() async throws -> [TranscriptSpan] { [] }
        func cancel() async {}
    }

    private struct GiveUpPlanner: PlannerLLM {
        func plan(goal: String, observation: AXSummary, history: [StepRecord], tools: [AgentTool]) async throws -> PlannerTurn {
            .giveUp(reason: "stub")
        }
    }

    final class Outcomes: @unchecked Sendable {
        private let lock = NSLock()
        private var _all: [AmbientActDelivery.Outcome] = []
        var all: [AmbientActDelivery.Outcome] { lock.withLock { _all } }
        func add(_ o: AmbientActDelivery.Outcome) { lock.withLock { _all.append(o) } }
    }

    final class ForwardSpy: AmbientDelivering, @unchecked Sendable {
        private let lock = NSLock()
        private var _owners: [UtteranceOwner] = []
        var owners: [UtteranceOwner] { lock.withLock { _owners } }
        func deliver(_ text: String, owner: UtteranceOwner, decision: UtteranceDecision) async { lock.withLock { _owners.append(owner) } }
    }

    struct Rig {
        let system = MockActionSystem()
        let settings = InMemorySettingsStore()
        let state = ActDomainState()
        let session: ActSessionController
        let delivery = AmbientActDelivery()
        let outcomes = Outcomes()
        let mode: AmbientModeController

        init(mode m: AmbientMode = .listenAndAct, actEnabled: Bool = true) throws {
            let app = AppRef(name: "Forms", bundleID: "com.example.forms")
            let window = WindowRef(id: 1, appBundleID: app.bundleID, title: "Order")
            system.add(.init(ref: app, kind: .browser, windows: [window], elements: [1: [
                ElementRef(id: 10, windowID: 1, role: "AXButton", title: "Submit"),
                ElementRef(id: 11, windowID: 1, role: "AXButton", title: "OK"),
            ]]))
            let catalog = try ActionCatalog.load()
            let consent = ConsentEngine()
            let executor = ActionExecutor(system: system)
            let router = ActRouter(parser: ActIntentParser(catalog: catalog, activation: state), consent: consent,
                                   executor: executor,
                                   agent: NativeAgentBackend(planner: GiveUpPlanner(), executor: executor, consent: consent))
            session = ActSessionController(engine: IdleEngine(), router: router, state: state, installLayer2: false)
            session.appBundleID = { "com.example.forms" }
            session.settings = settings
            ActKeySettings.setEnabled(actEnabled, store: settings)
            mode = AmbientModeController(settings: settings)
            mode.set(m)
            let mode = self.mode
            delivery.attach(session, mode: { mode.mode })
            let outcomes = self.outcomes
            delivery.onOutcome = { outcomes.add($0) }
        }

        static let act = UtteranceDecision(owner: .act, confidence: 0.95, band: .act, reason: "layer1.test")

        func deliver(_ text: String, owner: UtteranceOwner = .act) async {
            await delivery.deliver(text, owner: owner, decision: Self.act)
        }
    }

    @Test("an ambient act runs the act key's path: catalogue → consent → executor")
    func ambientActRunsTheActPath() async throws {
        let rig = try Rig()
        await rig.deliver("click ok")
        #expect(rig.system.log.contains("press OK"))
        guard case .dispatched(.deterministic(_, let out))? = rig.outcomes.all.last else {
            Issue.record("expected a deterministic dispatch, got \(rig.outcomes.all)"); return
        }
        if case .awaitingConfirmation = out { Issue.record("semi-reversible must not wait for a card") }
        #expect(!rig.state.isActDomainActive, "domain closes when nothing is pending")
    }

    @Test("an irreversible ambient act waits for a card; an ambient 'confirm' never confirms it; an explicit turn does")
    func ambientNeverConfirmsIrreversible() async throws {
        let rig = try Rig()
        await rig.deliver("click submit")
        guard case .dispatched(.deterministic(_, .awaitingConfirmation))? = rig.outcomes.all.last else {
            Issue.record("expected a pending card, got \(rig.outcomes.all)"); return
        }
        #expect(!rig.system.log.contains("press Submit"))
        #expect(rig.session.router.hasPendingConfirmation)
        #expect(rig.state.isActDomainActive, "a pending card keeps the domain open for the user's explicit confirm")

        // Ambient "confirm" (even if it got past the guarantees) is dropped before the consent engine.
        for spoken in ["confirm", "Confirm.", "yes confirm"] {
            let d = await rig.session.dispatchAmbient(spoken)
            if ConfirmationCard.isSpokenConfirm(FuzzyMatch.normalize(spoken)) {
                #expect(d == .ignored(reason: ActSessionController.ambientCannotConfirm))
            }
        }
        await rig.deliver("confirm")
        #expect(!rig.system.log.contains("press Submit"))
        #expect(rig.session.router.hasPendingConfirmation)

        // The user's own turn (act key / dictation key while the domain is open) confirms.
        await rig.session.dispatch("confirm")
        #expect(rig.system.log.contains("press Submit"))
        #expect(!rig.session.router.hasPendingConfirmation)
    }

    @Test("ambient stop / cancel still work (they only ever reduce what runs)")
    func ambientCancelDropsTheCard() async throws {
        let rig = try Rig()
        await rig.deliver("click submit")
        #expect(rig.session.router.hasPendingConfirmation)
        let d = await rig.session.dispatchAmbient("cancel")
        #expect(d == .cancelled)
        #expect(!rig.session.router.hasPendingConfirmation && !rig.system.log.contains("press Submit"))
    }

    @Test("only Listen & act, only with computer use on")
    func gates() async throws {
        for m in [AmbientMode.off, .listenAndNote] {
            let rig = try Rig(mode: m)
            await rig.deliver("click ok")
            #expect(rig.outcomes.all == [.refused("not Listen & act")])
            #expect(!rig.system.log.contains("press OK"))
        }
        let off = try Rig(actEnabled: false)
        await off.deliver("click ok")
        #expect(off.outcomes.all == [.refused("computer use off")])
        #expect(!off.system.log.contains("press OK"))

        let detached = AmbientActDelivery()
        let outcomes = Outcomes()
        detached.onOutcome = { outcomes.add($0) }
        await detached.deliver("click ok", owner: .act, decision: Rig.act)
        #expect(outcomes.all == [.refused("no act session")])
    }

    @Test("non-act owners are forwarded to `next`, never run as actions")
    func nonActOwnersForward() async throws {
        let rig = try Rig()
        await rig.deliver("click ok", owner: .dictate)
        #expect(rig.outcomes.all == [.refused("no delivery for dictate")])
        let spy = ForwardSpy()
        rig.delivery.next = spy
        await rig.deliver("click ok", owner: .ask)
        #expect(spy.owners == [.ask])
        #expect(!rig.system.log.contains("press OK"))
    }

    @Test("end to end: the ambient pipeline's act decision reaches the act session (Listen & act, your voice)")
    func throughThePipeline() async throws {
        let rig = try Rig()
        final class ActModel: DecisionModel, @unchecked Sendable {
            let id = "mock"
            func decide(state: String, questions: [DecisionQuestion]) async throws -> DecisionAnswers {
                var cap: [String: Double] = [:]
                for o in UtteranceOwner.allCases { cap[o.rawValue] = o == .act ? 0.9 : 0.02 }
                return DecisionAnswers([.addressed: ["no": 0.03, "yes": 0.97], .complete: ["no": 0.05, "yes": 0.95],
                                        .capability: cap, .continuation: ["no": 0.5, "yes": 0.5],
                                        .needsAgent: ["no": 0.9, "yes": 0.1], .worthNoting: ["no": 0.9, "yes": 0.1]])
            }
        }
        let model = ActModel()
        let arbiter = IntentArbiter(layer0: ArbiterWiring.layer0(actParser: nil), model: { model })
        let pipeline = AmbientDecisionPipeline(mode: rig.mode, arbiter: { arbiter }, verdict: { .user(similarity: 0.9) })
        pipeline.delivery = rig.delivery
        let out = await pipeline.handle("click ok", utteranceID: "u1", range: Date()...Date())
        #expect(out == .deliver(.act))
        #expect(rig.system.log.contains("press OK"))
        // Another voice: never reaches the act session.
        let other = AmbientDecisionPipeline(mode: rig.mode, arbiter: { arbiter }, verdict: { .other(similarity: 0.1) })
        other.delivery = rig.delivery
        let before = rig.system.log.count
        _ = await other.handle("click ok", utteranceID: "u2", range: Date()...Date())
        #expect(rig.system.log.count == before)
    }
}
