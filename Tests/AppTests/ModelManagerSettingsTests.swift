import Foundation
import Testing
import Engine
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
