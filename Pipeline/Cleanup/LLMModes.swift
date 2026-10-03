import Foundation
import Shared

// MARK: - X4 · four independent LLM modes (owner decisions, round 4)
//
// 1. Fast path only — default ON: rules only, the model never loads.
// 2. Per-app Polish — default OFF: every dictation into a listed app gets the model.
// 3. Automatic polish when unsure — default OFF: the model runs when the rules see a cue
//    (self-correction, list, numbers, long dictation: `CleanupCueDetector`).
// 4. LLM on every dictation — default OFF: the model checks every prose dictation (+~1–2.5 s).
// Modes 2–4 are independent switches. "Fast path only" is ON exactly when 2–4 are all OFF, and
// switching it ON turns 2–4 OFF. The rules (fast path) always run first in every mode, and the
// existing skips (code, terminal, secure field, Verbatim/Exact) still apply.

public struct LLMModes: Equatable, Sendable, Codable {
    public var perAppPolish: Bool
    /// Bundle IDs that get Polish when `perAppPolish` is on.
    public var polishApps: Set<String>
    public var autoPolishWhenUnsure: Bool
    public var everyDictation: Bool

    public init(perAppPolish: Bool = false, polishApps: Set<String> = [], autoPolishWhenUnsure: Bool = false,
                everyDictation: Bool = false) {
        self.perAppPolish = perAppPolish
        self.polishApps = polishApps
        self.autoPolishWhenUnsure = autoPolishWhenUnsure
        self.everyDictation = everyDictation
    }

    public static let `default` = LLMModes()
    /// `SettingsStore` key, JSON-encoded.
    public static let settingsKey = "llm.modes"
    /// Wall-clock budget when the model checks a whole dictation (modes 2 and 4).
    public static let polishDeadline: TimeInterval = 2.5

    public var fastPathOnly: Bool { !perAppPolish && !autoPolishWhenUnsure && !everyDictation }

    /// Switching "Fast path only" ON turns every LLM mode off (OFF alone changes nothing).
    public mutating func setFastPathOnly(_ on: Bool) {
        guard on else { return }
        perAppPolish = false; autoPolishWhenUnsure = false; everyDictation = false
    }

    /// The cleanup mode for one dictation into `bundleID`.
    public func cleanupMode(bundleID: String?) -> CleanupMode {
        if everyDictation { return .always }
        if perAppPolish, let b = bundleID, polishApps.contains(b) { return .always }
        if autoPolishWhenUnsure { return .automatic }
        return .off
    }

    public func deadline(for mode: CleanupMode) -> TimeInterval {
        mode == .always ? Self.polishDeadline : CleanupStage.defaultDeadline
    }

    public var encoded: String {
        (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    public static func decode(_ s: String?) -> LLMModes? {
        guard let s, let d = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(LLMModes.self, from: d)
    }
}
