import Actions
import Foundation
import Injection
import Pipeline
import Shared
import Testing
@testable import VoicePlusApp

/// Phase 4 acceptance — the act path end to end over `MockActionSystem`:
/// "open the PR tab and scroll to the failing check" through the agent; irreversible actions
/// never execute unconfirmed (fuzzed); the second key gates the domain; the gatekeeper adapter
/// claims act utterances so the lander never types them.
@Suite("Phase 4 acceptance — act domain")
struct Phase4AcceptanceTests {
    static func browserSystem() -> MockActionSystem {
        let system = MockActionSystem()
        let bundle = "com.apple.Safari"
        let window = WindowRef(id: 10, appBundleID: bundle, title: "GitHub — pull request #42")
        let tabs = [
            ElementRef(id: 1, windowID: 10, role: "AXTab", title: "Overview", isSelected: true),
            ElementRef(id: 2, windowID: 10, role: "AXTab", title: "PR checks"),
            ElementRef(id: 3, windowID: 10, role: "AXStaticText", title: "build-and-test — failing"),
        ]
        system.add(MockActionSystem.MockApp(ref: AppRef(name: "Safari", bundleID: bundle), kind: .browser,
                                            windows: [window], elements: [10: tabs]))
        system.bringToFront(bundle)
        return system
    }

    static func router(system: MockActionSystem, planner: any PlannerLLM,
                       active: Bool = true) -> (ActRouter, ActDomainState, ConsentEngine) {
        let state = ActDomainState(active: active)
        let catalog = (try? ActionCatalog.load()) ?? ActionCatalog(entries: [])
        let consent = ConsentEngine()
        let executor = ActionExecutor(system: system)
        let agent = NativeAgentBackend(planner: planner, executor: executor, consent: consent)
        let router = ActRouter(parser: ActIntentParser(catalog: catalog, activation: state),
                               consent: consent, executor: executor, agent: agent)
        return (router, state, consent)
    }

    @Test func openThePRTabAndScrollToTheFailingCheck() async throws {
        let system = Self.browserSystem()
        let plan = StepPlan(goal: "open the PR tab and scroll to the failing check", steps: [
            PlanStep(title: "switch to the PR checks tab",
                     request: ActionRequest(kind: .focusTab, params: ["target": "PR checks"])),
            PlanStep(title: "scroll to the failing check",
                     request: ActionRequest(kind: .scroll, params: ["direction": "down", "amount": "5"])),
        ])
        let planner = ScriptedPlanner([.plan(plan), .done(summary: "failing check visible")])
        let (router, _, _) = Self.router(system: system, planner: planner)

        let dispatch = try await router.handle("open the PR tab and scroll to the failing check",
                                               appBundleID: "com.apple.Safari")
        guard case .agentic(let report) = dispatch else {
            Issue.record("expected the multi-step phrase to go agentic, got \(dispatch)")
            return
        }
        #expect(report.status == .completed(summary: "failing check visible"))
        #expect(report.records.allSatisfy { if case .done = $0.outcome { return true } else { return false } })
        #expect(system.log.contains("press PR checks"))
        #expect(system.log.contains("scroll down"))
        #expect(system.element(2)?.isSelected == true)
    }

    @Test func secondKeyGatesTheActDomain() async throws {
        let system = Self.browserSystem()
        let (router, state, _) = Self.router(system: system, planner: ScriptedPlanner([]), active: false)
        // Domain closed: the parser is inert, nothing routes.
        let closed = try await router.handle("switch to tab PR checks", appBundleID: "com.apple.Safari")
        #expect(closed == .ignored(reason: "act domain inactive"))
        #expect(system.log.isEmpty)
        // Second key down → deterministic catalogue hit executes.
        state.activate()
        let open = try await router.handle("switch to tab PR checks", appBundleID: "com.apple.Safari")
        guard case .deterministic(let result, let outcome) = open else {
            Issue.record("expected deterministic dispatch, got \(open)")
            return
        }
        #expect(result?.outcome.isSuccess == true)
        if case .awaitingConfirmation = outcome { Issue.record("reversible action must not require confirmation") }
        #expect(system.log.contains("press PR checks"))
    }

    @Test func irreversibleActionsNeverExecuteUnconfirmed() async throws {
        // Fuzz the consent engine directly: random irreversible requests + random control
        // utterances. The executor must run only after an explicit confirm.
        final class ExecLog: @unchecked Sendable {
            private let lock = NSLock()
            private var ids: [String] = []
            func append(_ id: String) { lock.lock(); ids.append(id); lock.unlock() }
            func contains(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return ids.contains(id) }
            var count: Int { lock.lock(); defer { lock.unlock() }; return ids.count }
        }
        let consent = ConsentEngine()
        let executed = ExecLog()
        var rng = SystemRandomNumberGenerator()
        for i in 0..<200 {
            let id = "fuzz.\(i)"
            let request = ConsentRequest(id: id, category: .delete, title: "delete \(i)",
                                         flags: Bool.random(using: &rng) ? ["destructive"] : [])
            let (token, outcome) = try await consent.submit(request) { _ in
                executed.append(id)
                return ExecutionReceipt(handle: id)
            }
            guard case .awaitingConfirmation = outcome else {
                Issue.record("irreversible request \(id) did not park for confirmation: \(outcome)")
                continue
            }
            #expect(!executed.contains(id), "parked action ran before confirmation")
            // Random spoken answers; only a real confirm may run it.
            let spoken = ["confirm", "cancel", "no", "do it", "never mind", "yes confirm", "delete it all", ""].randomElement(using: &rng)!
            let out = try await consent.confirm(token, spoken: spoken)
            let confirmed = ConfirmationCard.isSpokenConfirm(spoken)
            if confirmed {
                #expect(executed.contains(id))
                if case .executed = out {} else { Issue.record("confirm of \(id) produced \(out)") }
            } else {
                #expect(!executed.contains(id), "'\(spoken)' executed an irreversible action")
            }
        }
        #expect(executed.count < 200)
    }

