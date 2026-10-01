import Engine
import Foundation
import Pipeline
import Providers
import Shared

// MARK: - V5 D2 · app wiring for the cleanup LLM
//
// - `LlamaCppProvider` (on-device, llama.cpp) is registered in the `RoutingTable` and with
//   `ModelResidency` under `ResidencyKey.cleanup` (tier from the HW2 plan), so D5's prewarm at
//   hotkey-down finds it and the idle sweeper unloads it.
// - `RoutingCleanupGenerator` is the stage's `CleanupGenerating`: every call goes through the
//   routing table, stage `cleanup` (§10). Local only unless the user pinned a provider for the stage
//   (`routing.cleanup = provider:<id>`); the rules fallback "completing" counts as no model.
// - `CleanupStage` goes in front of the style pass, behind the D3 guard (P5 entity guard inside).

public final class RoutingCleanupGenerator: CleanupGenerating, @unchecked Sendable {
    public let table: RoutingTable
    private let settings: SettingsStore
    public let promptStyle: CleanupPromptStyle

    public init(table: RoutingTable, settings: SettingsStore, promptStyle: CleanupPromptStyle) {
        self.table = table
        self.settings = settings
        self.promptStyle = promptStyle
    }

    public func cleanup(_ prompt: CleanupPrompt, context: StageContext) async throws -> String {
        var ctx = context
        ctx.extra[PromptBuilder.systemOverrideKey] = prompt.system
        ctx.extra[PromptBuilder.userOverrideKey] = prompt.user
        switch settings.string(SettingsKeys.routingPrefix + StageID.cleanup.rawValue).flatMap(ProviderChoice.init(rawValue:)) {
        case .provider(let id)?: table.setChoice(.provider(ProviderID(rawValue: id)), for: .cleanup)
        default: table.setChoice(.localOnly, for: .cleanup)
        }
        let span = TranscriptSpan(text: prompt.user, confidence: 1, audioRange: 0...0, provenance: [.asr])
        let outcome = try await table.complete(stage: .cleanup, spans: [span], context: ctx, purpose: "pipeline:cleanup")
        guard outcome.provider != table.fallback.id else { throw ProviderRoutingError.unavailable }
        return outcome.completion.spans.map(\.text).joined(separator: " ")
    }
}

public enum CleanupWiring {
    /// The model the app uses (D2's pick, provisional until the V1 gate runs on hardware).
    public static var model: LocalLLMModel { LocalLLMCatalog.cleanupDefault }

    public static func mode(settings: SettingsStore) -> CleanupMode {
        settings.string(CleanupMode.settingsKey).flatMap(CleanupMode.init(rawValue:)) ?? .default
    }

    /// Provider for `model`, its residency tier taken from the HW2 plan.
    public static func provider(model: LocalLLMModel = model, residency: ModelResidency = .shared,
                                plan: ResidencyPlan = ResidencyPlanStore.shared.plan) -> LlamaCppProvider {
        LlamaCppProvider(config: LlamaCppConfig(modelPath: model.localURL(), residencyKey: ResidencyKey.cleanup,
                                                tier: plan.tier(for: .cleanup) ?? .onDemand,
                                                estimatedBytes: model.residentBytes,
                                                deadline: CleanupStage.defaultDeadline),
                         displayName: "\(model.displayName) on this Mac", residency: residency)
    }

    /// Registers the provider in `routing` (and with the residency when the GGUF is installed) and
    /// returns the stage. `mode` is read per run, so a Settings change applies to the next dictation.
    public static func stage(routing: RoutingTable, settings: SettingsStore, model: LocalLLMModel = model,
                             residency: ModelResidency = .shared) -> CleanupStage {
        let llama = provider(model: model, residency: residency)
        routing.register(llama)
        if mode(settings: settings) != .off { Task { await syncResidency(llama, mode: mode(settings: settings), residency: residency) } }
        let generator = RoutingCleanupGenerator(table: routing, settings: settings,
                                                promptStyle: CleanupPromptStyle(rawValue: model.promptStyle) ?? .delimited)
        return CleanupStage(generator: generator, mode: { [weak settings] in
            settings.map(CleanupWiring.mode(settings:)) ?? .default
        })
    }

    /// Registered with the residency only while cleanup is on and the GGUF is installed, so D5's
    /// hotkey-down prewarm never loads a model the user switched off.
    public static func syncResidency(_ llama: LlamaCppProvider = provider(), mode: CleanupMode,
                                     residency: ModelResidency = .shared) async {
        if mode != .off, await llama.isAvailable() {
            await llama.registerWithResidency()
        } else {
            await residency.unload(ResidencyKey.cleanup)
            await residency.unregister(ResidencyKey.cleanup)
        }
    }

    /// `stages` with `cleanup` inserted right before the style pass (or appended when there is none).
    public static func inserting(_ cleanup: any PipelineStage, into stages: [any PipelineStage]) -> [any PipelineStage] {
        var out = stages
        out.insert(cleanup, at: out.firstIndex { $0.id == .style } ?? out.endIndex)
        return out
    }
}
