import Foundation
import Shared

// MARK: - V5 HW2 · RAM-aware defaults
//
// At first launch the app reads `ProcessInfo.physicalMemory` once, picks a `MemoryClass`, and from
// it a `ResidencyPlan`: which shared local LLM to use (Qwen3.5-2B / 4B — planner, Ask, notes; V5 CU8)
// and the `ResidencyTier` every later model registers with. The decision *model* is §O-d's choice
// (Kev); the plan only sets how it stays in memory — on an 8 GB Mac it is Laya, the light model,
// because Kev does not fit beside dictation and cleanup. The cleanup model itself is D2's pick (a
// small restraint-tuned model); the plan only gives it a key and a tier.
//
// How later model items use it (D2 cleanup, CU8 local LLM, O4 decision, CU2 computer use):
//
//     let plan = ResidencyPlanStore.shared.plan
//     guard let key = plan.key(for: .localLLM), let tier = plan.tier(for: .localLLM) else {
//         return   // not offered on this Mac — the UI says why (`plan.explanation`)
//     }
//     await ModelResidency.shared.register(key, tier: tier, estimatedBytes: …,
//                                          lighterAlternative: plan.lighterAlternative(for: key), …)
//
// Settings › Models shows the class and lets the user override it.

/// Well-known residency keys. Every module registers its model under one of these so that the plan,
/// the prewarmer (D5) and the HW3 lighter swap all name the same thing.
public enum ResidencyKey {
    /// The cleanup model (D2), whichever GGUF D2 picks. One key so D5 can prewarm it by name.
    public static let cleanup = "cleanup.llm"
    public static let localLLM2B = "llm.qwen3.5-2b"
    public static let localLLM4B = "llm.qwen3.5-4b"
    public static let decisionKev = "decide.kev"
    public static let decisionLaya = "decide.laya-e8"
    public static let computerUseS1 = "act.cua-s1-4b"
}

/// The three RAM classes V5 §HW names. Anything between snaps to the nearest one below.
public enum MemoryClass: String, CaseIterable, Codable, Sendable {
    /// 8 GB Macs: dictation + cleanup + Laya only.
    case compact
    /// 16 GB Macs.
    case standard
    /// 24 GB and up.
    case roomy

    public static func detect(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> MemoryClass {
        let gib = Double(physicalMemory) / Double(ResidencyBudget.gib)
        switch gib {
        case ..<12: return .compact
        case ..<20: return .standard
        default: return .roomy
        }
    }

    /// Settings copy: "8 GB Mac", "16 GB Mac", "24 GB or more".
    public var title: String {
        switch self {
        case .compact: return "8 GB Mac"
        case .standard: return "16 GB Mac"
        case .roomy: return "24 GB or more"
        }
    }
}

/// The model roles whose residency the plan decides. Dictation ASR is always `.always` (HW1).
public enum ResidencyRole: String, CaseIterable, Sendable {
    /// D2 cleanup model.
    case cleanup
    /// Shared local LLM: act planner, Ask, notes (CU8).
    case localLLM
    /// §O-d decision model.
    case decision
    /// CUA-S1-4B (CU2).
    case computerUse
}

/// Features the plan hides on a small Mac. The UI shows them disabled with `ResidencyPlan.explanation`.
public enum MemoryGatedFeature: String, CaseIterable, Codable, Sendable {
    /// Ambient act (wake-free "do this" turns; needs the computer-use model).
    case ambientAct
    /// Lip reading (camera + AVSR model).
    case lips
    /// Any 4B model (Qwen3.5-4B, CUA-S1-4B).
    case fourB
    /// The on-device shared LLM (planner / Ask / notes run on a cloud or local-server provider instead).
    case localLLM
}

public struct ResidencyPlan: Equatable, Sendable {
    public let memoryClass: MemoryClass
    public let cleanupTier: ResidencyTier
    /// nil → no on-device shared LLM on this Mac.
    public let localLLMKey: String?
    public let localLLMTier: ResidencyTier?
    public let decisionKey: String
    public let decisionTier: ResidencyTier
    /// nil → computer use is not offered on this Mac.
    public let computerUseKey: String?
    public let computerUseTier: ResidencyTier?
    /// ≥ 24 GB: load the computer-use model ahead of the first act turn ("kept warm").
    public let keepComputerUseWarm: Bool
    public let hidden: Set<MemoryGatedFeature>

    public static func `for`(_ memoryClass: MemoryClass) -> ResidencyPlan {
        switch memoryClass {
        case .compact:
            return ResidencyPlan(memoryClass: .compact, cleanupTier: .onDemand,
                                 localLLMKey: nil, localLLMTier: nil,
                                 decisionKey: ResidencyKey.decisionLaya, decisionTier: .onDemand,
                                 computerUseKey: nil, computerUseTier: nil, keepComputerUseWarm: false,
                                 hidden: [.ambientAct, .lips, .fourB, .localLLM])
        case .standard:
            return ResidencyPlan(memoryClass: .standard, cleanupTier: .onDemand,
                                 localLLMKey: ResidencyKey.localLLM2B, localLLMTier: .onDemand,
                                 decisionKey: ResidencyKey.decisionKev, decisionTier: .onDemand,
                                 computerUseKey: ResidencyKey.computerUseS1, computerUseTier: .exclusive,
                                 keepComputerUseWarm: false, hidden: [])
        case .roomy:
            return ResidencyPlan(memoryClass: .roomy, cleanupTier: .onDemand,
                                 localLLMKey: ResidencyKey.localLLM4B, localLLMTier: .onDemand,
                                 decisionKey: ResidencyKey.decisionKev, decisionTier: .always,
                                 computerUseKey: ResidencyKey.computerUseS1, computerUseTier: .onDemand,
                                 keepComputerUseWarm: true, hidden: [])
        }
    }

