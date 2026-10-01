import Foundation
import Shared

// MARK: - V5 CU2 · CUA-S1 catalog + residency
//
// Two models, both Apache-2.0 / MIT, both on demand (nothing downloads until the user asks):
// - `cua-s1-4b-coreml` — the text decoder `text/L1024-gptq` (4 × ~688 MB parts, GPTQ int4 MLP +
//   int8 linears) plus the host-side tied embedding table `embeddings.f16` (1.27 GB) and
//   `tokenizer.json`: ~4.0 GB on disk, `.exclusive` in `ModelResidency` (HW1 / CU9: loaded for an
//   act turn, never beside another 4B). GPU only (`cpuAndGPU`); ~0.7 s per decision on M5 Pro.
//   Vendor GUI-360 text accuracy (613 tasks): 85.5 % for gptq.
// - `cua-s1-forms-coreml` — 706 K params, ~0.9 ms per decision on the ANE; scores entity → field
//   options (`fill Email: …`, `check`, `click`, `skip`) for `ActionKind.fillField`.

public struct CuaS1ModelEntry: Equatable, Sendable {
    public var id: String
    public var hfRepo: String
    /// Repository paths that make up the install.
    public var files: [String]
    public var bytes: Int64
    /// RAM while loaded, for the residency budget.
    public var residentBytes: Int64
    public var tier: ResidencyTier
    public var residencyKey: String
    public var license: String
}

public enum CuaS1Catalog {
    /// = `Engine.ResidencyKey.computerUseS1` (HW2); Actions does not import Engine.
    public static let residencyKey = "act.cua-s1-4b"
    public static let formsResidencyKey = "act.cua-s1-forms"

    public static let fourBText = CuaS1ModelEntry(
        id: "cua-s1-4b-coreml", hfRepo: "FluidInference/cua-s1-4b-coreml",
        files: ["text/L1024-gptq/", "embeddings.f16", "tokenizer.json", "config.json"],
        bytes: 4_028_547_210 + 12_807_982, residentBytes: 3_900_000_000,
        tier: .exclusive, residencyKey: residencyKey, license: "Apache-2.0")

    public static let forms = CuaS1ModelEntry(
        id: "cua-s1-forms-coreml", hfRepo: "FluidInference/cua-s1-forms-coreml",
        files: ["cua_s1_forms_fp16_options32.mlmodelc/"],
        bytes: 3_000_000, residentBytes: 20_000_000,
        tier: .onDemand, residencyKey: formsResidencyKey, license: "MIT")

    /// The variant `CuaS1FourBManager` loads: `.init(modality: .text, variant: "gptq")`.
    public static let modality = "text"
    public static let variant = "gptq"
    public static let variantDirectory = "text/L1024-gptq"
    /// Longest prompt the loaded bucket accepts.
    public static let maxPromptTokens = 1024

    public static let all: [CuaS1ModelEntry] = [fourBText, forms]
}

/// A `CuaS1Deciding` that lives in `ModelResidency`: every decision runs inside `withModel`, so the
/// weights load on first use, count against the one budget, and (as `.exclusive`) evict on-demand
/// models first and are refused while another exclusive model is resident (§10, HW1).
///
/// V5 CU9 — one 4B at a time, queued rather than failed. When the load is refused because another
/// `.exclusive` model (the 4B planner, a refinement pass) is resident, the decision waits: while that
/// model is in use (pinned) it polls; once it is idle it is unloaded (`ResidencyReason.exclusive`) and
/// CUA-S1 loads. A refusal for budget (something pinned is holding memory) waits the same way. After
/// `queueTimeout` the refusal is thrown and the act router hands the goal to the planner.
public final class ResidentCuaS1: CuaS1Deciding, @unchecked Sendable {
    public let residencyKey: String
    private let residency: ModelResidency
    private let backend: any CuaS1Backend
    /// Longest wait for another exclusive model to finish (CU9).
    public let queueTimeout: TimeInterval
    /// Poll interval while queued.
    public let pollInterval: TimeInterval
    private let now: @Sendable () -> Date

    public init(backend: any CuaS1Backend, residency: ModelResidency = .shared,
                residencyKey: String = CuaS1Catalog.residencyKey,
                queueTimeout: TimeInterval = 30, pollInterval: TimeInterval = 0.1,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.backend = backend
        self.residency = residency
        self.residencyKey = residencyKey
        self.queueTimeout = max(0, queueTimeout)
        self.pollInterval = max(0.001, pollInterval)
        self.now = now
    }

    /// Register under the HW2 plan's tier (`.exclusive` on 16 GB, `.onDemand` + warm on ≥ 24 GB).
    public func register(tier: ResidencyTier = CuaS1Catalog.fourBText.tier,
                         estimatedBytes: Int64 = CuaS1Catalog.fourBText.residentBytes) async {
        if await residency.isRegistered(residencyKey) { return }
        let backend = self.backend
        await residency.register(residencyKey, tier: tier, estimatedBytes: estimatedBytes,
                                 lighterAlternative: nil, owner: "act",
                                 load: { try await backend.load() },
                                 unload: { await backend.unload() })
    }

    public func decide(_ state: CuaS1State) async throws -> CuaS1Decision {
        await register()
        let backend = self.backend
        return try await queued { try await self.residency.withModel(self.residencyKey) { try await backend.decide(state) } }
    }

    /// ≥ 24 GB plan (kept warm): load ahead of the first decision of an act turn.
    public func prewarm() async throws {
        await register()
        try await queued { try await self.residency.acquire(self.residencyKey) }
    }

    /// CU9: unload after the act turn.
    public func release() async { await residency.unload(residencyKey) }

    /// Run `body`; on an exclusive / budget refusal wait for the turn (see the type comment).
    private func queued<T>(_ body: () async throws -> T) async throws -> T {
        let deadline = now().addingTimeInterval(queueTimeout)
        while true {
            do {
                return try await body()
            } catch let refusal as ResidencyError {
                guard now() < deadline, try await waitTurn(after: refusal) else { throw refusal }
            }
        }
    }

    /// True → try again. Unloads the other exclusive model once it is idle.
    private func waitTurn(after refusal: ResidencyError) async throws -> Bool {
        switch refusal {
        case .exclusiveConflict(_, let other):
            let entry = await residency.snapshot().entries.first { $0.key == other }
            guard let entry, entry.resident else { return true }   // already gone
            if entry.pinned {
                try await Task.sleep(nanoseconds: UInt64(pollInterval * 1e9))
            } else {
                await residency.unload(other, reason: .exclusive)
            }
            return true
        case .overBudget:
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1e9))
            return true
        default:
            return false
        }
    }
}

/// The backend this build ships for the 4B chooser: FluidUse at the J6 pin has no
/// `CuaS1FourBManager`, so loading reports `runtimeMissing` (the act path falls back to the
/// planner). Replace with the FluidUse adapter when the pin moves.
public actor UnavailableCuaS1Backend: CuaS1Backend {
    public init() {}
    public var isLoaded: Bool { false }
    public func load() async throws { throw CuaS1Error.runtimeMissing }
    public func unload() {}
    public func decide(_ state: CuaS1State) async throws -> CuaS1Decision { throw CuaS1Error.runtimeMissing }
}
