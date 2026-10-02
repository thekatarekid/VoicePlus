import Foundation
import Injection
import Pipeline
import Shared

/// N25 — the user's default preset per surface group (Settings › General › "Style by kind of
/// field"). Stored as `group=id;group=id`. A per-app selection already in the run's context (the
/// app rule) wins for its group; these fill the rest. A missing group means that group's default.
public enum SurfacePresetSettings {
    public static let key = "style.presets.default"

    public static func selection(_ store: SettingsStore?) -> [String: String] {
        SurfacePresets.decode(store?.string(key))
    }

    /// The chosen preset id for `group`, or the group's default.
    public static func presetID(forGroup group: String, store: SettingsStore?) -> String? {
        if let id = selection(store)[group], SurfacePresets.preset(id, inGroup: group) != nil { return id }
        return SurfacePresets.defaultPreset(forGroup: group)?.id
    }

    /// Unknown groups / ids are ignored; choosing the default removes the entry.
    public static func set(_ id: String, forGroup group: String, store: SettingsStore?) {
        guard SurfacePresets.preset(id, inGroup: group) != nil else { return }
        var sel = selection(store)
        if SurfacePresets.defaultPreset(forGroup: group)?.id == id { sel.removeValue(forKey: group) } else { sel[group] = id }
        store?.set(sel.isEmpty ? nil : SurfacePresets.encode(sel), for: key)
    }

    /// The run's selection: per-app entries already in `context` first, then the user's defaults.
    public static func apply(to context: StageContext, store: SettingsStore?) -> StageContext {
        let defaults = selection(store)
        guard !defaults.isEmpty else { return context }
        var ctx = context
        var merged = defaults
        for (group, id) in SurfacePresets.decode(ctx.extra[SurfacePresets.selectionKey]) { merged[group] = id }
        ctx.extra[SurfacePresets.selectionKey] = SurfacePresets.encode(merged)
        return ctx
    }

    // Copy
    public static let groupTitle = "Style by kind of field"
    public static let groupDetail = "The default voice for each kind of field. An app's own rule (Dictionary & Apps) wins. Safety never changes: no preset sends a message."
    public static func groupName(_ group: String) -> String {
        switch group {
        case "prose": return "Documents and notes"
        case "emailBody": return "Email"
        case "chatComposer": return "Chat"
        case "markdownEditor": return "Markdown editors"
        case "formField": return "Form fields"
        case "searchField": return "Search boxes"
        case "urlBar": return "Address bars"
        case "spreadsheetCell": return "Spreadsheet cells"
        case "codeEditor": return "Code editors"
        case "terminal": return "Terminal"
        default: return group
        }
    }
}

/// N26 — "Clean up text inserted mid-sentence". On by default: a mid-document insert keeps
/// cleanup (with its edges kept, N26). Off: such an insert skips the cleanup model
/// (`CleanupStage.skipKey`) while style and the field rules still apply — the two are separate.
public enum MidDocumentCleanupSettings {
    public static let key = "cleanup.midDocument.enabled"
    public static func isEnabled(_ store: SettingsStore?) -> Bool { store?.bool(key) ?? true }
    public static func setEnabled(_ on: Bool, store: SettingsStore?) { store?.set(on, for: key) }

    /// True when the field rules decided this is a mid-sentence insertion (no capital first word or
    /// no closing period) — the same test `FieldRolePipeline` uses to keep cleanup's edges.
    public static func isMidDocument(_ field: FieldContext) -> Bool {
        let plan = FieldRoleFormatter().plan(for: field)
        return !plan.rules.trailingPeriod || !plan.continuation.capitalizeFirstWord
    }

    /// Off + mid-document → skip cleanup for this run. `field` is read only when the switch is off.
    public static func apply(to context: StageContext, store: SettingsStore?,
                             field: () -> FieldContext?) -> StageContext {
        guard !isEnabled(store), let f = field(), isMidDocument(f) else { return context }
        var ctx = context
        ctx.extra[CleanupStage.skipKey] = "true"
        return ctx
    }

    public static let title = "Clean up text inserted mid-sentence"
    public static let detail = "When off, words dropped into the middle of existing text skip the cleanup model. Your style and the field's rules still apply."
}

/// N10 — per-app off switch for turning on accessibility (`AXManualAccessibility` /
/// `AXEnhancedUserInterface`). `Injection` reads `InjectionSettingsKeys.accessibilityOffApps`.
public enum AccessibilityOffApps {
    public static var key: String { InjectionSettingsKeys.accessibilityOffApps }

    public static func list(_ defaults: UserDefaults = .standard) -> [String] {
        (defaults.stringArray(forKey: key) ?? []).sorted()
    }

    public static func add(_ bundleID: String, _ defaults: UserDefaults = .standard) {
        let id = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        var set = Set(defaults.stringArray(forKey: key) ?? [])
        set.insert(id)
        defaults.set(set.sorted(), forKey: key)
    }

    public static func remove(_ bundleID: String, _ defaults: UserDefaults = .standard) {
        let rest = (defaults.stringArray(forKey: key) ?? []).filter { $0 != bundleID }
        if rest.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(rest, forKey: key) }
    }

    public static let title = "Never turn on accessibility in"
    public static let detail = "VoicePlus asks Chromium and Electron apps to expose their text. Apps listed here are never asked; text still lands, but VoicePlus cannot read or confirm it there."
    public static let addLabel = "Add app…"
    public static let empty = "No apps"
}
