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
    /// N8 / owner decision (2026-10-02): no preview pause — typed as soon as the final text is
    /// ready. The preview may still show, but it never delays insertion. What dictation uses unless
    /// Manual review is on (`TurnSettings.landingDwell`); the timed cases above are legacy values
    /// still read for transforms and older stored settings.
    case immediate = "0"

    /// Seconds before insertion; `nil` for manual review.
    public var seconds: TimeInterval? {
        switch self {
        case .short: return 0.6
        case .standard: return 0.6
        case .long: return 1.2
        case .manual: return nil
        case .immediate: return 0
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
        case .immediate: return "Right away"
        }
    }
}

public enum TurnSettings {
    /// The dwell in force: `.standard` when unset or unreadable.
    public static func previewDwell(_ store: SettingsStore?) -> PreviewDwell {
        store?.string(SettingsKeys.previewDwell).flatMap(PreviewDwell.init(rawValue:)) ?? .standard
    }

    /// N8 — what a dictation turn does with its final preview: wait for Insert under Manual review,
    /// otherwise type right away. A stored timed dwell (600 / 900 / 1500) no longer delays a turn.
    public static func landingDwell(_ store: SettingsStore?) -> PreviewDwell {
        previewDwell(store) == .manual ? .manual : .immediate
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
