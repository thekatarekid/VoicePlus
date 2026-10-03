import Engine
import Foundation
import Providers
import Shared

// MARK: - V5 CU8 · one shipped local instruct model, shared by every generative stage
//
// Qwen3.5-2B (16 GB Macs) or Qwen3.5-4B (≥ 24 GB), Q4_K_M GGUF, on D2's llama.cpp runtime. One
// provider (`SharedLocalLLMProvider`) serves the act planner, meeting notes and Ask, Hinglish/style
// cleanup, note follow-ups (N5) and "Why did it write that?" (I3), so there is one download and one
// resident model. §10:
// - loaded only through `ModelResidency` (the inner `LlamaCppProvider` registers under the HW2
//   plan's key — `llm.qwen3.5-2b` / `llm.qwen3.5-4b` — with the plan's tier and HW3 lighter
//   alternative, 4B → 2B);
// - called only through `RoutingTable` (`SharedLocalLLM.complete` pins the provider for the stage
//   and runs `table.complete`).
// Nothing downloads on its own: the GGUF arrives only from the Settings › Computer use button.

extension ComputerUseSettings {
    /// The GGUF the shared model runs: the user's pick, else the memory tier's (nil on an 8 GB Mac,
    /// where the plan offers no on-device shared LLM).
    /// X5 — Automatic prefers the model the user downloaded (onboarding / Settings), then the plan's.
    public static func resolvedPlannerModel(_ store: SettingsStore?,
                                            plan: ResidencyPlan = ResidencyPlanStore.shared.plan,
                                            downloaded: () -> LocalLLMModel? = { EditModels.manager.activeModel }) -> LocalLLMModel? {
        switch plannerModel(store) {
        case .qwen2B: return LocalLLMCatalog.qwen35_2B
        case .qwen4B: return LocalLLMCatalog.qwen35_4B
        case .automatic: return downloaded() ?? LocalLLMCatalog.sharedDefault(localLLMKey: plan.localLLMKey)
        }
    }

    /// The residency key a shared model registers under (HW2 names).
    public static func residencyKey(for model: LocalLLMModel) -> String {
        model.id == LocalLLMCatalog.qwen35_4B.id ? ResidencyKey.localLLM4B : ResidencyKey.localLLM2B
    }
}

/// X5 — the app's one model manager (Qwen3.5-2B / 4B for edits; onboarding, notch offer, Settings).
public enum EditModels {
    public static let manager = LocalModelManager()
    public static let offerPolicy = ModelOfferPolicy()
    /// H16 — unload the edit model after ~2 min idle.
    public static let idleUnloadAfter: TimeInterval = 120
}

extension ComputerUseSettings {

    /// V5 CU9 — one 4B at a time. Where the plan runs CUA-S1-4B `.exclusive` (16 GB), a 4B planner the
    /// user picked is `.exclusive` too, so the two are never resident together (`ModelResidency`
    /// refuses the second; CUA-S1 queues behind the planner, `ResidentCuaS1`). Otherwise the plan's
    /// shared-LLM tier.
    public static func plannerTier(for model: LocalLLMModel, plan: ResidencyPlan) -> ResidencyTier {
        if model.id == LocalLLMCatalog.qwen35_4B.id, plan.tier(for: .computerUse) == .exclusive { return .exclusive }
        return plan.tier(for: .localLLM) ?? .onDemand
    }
}

/// The shared model as a routable provider. The model is resolved per call (the planner-model pick
/// can change in Settings while the app runs); one `LlamaCppProvider` per GGUF is kept.
public final class SharedLocalLLMProvider: TextGenerator, @unchecked Sendable {
    public static let providerID: ProviderID = "local.llamacpp.shared"
    /// N5 note → reminder/draft and I3 explanations, named here so their consumers route to this model.
    public static let notesFollowUpStage: StageID = "notes.followup"
    public static let explainStage: StageID = "explain.why"
    /// Every stage this model is registered for (CU8).
    /// H13 — plus LLM edits: rewrite (`transform`) and questions about a selection (`question`).
    public static let servedStages: Set<StageID> = [ProviderPlanner.stage, .meetingNotes, .meetingAsk, .style,
                                                    notesFollowUpStage, explainStage, "transform", "question"]
    /// Planner/notes/Ask: a step plan or a few paragraphs, never an essay.
    public static let maxTokens = 1_024
    public static let deadline: TimeInterval = 90