    /// The key a role registers under, or nil when the role is not offered on this Mac.
    public func key(for role: ResidencyRole) -> String? {
        switch role {
        case .cleanup: return ResidencyKey.cleanup
        case .localLLM: return localLLMKey
        case .decision: return decisionKey
        case .computerUse: return computerUseKey
        }
    }

    /// The tier a role registers with, or nil when the role is not offered on this Mac.
    public func tier(for role: ResidencyRole) -> ResidencyTier? {
        switch role {
        case .cleanup: return cleanupTier
        case .localLLM: return localLLMTier
        case .decision: return decisionTier
        case .computerUse: return computerUseTier
        }
    }

    public func isHidden(_ feature: MemoryGatedFeature) -> Bool { hidden.contains(feature) }

    /// HW3 swap targets (Kev → Laya e8, 4B → 2B). Pass as `lighterAlternative` when registering.
    public func lighterAlternative(for key: String) -> String? {
        switch key {
        case ResidencyKey.decisionKev: return ResidencyKey.decisionLaya
        case ResidencyKey.localLLM4B: return ResidencyKey.localLLM2B
        default: return nil
        }
    }

    /// D5 — what to load when the dictation hotkey goes down: the cleanup LLM.
    public var prewarmKeys: [String] { [ResidencyKey.cleanup] }

    /// Human names for Settings.
    public var localLLMName: String? {
        switch localLLMKey {
        case ResidencyKey.localLLM4B?: return "Qwen3.5-4B"
        case ResidencyKey.localLLM2B?: return "Qwen3.5-2B"
        default: return nil
        }
    }
    public var decisionModelName: String { decisionKey == ResidencyKey.decisionKev ? "Kev" : "Laya" }

    /// One-line summary under the tier picker.
    public var summary: String {
        switch memoryClass {
        case .compact:
            return "Dictation, cleanup and Laya for decisions."
        case .standard:
            return "Qwen3.5-2B on this Mac · Kev loads when needed · computer use runs on its own."
        case .roomy:
            return "Qwen3.5-4B on this Mac · Kev stays loaded · computer use is kept warm."
        }
    }

    /// Why features are missing, or nil when nothing is hidden.
    public var explanation: String? {
        guard !hidden.isEmpty else { return nil }
        return "With 8 GB of memory, ambient actions, lip reading and the on-device assistant model are off — "
            + "they need more memory than is left beside dictation. Ask and notes can still use a provider "
            + "you connect. You can pick a larger tier, but the Mac may slow down."
    }
}

/// Persists the first-launch class and the user's override. `UserDefaults`-backed; inject one in tests.
public final class ResidencyPlanStore: @unchecked Sendable {
    public static let detectedKey = "residency.memoryClass.detected"
    public static let overrideKey = "residency.memoryClass.override"
    /// Posted (object: the store) when the override changes. Models registered afterwards use the new
    /// plan; already-loaded models keep their tier until they next unload.
    public static let didChangeNotification = Notification.Name("VoicePlus.ResidencyPlanStore.didChange")

    public static let shared = ResidencyPlanStore()

    private let defaults: UserDefaults
    private let physicalMemory: UInt64
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard,
                physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) {
        self.defaults = defaults
        self.physicalMemory = physicalMemory
    }

    /// First launch: record the detected class once. Returns true when this call recorded it.
    /// Later launches keep the recorded class (a RAM upgrade is picked up by "Automatic" re-detecting
    /// only if the user resets — see `resetToDetected`).
    @discardableResult
    public func applyFirstLaunchDefaults() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard defaults.string(forKey: Self.detectedKey).flatMap(MemoryClass.init(rawValue:)) == nil else { return false }
        let detected = MemoryClass.detect(physicalMemory: physicalMemory)
        defaults.set(detected.rawValue, forKey: Self.detectedKey)
        Log.engine.notice("residency: first launch — \(detected.rawValue) plan for \(self.physicalMemory / 1_000_000) MB RAM")
        return true
    }

    /// The class recorded at first launch (recording it now if this is first launch).
    public var detectedClass: MemoryClass {
        applyFirstLaunchDefaults()
        return defaults.string(forKey: Self.detectedKey).flatMap(MemoryClass.init(rawValue:))
            ?? MemoryClass.detect(physicalMemory: physicalMemory)
    }

    /// The user's choice in Settings › Models; nil = automatic.
    public var overrideClass: MemoryClass? {
        defaults.string(forKey: Self.overrideKey).flatMap(MemoryClass.init(rawValue:))
    }

    public func setOverride(_ memoryClass: MemoryClass?) {
        guard memoryClass != overrideClass else { return }
        if let memoryClass { defaults.set(memoryClass.rawValue, forKey: Self.overrideKey) }
        else { defaults.removeObject(forKey: Self.overrideKey) }
        Log.engine.notice("residency: plan override \(memoryClass?.rawValue ?? "automatic")")
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    /// Re-detect from the current RAM (after a hardware change) and clear the override.
    public func resetToDetected() {
        defaults.set(MemoryClass.detect(physicalMemory: physicalMemory).rawValue, forKey: Self.detectedKey)
        setOverride(nil)
    }

    public var effectiveClass: MemoryClass { overrideClass ?? detectedClass }

    public var plan: ResidencyPlan { .for(effectiveClass) }
}
