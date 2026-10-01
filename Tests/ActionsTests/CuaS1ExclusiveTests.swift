import Foundation
import Shared
import Testing
@testable import Actions

/// V5 CU9 — one 4B at a time: CUA-S1 is `.exclusive`, loads for the act turn, unloads after it, and
/// queues (never fails outright) behind another exclusive model.
@Suite struct CuaS1ExclusiveTests {
    actor CountingBackend: CuaS1Backend {
        var loads = 0, unloads = 0
        var isLoaded = false
        func load() async throws { loads += 1; isLoaded = true }
        func unload() { unloads += 1; isLoaded = false }
        func decide(_ state: CuaS1State) async throws -> CuaS1Decision {
            CuaS1Decision(probabilities: state.options.indices.map { $0 == 0 ? 0.9 : 0.1 })
        }
    }

    /// Another `.exclusive` model (the 4B planner on a 16 GB plan).
    actor Other {
        var loaded = false
        var log: [String] = []
        func load() { loaded = true; log.append("planner load") }
        func unload() { loaded = false; log.append("planner unload") }
    }

    static let plannerKey = "llm.qwen3.5-4b"
    static let state = CuaS1State(app: "A", taskFamily: "navigation", goal: "g", accessibilityTree: "",
                                  options: [.init(elementId: "el_0", role: "Button", label: "a", action: "click"),
                                            .init(elementId: "el_1", role: "Button", label: "b", action: "click")])

    func residencyWithPlanner(_ other: Other) async -> ModelResidency {
        let r = ModelResidency(budgetBytes: 12 << 30)
        await r.register(Self.plannerKey, tier: .exclusive, estimatedBytes: 3_200_000_000, owner: "llm",
                         load: { await other.load() }, unload: { await other.unload() })
        return r
    }

    @Test("ModelResidency refuses a second exclusive model while the first is resident")
    func refusesSecondExclusive() async throws {
        let other = Other()
        let r = await residencyWithPlanner(other)
        try await r.acquire(Self.plannerKey)
        let resident = ResidentCuaS1(backend: CountingBackend(), residency: r)
        await resident.register()
        await #expect(throws: ResidencyError.self) { try await r.acquire(CuaS1Catalog.residencyKey) }
        #expect(await r.recentEvents().contains { $0.kind == .refused && $0.reason == .exclusiveConflict })
    }

    @Test("queued behind a planner that is in use: the decision waits for it to finish, then loads")
    func queuesWhileOtherIsBusy() async throws {
        let other = Other()
        let r = await residencyWithPlanner(other)
        let backend = CountingBackend()
        let resident = ResidentCuaS1(backend: backend, residency: r, queueTimeout: 5, pollInterval: 0.01)
        // The planner is mid-generation (pinned) for ~150 ms.
        let planner = Task {
            try await r.withModel(Self.plannerKey) { try await Task.sleep(nanoseconds: 150_000_000) }
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        let decision = try await resident.decide(Self.state)
        try await planner.value
        #expect(decision.bestIndex == 0)
        #expect(await backend.loads == 1)
        #expect(await r.isResident(CuaS1Catalog.residencyKey))
        #expect(!(await r.isResident(Self.plannerKey)))
    }

    @Test("an idle resident planner is unloaded (reason .exclusive) so CUA-S1 can load; never both resident")
    func idleOtherIsUnloaded() async throws {
        let other = Other()
        let r = await residencyWithPlanner(other)
        try await r.acquire(Self.plannerKey)
        let backend = CountingBackend()
        let resident = ResidentCuaS1(backend: backend, residency: r, queueTimeout: 5, pollInterval: 0.01)
        _ = try await resident.decide(Self.state)
        #expect(await other.log == ["planner load", "planner unload"])
        #expect(await r.recentEvents().contains { $0.key == Self.plannerKey && $0.kind == .unload && $0.reason == .exclusive })
        let resi = await r.snapshot().residentKeys
        #expect(resi == [CuaS1Catalog.residencyKey])
    }

    @Test("the queue gives up after its timeout; the refusal reaches the router (→ planner)")
    func queueTimesOut() async throws {
        let other = Other()
        let r = await residencyWithPlanner(other)
        let backend = CountingBackend()
        let resident = ResidentCuaS1(backend: backend, residency: r, queueTimeout: 0.05, pollInterval: 0.01)
        let hold = Task { try await r.withModel(Self.plannerKey) { try await Task.sleep(nanoseconds: 400_000_000) } }
        try await Task.sleep(nanoseconds: 20_000_000)
        await #expect(throws: ResidencyError.self) { _ = try await resident.decide(Self.state) }
        #expect(await backend.loads == 0)
        try await hold.value
    }

    @Test("16 GB: loaded for the act turn, unloaded after it; the 4B planner can load next")
    func unloadAfterTurn() async throws {
        let other = Other()
        let r = await residencyWithPlanner(other)
        let backend = CountingBackend()
        let resident = ResidentCuaS1(backend: backend, residency: r)
        let step = CuaS1SingleStep(chooser: CuaS1Chooser(model: resident), resident: resident, keepWarm: false)
        await step.beginTurn()
        #expect(await backend.loads == 0)   // nothing loads until a goal needs the chooser
        let obs = AXSummary(app: "A", window: "W", elements: [.init(role: "AXButton", title: "a", value: "", isSelected: false, isEnabled: true),
                                                              .init(role: "AXButton", title: "b", value: "", isSelected: false, isEnabled: true)])
        _ = try await step.choose(goal: "press a", observation: obs)
        #expect(await r.isResident(CuaS1Catalog.residencyKey))
        await step.endTurn()
        #expect(!(await r.isResident(CuaS1Catalog.residencyKey)))
        #expect(await backend.unloads == 1)
        try await r.acquire(Self.plannerKey)   // no exclusive conflict now
        #expect(await other.loaded)
    }

    @Test("≥ 24 GB: kept warm — loads at act key down, stays after the turn")
    func keptWarm() async throws {
        let r = ModelResidency(budgetBytes: 20 << 30)
        let backend = CountingBackend()
        let resident = ResidentCuaS1(backend: backend, residency: r)
        await resident.register(tier: .onDemand)
        let step = CuaS1SingleStep(chooser: CuaS1Chooser(model: resident), resident: resident, keepWarm: true)
        await step.beginTurn()
        #expect(await backend.loads == 1)
        await step.endTurn()
        #expect(await r.isResident(CuaS1Catalog.residencyKey))
    }

    @Test("the router begins the act turn on the lazily resolved chooser")
    func routerBeginsTurn() async throws {
        final class Spy: SingleStepChoosing, @unchecked Sendable {
            var begun = 0
            func choose(goal: String, observation: AXSummary) async throws -> CuaS1Choice { throw CuaS1Error.noCandidates }
            func beginTurn() async { begun += 1 }
            func endTurn() async {}
        }
        final class NoAgent: AgentActionBackend, @unchecked Sendable {
            var isRunning = false
            func run(goal: String) async -> AgentRunReport { AgentRunReport(goal: goal, status: .completed(summary: ""), records: [], rounds: 0) }
            func stop() async {}
        }
        let catalog = try ActionCatalog.load()
        let router = ActRouter(parser: ActIntentParser(catalog: catalog, activation: ActDomainState(active: true)),
                               consent: ConsentEngine(), executor: ActionExecutor(system: MockActionSystem()), agent: NoAgent())
        let spy = Spy()
        router.chooserProvider = { spy }
        await router.beginActTurn()
        await router.beginActTurn()
        #expect(spy.begun == 2)
    }
}