    public let id: ProviderID = SharedLocalLLMProvider.providerID
    public let capabilities: ProviderCapabilities = [.pipeline]
    public let costClass: CostClass = .free
    public let privacyClass: PrivacyClass = .onDevice

    private let resolveModel: @Sendable () -> LocalLLMModel?
    private let makeInner: @Sendable (LocalLLMModel) -> any TextGenerator
    private let lock = NSLock()
    private var inners: [String: any TextGenerator] = [:]

    public init(resolveModel: @escaping @Sendable () -> LocalLLMModel?,
                makeInner: @escaping @Sendable (LocalLLMModel) -> any TextGenerator) {
        self.resolveModel = resolveModel
        self.makeInner = makeInner
    }

    /// The production provider: model from Settings/plan, llama.cpp under `ModelResidency`.
    public static func live(settings: SettingsStore, residency: ModelResidency = .shared,
                            planStore: ResidencyPlanStore = .shared) -> SharedLocalLLMProvider {
        let box = SettingsBox(settings)
        return SharedLocalLLMProvider(
            resolveModel: { ComputerUseSettings.resolvedPlannerModel(box.settings, plan: planStore.plan) },
            makeInner: { model in
                let plan = planStore.plan
                let key = ComputerUseSettings.residencyKey(for: model)
                return LlamaCppProvider(
                    config: LlamaCppConfig(modelPath: model.localURL(), residencyKey: key,
                                           tier: ComputerUseSettings.plannerTier(for: model, plan: plan),
                                           estimatedBytes: model.residentBytes, maxTokens: maxTokens,
                                           deadline: deadline, lighterAlternative: plan.lighterAlternative(for: key),
                                           sampling: .qwenNonThinking,                       // H14
                                           idleUnloadAfter: EditModels.idleUnloadAfter,      // H16
                                           refuseUnderCriticalPressure: true),               // H16
                    displayName: "\(model.displayName) on this Mac", residency: residency)
            })
    }

    public var model: LocalLLMModel? { resolveModel() }
    public var displayName: String { model.map { "\($0.displayName) on this Mac" } ?? "Local model on this Mac" }

    func inner() -> (any TextGenerator)? {
        guard let model = resolveModel() else { return nil }
        return lock.withLock {
            if let existing = inners[model.id] { return existing }
            let made = makeInner(model)
            inners[model.id] = made
            return made
        }
    }

    public func isAvailable() async -> Bool {
        guard let inner = inner() else { return false }
        return await inner.isAvailable()
    }

    public func generate(prompt: String, system: String, stage: StageID) async throws
        -> (text: String, bytesOut: Int, bytesIn: Int, host: String) {
        guard Self.servedStages.contains(stage) else { throw ProviderError.unavailable("not a shared-LLM stage: \(stage)") }
        guard let inner = inner() else { throw ProviderError.unavailable("no on-device shared model on this Mac") }
        return try await inner.generate(prompt: prompt, system: system, stage: stage)
    }
}

/// The local route the act planner uses when no provider is pinned (`ProviderPlanner`).
public protocol LocalPlannerRouting: Sendable {
    /// Runtime linked and the GGUF on disk. Never loads or downloads anything.
    func isAvailable() async -> Bool
    func complete(stage: StageID, system: String, user: String) async throws -> String
}

/// Holds the routing table the shared model is registered in. Installed once at launch (through
/// `MeetingIntelligenceWiring.install`, which already runs at the composition root).
public final class SharedLocalLLM: LocalPlannerRouting, @unchecked Sendable {
    public static let shared = SharedLocalLLM()

    private let lock = NSLock()
    private var table: RoutingTable?
    private var provider: SharedLocalLLMProvider?

    public init() {}

    public init(table: RoutingTable, provider: SharedLocalLLMProvider) {
        install(table: table, provider: provider)
    }

    public func install(table: RoutingTable, provider: SharedLocalLLMProvider) {
        table.register(provider)
        lock.withLock { self.table = table; self.provider = provider }
    }

