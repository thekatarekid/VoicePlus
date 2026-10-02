import Foundation
import Pipeline

/// D3 / D6 — the two formatting settings (V4.2, V4.17). Settings → General renders them (S7g);
/// `UtteranceLander` reads them once per landing and hands them to the continuation planner.
///
/// Wave 1 keeps its keys out of `SettingsStore.swift` (owned by B this wave), in this extension.
public extension SettingsKeys {
    /// `SpacingPreference.rawValue`: `automatic` (default) · `always` · `never`.
    static let formattingSpacing = FieldContext.Keys.spacing
    /// `UnknownCaretStyle.rawValue`: `sentence` (default) · `asSpoken`.
    static let formattingUnknownCaretStyle = FieldContext.Keys.unknownCaretStyle
    /// N9 — "1" once `FormattingSettings.runSurfacePersonaResetIfNeeded` has run.
    static let surfacePersonaResetDone = "formatting.surfacePersonaReset.v1"
}

/// Typed access with the defaults in one place. An unrecognised stored value reads as the
/// default rather than failing.
public enum FormattingSettings {
    public static func spacing(_ store: SettingsStore?) -> SpacingPreference {
        store?.string(SettingsKeys.formattingSpacing).flatMap(SpacingPreference.init(rawValue:)) ?? .automatic
    }

    public static func setSpacing(_ value: SpacingPreference, store: SettingsStore?) {
        store?.set(value.rawValue, for: SettingsKeys.formattingSpacing)
    }

    public static func unknownCaretStyle(_ store: SettingsStore?) -> UnknownCaretStyle {
        store?.string(SettingsKeys.formattingUnknownCaretStyle).flatMap(UnknownCaretStyle.init(rawValue:)) ?? .sentence
    }

    public static func setUnknownCaretStyle(_ value: UnknownCaretStyle, store: SettingsStore?) {
        store?.set(value.rawValue, for: SettingsKeys.formattingUnknownCaretStyle)
    }

    public static func preferences(_ store: SettingsStore?) -> FormattingPreferences {
        FormattingPreferences(spacing: spacing(store), unknownCaretStyle: unknownCaretStyle(store))
    }

    public static var allKeys: [String] { [SettingsKeys.formattingSpacing, SettingsKeys.formattingUnknownCaretStyle] }

    /// N9 — one-time reset of auto personas / cold-start styles that the old `"code"` substring
    /// guessed wrong (`com.openai.codex`). Runs once per store; returns the bundle ids reset.
    @discardableResult
    public static func runSurfacePersonaResetIfNeeded(store: SettingsStore?, personas: PersonaManager) -> [String] {
        guard let store, store.string(SettingsKeys.surfacePersonaResetDone) != "1" else { return [] }
        let changed = (try? personas.resetMiscategorized()) ?? []
        store.set("1", for: SettingsKeys.surfacePersonaResetDone)
        return changed
    }
}
