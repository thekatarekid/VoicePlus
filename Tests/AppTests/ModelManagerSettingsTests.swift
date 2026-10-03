import Foundation
import Testing
import Engine
import Pipeline
import Providers
import Shared
@testable import VoicePlusApp

// X5 — Settings › Models "Rewrite models": download / use / delete through the manager contract,
// with a scripted manager (no network, no files).

final class ScriptedModelManager: LocalModelManaging, @unchecked Sendable {
    let models = LocalLLMCatalog.shared
    private let lock = NSLock()
    private var states: [String: LocalModelState] = [:]
    private var preferred: String?
    var downloads: [String] { lock.withLock { _downloads } }
    private var _downloads: [String] = []
    func state(_ id: String) -> LocalModelState { lock.withLock { states[id] ?? .notDownloaded } }
    func download(_ id: String) async { lock.withLock { _downloads.append(id); states[id] = .ready } }
    func delete(_ id: String) async throws { lock.withLock { states[id] = nil; if preferred == id { preferred = nil } } }
    var activeModel: LocalLLMModel? {
        lock.withLock {
            if let p = preferred, states[p] == .ready { return models.first { $0.id == p } }
            return models.first { states[$0.id] == .ready }
        }
    }
    func setPreferred(_ id: String?) { lock.withLock { preferred = id } }
}

@MainActor @Suite struct ModelManagerSettingsTests {
    @Test func downloadUseAndDelete() async throws {
        let mgr = ScriptedModelManager()
        let vm = EditModelsSettingsModel(manager: mgr)
        let two = LocalLLMCatalog.qwen35_2B, four = LocalLLMCatalog.qwen35_4B
        #expect(vm.line(for: two).contains("to download"))
        await mgr.download(two.id); await mgr.download(four.id)
        vm.refresh()
        #expect(vm.activeID == two.id)
        vm.use(four.id)
        #expect(vm.activeID == four.id)
        #expect(vm.line(for: four) == "On this Mac · in use for rewrites")
        try await mgr.delete(four.id)
        vm.refresh()
        #expect(vm.activeID == two.id)
        #expect(vm.states[four.id] == .notDownloaded)
    }

    @Test func automaticPlannerPrefersTheDownloadedModel() {
        let plan = ResidencyPlanStore.shared.plan
        let picked = ComputerUseSettings.resolvedPlannerModel(InMemorySettingsStore(), plan: plan,
                                                              downloaded: { LocalLLMCatalog.qwen35_4B })
        #expect(picked == LocalLLMCatalog.qwen35_4B)
        let fallback = ComputerUseSettings.resolvedPlannerModel(InMemorySettingsStore(), plan: plan, downloaded: { nil })
        #expect(fallback == LocalLLMCatalog.sharedDefault(localLLMKey: plan.localLLMKey))
    }

    @Test func sharedProviderUsesH14SamplingAndH16Residency() {
        let p = SharedLocalLLMProvider.live(settings: InMemorySettingsStore(), residency: ModelResidency(budgetBytes: 8 << 30))
        guard let inner = p.inner() as? LlamaCppProvider else { return }   // 8 GB plan: no model offered
        #expect(inner.config.sampling == .qwenNonThinking)
        #expect(inner.config.idleUnloadAfter == 120)
        #expect(inner.config.refuseUnderCriticalPressure)
    }
}

// H16 — the optional "use my Ollama / LM Studio" path for rewrites (localhost; detection injected).
@MainActor @Suite struct RewriteServerPinTests {
    @Test func pinningAServerRoutesBothEditStagesAndUnpinningClearsOnlyThat() async {
        let store = InMemorySettingsStore()
        let vm = EditModelsSettingsModel(manager: ScriptedModelManager(), settings: store,
                                         detectServers: { [.lmStudio, .ollama] })
        await vm.refreshServers()
        #expect(vm.servers == [.ollama, .lmStudio])
        #expect(vm.serverPin == nil)
        vm.useServer(.ollama, true)
        #expect(vm.serverPin == .ollama)
        #expect(store.string(SettingsKeys.routingPrefix + "transform") == "provider:local.ollama")
        #expect(store.string(SettingsKeys.routingPrefix + StageID.question.rawValue) == "provider:local.ollama")
        vm.useServer(.lmStudio, false)          // not the pinned one: no change
        #expect(vm.serverPin == .ollama)
        vm.useServer(.ollama, false)
        #expect(vm.serverPin == nil)
        #expect(store.string(SettingsKeys.routingPrefix + "transform") == nil)
    }

    @Test func aCloudPinIsNeverClearedAndNoServerMeansNoRows() async {
        let store = InMemorySettingsStore()
        store.set("provider:openrouter", for: SettingsKeys.routingPrefix + "transform")
        RewriteServerPin.set(nil, in: store)
        #expect(store.string(SettingsKeys.routingPrefix + "transform") == "provider:openrouter")
        let vm = EditModelsSettingsModel(manager: ScriptedModelManager(), settings: store, detectServers: { [] })
        await vm.refreshServers()
        #expect(vm.servers.isEmpty)
        #expect(vm.serverPin == nil)
    }

    @Test func aPinnedServerStaysListedWhenItIsDown() async {
        let store = InMemorySettingsStore()
        RewriteServerPin.set(.lmStudio, in: store)
        let vm = EditModelsSettingsModel(manager: ScriptedModelManager(), settings: store, detectServers: { [] })
        await vm.refreshServers()
        #expect(vm.servers == [.lmStudio])
        #expect(vm.serverPin == .lmStudio)
    }
}
