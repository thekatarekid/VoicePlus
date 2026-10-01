import Actions
import Foundation
import Shared

// MARK: - V5 CU1 · Settings › Computer use — stored values, defaults and runtime application
//
// One place for everything the Computer use page writes. Enable and the act key are not new
// settings: they are `ActKeySettings` and `HotkeyService.actBindingDefaultsKey`, written through
// `GeneralSettingsViewModel.actKey` so Shortcuts and this page can never disagree. The provider row
// is `routing.act.planner` (`ModelsSettingsViewModel`). Everything else is new and lives under
// `computerUse.*`. `ComputerUseSettings.apply` hands the values to the running act stack; it is
// re-read at the start of every act turn, so a change takes effect on the next press of the key.

public enum ComputerUseSettings {
    public static let plannerModelKey = "computerUse.plannerModel"
    public static let timeoutKey = "computerUse.timeoutSeconds"
    public static let reversibleKey = "computerUse.consent.reversible"
    public static let semiKey = "computerUse.consent.semi"
    public static let showPlanChipsKey = "computerUse.showPlanChips"

    /// The agent's wall-clock budget for one goal (`NativeAgentBackend.Config.timeout`).
    public static let defaultTimeout: TimeInterval = 60
    public static let timeoutRange: ClosedRange<TimeInterval> = 15...300
    public static let timeoutStep: TimeInterval = 15

    /// Which local model plans (CU8). Automatic follows the memory tier (16 GB → 2B, ≥ 24 GB → 4B).
    public enum PlannerModel: String, CaseIterable, Identifiable, Sendable {
        case automatic, qwen2B, qwen4B
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .automatic: return "Automatic (by memory)"
            case .qwen2B: return "Qwen3.5-2B"
            case .qwen4B: return "Qwen3.5-4B"
            }
        }
    }

    // MARK: Reads (defaults included)

    public static func isEnabled(_ store: SettingsStore?) -> Bool { ActKeySettings.isEnabled(store) }

    public static func plannerModel(_ store: SettingsStore?) -> PlannerModel {
        store?.string(plannerModelKey).flatMap(PlannerModel.init(rawValue:)) ?? .automatic
    }

    public static func timeout(_ store: SettingsStore?) -> TimeInterval {
        guard let raw = store?.string(timeoutKey), let v = Double(raw), v.isFinite else { return defaultTimeout }
        return clampTimeout(v)
    }

    public static func clampTimeout(_ seconds: TimeInterval) -> TimeInterval {
        let bounded = min(timeoutRange.upperBound, max(timeoutRange.lowerBound, seconds))
        return (bounded / timeoutStep).rounded() * timeoutStep
    }

    public static func consentPolicy(_ store: SettingsStore?) -> ConsentPolicy {
        ConsentPolicy(
            reversible: store?.string(reversibleKey).flatMap(ConsentPolicy.ReversibleHandling.init(rawValue:)) ?? .run,
            semi: store?.string(semiKey).flatMap(ConsentPolicy.SemiHandling.init(rawValue:)) ?? .undoToast)
    }

    public static func showsPlanChips(_ store: SettingsStore?) -> Bool { store?.bool(showPlanChipsKey) ?? true }

    // MARK: Writes

    public static func setPlannerModel(_ m: PlannerModel, store: SettingsStore?) {
        store?.set(m == .automatic ? nil : m.rawValue, for: plannerModelKey)
    }
    public static func setTimeout(_ seconds: TimeInterval, store: SettingsStore?) {
        guard seconds.isFinite else { return }
        store?.set(String(clampTimeout(seconds)), for: timeoutKey)
    }
    public static func setConsentPolicy(_ p: ConsentPolicy, store: SettingsStore?) {
        store?.set(p.reversible.rawValue, for: reversibleKey)
        store?.set(p.semi.rawValue, for: semiKey)
    }
    public static func setShowsPlanChips(_ on: Bool, store: SettingsStore?) { store?.set(on, for: showPlanChipsKey) }

    /// Push the stored values into the live act stack (called at the start of each act turn).
    public static func apply(_ store: SettingsStore?, consent: ConsentEngine, agent: any AgentActionBackend) {
        consent.policy = consentPolicy(store)
        if let native = agent as? NativeAgentBackend {
            native.config.timeout = timeout(store)
            native.showsPlanChips = showsPlanChips(store)
        }
    }
}

/// Copy for the page, in one place so tests can hold the words.
public enum ComputerUseCopy {
    public static let title = "Computer use"
    public static let subtitle = "Do things on this Mac by voice. Local first; nothing is sent unless you choose a provider."
    public static let enableTitle = "Computer use"
    public static let enableDetail = "Hold the act key and say what to do. Off by default."
    public static let keyTitle = "Act key"
    public static let keyDetail = "Must be a different key from dictation."
    public static let providerTitle = "Planner runs on"
    public static let providerDetail = "Auto uses the model on this Mac. Pin Ollama, LM Studio, a CLI, ChatGPT or a key to use it instead."
    public static let modelTitle = "Planner model"
    public static let timeoutTitle = "Give up after"
    public static let timeoutDetail = "How long one request may run before it stops and rolls back what it can."
    public static let consentTitle = "Before acting"
    public static let reversibleTitle = "Easy to undo (focus, scroll, open)"
    public static let semiTitle = "Undoable (archive, move, close)"
    public static let irreversibleTitle = "Can't be undone (send, delete, pay)"
    public static let irreversibleDetail = "Always asks. This one is not a setting."
    public static let chipsTitle = "Show plan chips"
    public static let chipsDetail = "Show each step in the pill while it runs. Off still shows anything that needs your OK."
    public static let footnote = "Computer use reads the accessibility tree, never the screen's pixels."

    public static func seconds(_ s: TimeInterval) -> String { "\(Int(s)) s" }

    public static func title(_ h: ConsentPolicy.ReversibleHandling) -> String {
        switch h {
        case .run: return "Just do it"
        case .undoToast: return "Do it, offer undo"
        case .confirm: return "Ask first"
        }
    }
    public static func title(_ h: ConsentPolicy.SemiHandling) -> String {
        switch h {
        case .undoToast: return "Do it, offer undo"
        case .confirm: return "Ask first"
        }
    }

    public static func providerTitle(_ choice: ProviderChoice) -> String {
        switch choice {
        case .auto: return "Auto (this Mac)"
        case .local: return "This Mac only"
        case .provider(let p): return p
        }
    }
}