    public var isInstalled: Bool { lock.withLock { table != nil } }
    public var installedProvider: SharedLocalLLMProvider? { lock.withLock { provider } }

    /// The route for `ProviderPlanner`, or nil before launch wiring ran (tests, the Lab).
    public var plannerRoute: (any LocalPlannerRouting)? { isInstalled ? self : nil }

    public func isAvailable() async -> Bool {
        guard let provider = lock.withLock({ provider }) else { return false }
        return await provider.isAvailable()
    }

    /// Synchronous "is the GGUF here" for disclosures (meeting Ask route).
    public var isModelOnDisk: Bool {
        guard let model = lock.withLock({ provider })?.model else { return false }
        return LlamaCppEngine.runtimeAvailable && FileManager.default.fileExists(atPath: model.localURL().path)
    }

    /// One generation through the routing table with the shared model pinned for `stage`. A reply
    /// from anything else in the local chain (the rules fallback, the cleanup specialist) is not a
    /// planner reply and counts as unavailable.
    public func complete(stage: StageID, system: String, user: String) async throws -> String {
        guard let table = lock.withLock({ table }) else { throw ProviderError.unavailable("shared LLM not installed") }
        var ctx = StageContext()
        ctx.extra[PromptBuilder.systemOverrideKey] = system
        ctx.extra[PromptBuilder.userOverrideKey] = user
        table.setChoice(.provider(SharedLocalLLMProvider.providerID), for: stage)
        let span = TranscriptSpan(text: user, confidence: 1, audioRange: 0...0, provenance: [.asr])
        let outcome = try await table.complete(stage: stage, spans: [span], context: ctx, purpose: "local:\(stage.rawValue)")
        guard outcome.provider == SharedLocalLLMProvider.providerID else {
            throw ProviderError.unavailable("shared local model did not answer \(stage.rawValue)")
        }
        return outcome.completion.spans.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

// MARK: - Install status for Settings › Computer use

/// What the planner-model row says, and its one action.
public enum PlannerModelStatus: Equatable, Sendable {
    /// 8 GB plan and no explicit pick: no on-device model; a provider can still plan.
    case notOffered
    case notDownloaded(LocalLLMModel)
    case downloading(LocalLLMModel)
    case installed(LocalLLMModel)
    case failed(LocalLLMModel, String)

    public var line: String {
        switch self {
        case .notOffered:
            return "This Mac's memory tier has no on-device planner. Pin a provider above, or pick a model."
        case .notDownloaded(let m): return "\(m.displayName) — \(m.sizeLabel) to download. Nothing downloads until you click."
        case .downloading(let m): return "Downloading \(m.displayName)…"
        case .installed(let m): return "\(m.displayName) — on this Mac."
        case .failed(let m, _): return "\(m.displayName) didn't download. Try again."
        }
    }

    public var canDownload: Bool {
        switch self {
        case .notDownloaded, .failed: return true
        default: return false
        }
    }
}

@MainActor
public final class PlannerModelInstaller: ObservableObject {
    @Published public private(set) var status: PlannerModelStatus = .notOffered
    private let store: SettingsStore
    private let downloader: LocalLLMDownloader
    private let plan: () -> ResidencyPlan

    public init(store: SettingsStore, downloader: LocalLLMDownloader = LocalLLMDownloader(),
                plan: @escaping () -> ResidencyPlan = { ResidencyPlanStore.shared.plan }) {
        self.store = store
        self.downloader = downloader
        self.plan = plan
        refresh()
    }

    public func refresh() {
        guard let model = ComputerUseSettings.resolvedPlannerModel(store, plan: plan()) else { status = .notOffered; return }
        if case .downloading(let m) = status, m == model { return }
        status = downloader.isInstalled(model) ? .installed(model) : .notDownloaded(model)
    }

    /// The user's click. SHA-verified; nothing lands at the final path unless the hash matches.
    public func download() {
        guard status.canDownload, let model = ComputerUseSettings.resolvedPlannerModel(store, plan: plan()) else { return }
        status = .downloading(model)
        let downloader = self.downloader
        Task { [weak self] in
            do {
                try await downloader.download(model)
                await MainActor.run { self?.status = .installed(model) }
            } catch {
                await MainActor.run { self?.status = .failed(model, "\(error)") }
            }
        }
    }
}
