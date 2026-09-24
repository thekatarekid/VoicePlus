import Foundation

/// S3 / S11 — the final-preview dwell and recovery persistence, as settings.
///
/// Wave 2 keeps its keys out of `SettingsStore.swift` (the rule for tasks that do not own it), in
/// this extension. The Settings rows (Dictation › "Preview before inserting", Privacy › "Keep held
/// text until resolved") are the S7 subpages' to draw; they read and write through these helpers.
public extension SettingsKeys {
    /// Legacy stored identifiers are retained; V3 presents 600 ms, 1200 ms or Manual.
    static let previewDwell = "preview.dwell"
    /// Whether held and recoverable turns are written to disk. Default ON. Independent of history
    /// (design §8.1, §12): off means "Kept for this session only".
    static let recoveryPersistence = "recovery.persist"
}

/// Design §5 step 4: how long the final payload is on screen before its one insertion.
public enum PreviewDwell: String, CaseIterable, Equatable, Sendable {
    case short = "600"
    case standard = "900"
    case long = "1500"
    /// Nothing is inserted until the Insert action.
    case manual

    /// Seconds before insertion; `nil` for manual review.
    public var seconds: TimeInterval? {
        switch self {
        case .short: return 0.6
        case .standard: return 0.6
        case .long: return 1.2
        case .manual: return nil
        }
    }

    /// Kept for source compatibility; confidence no longer adds a preview penalty.
    public static let lowConfidenceSeconds: TimeInterval = 0.6

    /// The dwell for a payload: `nil` = wait for Insert.
    public func seconds(lowConfidence: Bool) -> TimeInterval? {
        guard let base = seconds else { return nil }
        return base
    }

    public var label: String {
        switch self {
        case .short: return "600 ms"
        case .standard: return "600 ms"
        case .long: return "1200 ms"
        case .manual: return "Until I insert"
        }
    }
}

public enum TurnSettings {
    /// The dwell in force: `.standard` when unset or unreadable.
    public static func previewDwell(_ store: SettingsStore?) -> PreviewDwell {
        store?.string(SettingsKeys.previewDwell).flatMap(PreviewDwell.init(rawValue:)) ?? .standard
    }

    public static func setPreviewDwell(_ dwell: PreviewDwell, store: SettingsStore?) {
        store?.set(dwell.rawValue, for: SettingsKeys.previewDwell)
    }

    /// Recovery persistence; ON unless the user turned it off.
    public static func persistsRecovery(_ store: SettingsStore?) -> Bool {
        store?.bool(SettingsKeys.recoveryPersistence) ?? true
    }

    public static func setPersistsRecovery(_ on: Bool, store: SettingsStore?) {
        store?.set(on, for: SettingsKeys.recoveryPersistence)
    }

    public static var allKeys: [String] { [SettingsKeys.previewDwell, SettingsKeys.recoveryPersistence] }
}
