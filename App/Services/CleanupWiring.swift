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

    /// X4 — the four LLM modes. Absent → defaults (fast path only), except a pre-X4 explicit
    /// "Always" choice, which carries over as "LLM on every dictation".
    public static func llmModes(settings: SettingsStore) -> LLMModes {
        if let m = LLMModes.decode(settings.string(LLMModes.settingsKey)) { return m }
        if settings.string(CleanupMode.settingsKey) == CleanupMode.always.rawValue { return LLMModes(everyDictation: true) }
        return .default
    }

    public static func setLLMModes(_ modes: LLMModes, settings: SettingsStore) {
        settings.set(modes.encoded, for: LLMModes.settingsKey)
    }

    /// The headline mode (residency registration, Settings detail): off on the fast path only,
    /// always when every dictation gets the model, else automatic (per-app / when unsure).
    public static func mode(settings: SettingsStore) -> CleanupMode {
        let m = llmModes(settings: settings)
        if m.fastPathOnly { return .off }
        return m.everyDictation ? .always : .automatic
    }

    /// Provider for `model`, its residency tier taken from the HW2 plan.
    public static func provider(model: LocalLLMModel = model, residency: ModelResidency = .shared,
                                plan: ResidencyPlan = ResidencyPlanStore.shared.plan) -> LlamaCppProvider {
        LlamaCppProvider(config: LlamaCppConfig(modelPath: model.localURL(), residencyKey: ResidencyKey.cleanup,
                                                tier: plan.tier(for: .cleanup) ?? .onDemand,
                                                estimatedBytes: model.residentBytes,
                                                // X4 — the stage's race enforces the per-mode deadline
                                                // (0.5 s when unsure, ~2.5 s for a whole-dictation polish).
                                                deadline: LLMModes.polishDeadline,
                                                servedStages: [.cleanup]),
                         displayName: "\(model.displayName) on this Mac", residency: residency)
    }

    /// Registers the provider in `routing` (and with the residency when the GGUF is installed) and
    /// returns the stage. `mode` is read per run, so a Settings change applies to the next dictation.
    public static func stage(routing: RoutingTable, settings: SettingsStore, model: LocalLLMModel = model,
                             residency: ModelResidency = .shared) -> CleanupStage {
        let llama = provider(model: model, residency: residency)
        routing.register(llama)
        if mode(settings: settings) != .off { Task { await syncResidency(llama, mode: mode(settings: settings), residency: residency) } }
        // V5 LANG1 — a non-English turn routes to CU8's multilingual model (LanguageCleanup.swift).
        let generator = LanguageCleanupWiring.wrap(
            RoutingCleanupGenerator(table: routing, settings: settings,
                                    promptStyle: CleanupPromptStyle(rawValue: model.promptStyle) ?? .delimited),
            routing: routing, settings: settings)
        var stage = CleanupStage(generator: generator, mode: { [weak settings] in
            settings.map(CleanupWiring.mode(settings:)) ?? .off
        })
        // X4 — per run: every dictation / per-app Polish (this app) / when unsure / fast path only.
        stage.modeResolver = { [weak settings] ctx in
            guard let settings else { return .off }
            return CleanupWiring.llmModes(settings: settings).cleanupMode(bundleID: ctx.appBundleID)
        }
        stage.deadlineForMode = { LLMModes.default.deadline(for: $0) }
        return stage
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

    /// Context Writer — `stages` with the writer at cleanup's position: right before the cleanup
    /// stage, else where cleanup would go (before style). On a run the writer handles
    /// (`writer.active`) the cleanup stage skips with `writer`; otherwise the writer passes through.
    public static func insertingWriter(_ writer: any PipelineStage, into stages: [any PipelineStage]) -> [any PipelineStage] {
        guard let at = stages.firstIndex(where: { $0.id == .cleanup }) else { return inserting(writer, into: stages) }
        var out = stages
        out.insert(writer, at: at)
        return out
    }
}
