import Foundation
import Shared

// V5 D2 — Settings › AI cleanup: Off / Automatic (default) / Always.

public extension StageID {
    /// The cleanup LLM stage (D2). A `RoutingTable` stage like `act.planner` (§10).
    static let cleanup: StageID = "cleanup"
}

public enum CleanupMode: String, CaseIterable, Sendable, Codable {
    /// Rules only; the model is never loaded.
    case off
    /// The model runs only when the rules see a cue (`CleanupCueDetector`).
    case automatic
    /// The model runs on every dictation in a prose field.
    case always

    public static let `default`: CleanupMode = .automatic
    /// `SettingsStore` key (App) and the per-run override in `StageContext.extra` (Lab, tests).
    public static let settingsKey = "cleanup.mode"
    public static let contextKey = "cleanup.mode"

    public var title: String {
        switch self {
        case .off: return "Off"
        case .automatic: return "Automatic"
        case .always: return "Always"
        }
    }

    public var detail: String {
        switch self {
        case .off: return "Only the built-in rules tidy your text."
        case .automatic: return "A small model on this Mac fixes self-corrections, lists, numbers and long dictations. Everything else stays as the rules wrote it."
        case .always: return "The model checks every dictation. Slower, and it can change more."
        }
    }
}
