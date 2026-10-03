import Actions
import Engine
import Foundation
import Pipeline
import Providers
import Shared
import Testing
@testable import VoicePlusApp

/// V5 CU8 — one shipped local instruct model (Qwen3.5-2B / 4B on llama.cpp) behind `act.planner` and
/// the other generative stages. No GGUF is downloaded: the engine is scripted, the file check stubbed.
@Suite("CU8 shipped local planner")
struct SharedLocalPlannerTests {

    final class Engine: LocalLLMEngine, @unchecked Sendable {
        private let lock = NSLock()
        private var _loads = 0
        private var _systems: [String] = []
        let reply: String
        init(reply: String) { self.reply = reply }
        var loads: Int { lock.withLock { _loads } }
        var systems: [String] { lock.withLock { _systems } }
        func load(modelPath: URL) async throws { lock.withLock { _loads += 1 } }
        func unload() async {}
        func generate(system: String, user: String, maxTokens: Int, deadline: Date) async throws -> String {
            lock.withLock { _systems.append(system) }
            return reply
        }
    }

    struct StubRoute: LocalPlannerRouting {
        var available: Bool
        var reply: String
        var fails = false
        func isAvailable() async -> Bool { available }
        func complete(stage: StageID, system: String, user: String) async throws -> String {
            if fails { throw ProviderError.timeout }
            return reply
        }
    }

    struct PinnedRouting: PipelineProviderRouting {
        let reply: String
        func isProviderEnabled(for stage: StageID, context: StageContext) -> Bool { true }
        func complete(stage: StageID, prompt: String, input: String, context: StageContext) async throws -> String { reply }
    }

    static let planJSON = #"{"status":"plan","steps":[{"tool":"focusTab","params":{"target":"Pull requests"}}]}"#

    static func shared(engine: Engine, residency: ModelResidency, model: LocalLLMModel? = LocalLLMCatalog.qwen35_2B,
                       installed: Bool = true) -> SharedLocalLLMProvider {
        SharedLocalLLMProvider(resolveModel: { model }, makeInner: { m in
            LlamaCppProvider(config: LlamaCppConfig(modelPath: URL(fileURLWithPath: "/tmp/\(m.fileName)"),
                                                    residencyKey: ComputerUseSettings.residencyKey(for: m),
                                                    estimatedBytes: m.residentBytes, maxTokens: 256, deadline: 5),
                             residency: residency, engine: engine, fileExists: { _ in installed })
        })
    }

    // MARK: Catalog + plan

    @Test("catalog: Qwen3.5-2B / 4B Q4_K_M, Apache-2.0, hashed; picked by the HW2 plan")
    func catalog() {
        #expect(LocalLLMCatalog.qwen35_2B.fileName == "Qwen3.5-2B-Q4_K_M.gguf")
        #expect(LocalLLMCatalog.qwen35_4B.fileName == "Qwen3.5-4B-Q4_K_M.gguf")
        #expect(LocalLLMCatalog.shared.allSatisfy { $0.license == "Apache-2.0" && $0.sha256.count == 64 })
        #expect(!LocalLLMCatalog.all.contains(LocalLLMCatalog.qwen35_2B), "the planner is not a cleanup candidate")
        #expect(LocalLLMCatalog.sharedDefault(localLLMKey: ResidencyKey.localLLM2B) == LocalLLMCatalog.qwen35_2B)
        #expect(LocalLLMCatalog.sharedDefault(localLLMKey: ResidencyKey.localLLM4B) == LocalLLMCatalog.qwen35_4B)
        let store = InMemorySettingsStore()
        #expect(ComputerUseSettings.resolvedPlannerModel(store, plan: .for(.compact), downloaded: { nil }) == nil)
        #expect(ComputerUseSettings.resolvedPlannerModel(store, plan: .for(.standard), downloaded: { nil }) == LocalLLMCatalog.qwen35_2B)
        #expect(ComputerUseSettings.resolvedPlannerModel(store, plan: .for(.roomy), downloaded: { nil }) == LocalLLMCatalog.qwen35_4B)
        ComputerUseSettings.setPlannerModel(.qwen4B, store: store)
        #expect(ComputerUseSettings.resolvedPlannerModel(store, plan: .for(.standard), downloaded: { nil }) == LocalLLMCatalog.qwen35_4B)
        #expect(ComputerUseSettings.residencyKey(for: LocalLLMCatalog.qwen35_4B) == ResidencyKey.localLLM4B)
    }

    @Test("act.planner accepts the local model in Settings")
    func acceptsLocal() {
        #expect(RoutableStage.all.first { $0.id == ProviderPlanner.stage }?.acceptsLocal == true)
    }

    // MARK: ProviderPlanner

    @Test("no pin + local model installed → plans locally from strict JSON")
    func plansLocally() async throws {
        let planner = ProviderPlanner(providers: LocalOnlyProviderRouting(), local: StubRoute(available: true, reply: Self.planJSON))
        let turn = try await planner.plan(goal: "open PRs", observation: AXSummary(app: "Safari", window: "repo"),
                                          history: [], tools: AgentTool.vocabulary)
        guard case .plan(let plan) = turn else { Issue.record("expected a plan, got \(turn)"); return }
        #expect(plan.steps.first?.request == ActionRequest(kind: .focusTab, params: ["target": "Pull requests"]))
    }