    @Test func irreversibleCatalogueEntryParksThroughTheRouter() async throws {
        let system = MockActionSystem()
        let bundle = "com.apple.mail"
        let window = WindowRef(id: 20, appBundleID: bundle, title: "New Message")
        let send = ElementRef(id: 5, windowID: 20, role: "AXButton", title: "Send")
        system.add(MockActionSystem.MockApp(ref: AppRef(name: "Mail", bundleID: bundle), kind: .mail,
                                            windows: [window], elements: [20: [send]]))
        system.bringToFront(bundle)
        let (router, _, _) = Self.router(system: system, planner: ScriptedPlanner([]))

        let dispatch = try await router.handle("click send email", appBundleID: bundle)
        guard case .deterministic(let result, let outcome) = dispatch else {
            Issue.record("expected deterministic, got \(dispatch)")
            return
        }
        guard case .awaitingConfirmation = outcome else {
            Issue.record("mail send must await confirmation, got \(outcome)")
            return
        }
        #expect(result == nil)
        #expect(!system.log.contains("press Send"), "irreversible ran before confirmation")
        #expect(router.hasPendingConfirmation)

        // Spoken confirm through the router (the same path the gatekeeper adapter feeds).
        let confirmed = try await router.dispatch(.confirm)
        guard case .confirmed = confirmed else {
            Issue.record("expected .confirmed, got \(confirmed)")
            return
        }
        #expect(system.log.contains("press Send"))
        #expect(!router.hasPendingConfirmation)
    }

    @Test func gatekeeperAdapterClaimsActUtterancesAndLanderNeverTypesThem() async throws {
        let hook = ActPreRouteHook()
        let state = ActDomainState(active: true)
        let catalog = (try? ActionCatalog.load()) ?? ActionCatalog(entries: [])
        hook.parser = ActIntentParser(catalog: catalog, activation: state)
        var routed: [ActRoute] = []
        hook.onRoute = { routed.append($0) }

        let classifier = PreRoutingClassifier(hooks: [hook])
        let decision = classifier.classify("next tab", context: StageContext(appBundleID: "com.apple.Safari"))
        #expect(decision.route == Utterance.Route.none)
        #expect(routed.count == 1)

        // The lander sees route .none + a consumed claim → no injection.
        let injectorSystem = MockSystemAccess()
        let lander = UtteranceLander(pipeline: PipelineRunner(gatekeeper: GatekeeperStage(local: classifier), stages: []),
                                     injector: TextInjector(system: injectorSystem), system: injectorSystem,
                                     repair: nil, flags: .inMemory(), database: nil)
        lander.actClaimConsumer = { hook.consumeClaim() }
        let spans = [TranscriptSpan(text: "next", confidence: 0.9, audioRange: 0...0.2),
                     TranscriptSpan(text: "tab", confidence: 0.9, audioRange: 0.2...0.4)]
        let result = await lander.land(spans, startedAt: Date(), focus: injectorSystem.frontmostApp())
        #expect(result.injection == nil, "act-claimed text must never be typed")
        #expect(result.route == Utterance.Route.none)

        // Domain closed → the same text types normally.
        state.deactivate()
        let result2 = await lander.land(spans, startedAt: Date(), focus: injectorSystem.frontmostApp())
        #expect(result2.injection != nil)
    }

    @Test func plannerReplyParsing() {
        let plan = ProviderPlanner.parse("""
        1. focusTab(target=PR checks)
        2. scroll(direction=down, amount=5)
        """, goal: "g")
        guard case .plan(let p) = plan else {
            Issue.record("expected .plan, got \(plan)")
            return
        }
        #expect(p.steps.count == 2)
        #expect(p.steps[0].request.kind == .focusTab)
        #expect(p.steps[0].request.params["target"] == "PR checks")
        #expect(p.steps[1].request.params["amount"] == "5")

        if case .done(let s) = ProviderPlanner.parse("DONE all set", goal: "g") { #expect(s == "all set") }
        else { Issue.record("DONE not parsed") }
        if case .giveUp = ProviderPlanner.parse("GIVEUP no such window", goal: "g") {}
        else { Issue.record("GIVEUP not parsed") }
        if case .giveUp = ProviderPlanner.parse("random prose with no tool calls", goal: "g") {}
        else { Issue.record("unparseable reply must give up, never guess") }
    }

    @Test func loopbackReceiverParsesCallback() {
        let parsed = LoopbackCodeReceiver.parse(request: "GET /auth/callback?code=abc123&state=xyz HTTP/1.1\r\nHost: localhost:1456\r\n\r\n")
        #expect(parsed?.code == "abc123")
        #expect(parsed?.state == "xyz")
        #expect(LoopbackCodeReceiver.parse(request: "GET /favicon.ico HTTP/1.1\r\n\r\n") == nil)
    }

    @Test func catalogLoadsWithFullVocabulary() throws {
        let catalog = try ActionCatalog.load()
        #expect(catalog.entries.count == 200)
        #expect(catalog.entries.contains { $0.reversibility == .irreversible })
    }
}