    @Test("planner unavailable (model not downloaded) → .unavailable state, not a failure")
    func unavailableIsAState() async {
        let planner = ProviderPlanner(providers: LocalOnlyProviderRouting(), local: StubRoute(available: false, reply: ""))
        let agent = NativeAgentBackend(planner: planner, executor: ActionExecutor(system: MockActionSystem()),
                                       consent: ConsentEngine())
        let report = await agent.run(goal: "send the note to Priya")
        guard case .unavailable = report.status else { Issue.record("expected unavailable, got \(report.status)"); return }
        #expect(report.userMessage == "Actions need a model set up in Settings")
    }

    @Test("a local model that errors mid-call is unavailable too")
    func localErrorIsUnavailable() async {
        let planner = ProviderPlanner(providers: LocalOnlyProviderRouting(),
                                      local: StubRoute(available: true, reply: "", fails: true))
        await #expect(throws: PlannerError.self) {
            _ = try await planner.plan(goal: "g", observation: AXSummary(app: "a", window: "w"), history: [], tools: [])
        }
    }

    @Test("a pinned provider wins over the local model")
    func pinWins() async throws {
        let planner = ProviderPlanner(providers: PinnedRouting(reply: #"{"status":"done","summary":"pinned"}"#),
                                      local: StubRoute(available: true, reply: Self.planJSON))
        let turn = try await planner.plan(goal: "g", observation: AXSummary(app: "a", window: "w"), history: [], tools: [])
        #expect(turn == .done(summary: "pinned"))
    }

    @Test("legacy line replies from older pinned providers still parse")
    func legacyLines() {
        guard case .plan(let p) = ProviderPlanner.parse("1. click(name=Submit)", goal: "g") else { Issue.record("no plan"); return }
        #expect(p.steps.first?.request.kind == .click)
    }

    // MARK: SharedLocalLLMProvider + routing table + residency

    @Test("the shared provider routes through RoutingTable and loads via ModelResidency under the plan key")
    func endToEnd() async throws {
        let engine = Engine(reply: "<think>hmm</think>" + Self.planJSON)
        let residency = ModelResidency(budgetBytes: 8 << 30)
        let table = RoutingTable(providers: [], logger: InMemoryNetworkLogger())
        let route = SharedLocalLLM(table: table, provider: Self.shared(engine: engine, residency: residency))
        #expect(await route.isAvailable())
        let planner = ProviderPlanner(providers: LocalOnlyProviderRouting(), local: route)
        let turn = try await planner.plan(goal: "open PRs", observation: AXSummary(app: "Safari", window: "repo"),
                                          history: [], tools: AgentTool.vocabulary)
        guard case .plan = turn else { Issue.record("expected a plan, got \(turn)"); return }
        #expect(engine.loads == 1)
        #expect(await residency.isRegistered(ResidencyKey.localLLM2B))
        #expect(engine.systems.first?.contains("ONE JSON object") == true, "the planner's own system prompt reaches the model")
    }

    @Test("not on disk → unavailable, nothing loads")
    func notInstalled() async {
        let engine = Engine(reply: "")
        let residency = ModelResidency(budgetBytes: 8 << 30)
        let table = RoutingTable(providers: [], logger: InMemoryNetworkLogger())
        let route = SharedLocalLLM(table: table, provider: Self.shared(engine: engine, residency: residency, installed: false))
        #expect(await route.isAvailable() == false)
        let planner = ProviderPlanner(providers: LocalOnlyProviderRouting(), local: route)
        await #expect(throws: PlannerError.self) {
            _ = try await planner.plan(goal: "g", observation: AXSummary(app: "a", window: "w"), history: [], tools: [])
        }
        #expect(engine.loads == 0)
    }

    @Test("8 GB plan: no shared model, unavailable")
    func compactPlan() async {
        let p = Self.shared(engine: Engine(reply: ""), residency: ModelResidency(budgetBytes: 8 << 30), model: nil)
        #expect(await p.isAvailable() == false)
    }

    @Test("same model registered for planner, meetings, style, N5 and I3 — and nothing else")
    func servedStages() async throws {
        let engine = Engine(reply: "ok")
        let p = Self.shared(engine: engine, residency: ModelResidency(budgetBytes: 8 << 30))
        for stage in [ProviderPlanner.stage, .meetingNotes, .meetingAsk, .style,
                      SharedLocalLLMProvider.notesFollowUpStage, SharedLocalLLMProvider.explainStage] {
            #expect(SharedLocalLLMProvider.servedStages.contains(stage))
            _ = try await p.generate(prompt: "x", system: "s", stage: stage)
        }
        await #expect(throws: ProviderError.self) { _ = try await p.generate(prompt: "x", system: "s", stage: .gatekeeper) }
        #expect(p.privacyClass == .onDevice && p.costClass == .free)
    }

    @Test("planner-model status: not offered on 8 GB, download offered otherwise, installed when on disk")
    @MainActor
    func installerStatus() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cu8-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = InMemorySettingsStore()
        var plan = ResidencyPlan.for(.compact)
        let installer = PlannerModelInstaller(store: store, downloader: LocalLLMDownloader(root: root), plan: { plan },
                                              downloaded: { nil })   // not this Mac's real rewrite models
        #expect(installer.status == .notOffered)
        plan = .for(.standard)
        installer.refresh()
        #expect(installer.status == .notDownloaded(LocalLLMCatalog.qwen35_2B))
        #expect(installer.status.canDownload)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: LocalLLMCatalog.qwen35_2B.localURL(root: root).path, contents: Data())
        installer.refresh()
        #expect(installer.status == .installed(LocalLLMCatalog.qwen35_2B))
    }
}
