import AppKit
import Combine
import Pipeline
import Shared
import SwiftUI

// V5 LANG2 — the notch script dropdown. The pill's script badge ("EN" / "हि" / "EN·हि") becomes a
// menu: Roman · Devanagari · Mixed. A pick applies to the turn on screen and is remembered for the
// app it was made in, so the next turn there is written the same way without asking again.
//
// Resolution for a turn (first that answers): this turn's pick → the app's remembered script →
// the LANG1 script for Hindi → nothing (the script stage stays inert, pre-LANG behaviour). The
// rewrite itself is `ScriptOutputStage` at the end of the pipeline: P6 transliteration (IndicXlit
// when a converted model is installed, rule-based otherwise), danda only for Devanagari.

public extension SettingsKeys {
    /// `bundleID=script` pairs, comma-separated — LANG2's per-app memory.
    static let scriptByApp = "lang.scriptByApp"
}

/// Per-app script memory, persisted in `SettingsStore` (strings only).
public struct AppScriptMemory {
    public let store: SettingsStore?
    public init(store: SettingsStore?) { self.store = store }

    public var all: [String: OutputScript] {
        var out: [String: OutputScript] = [:]
        for pair in (store?.string(SettingsKeys.scriptByApp) ?? "").split(separator: ",") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2, !kv[0].isEmpty, let s = OutputScript(rawValue: kv[1]) { out[kv[0]] = s }
        }
        return out
    }

    public func script(for bundleID: String?) -> OutputScript? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        return all[bundleID]
    }

    public func remember(_ script: OutputScript, for bundleID: String?) {
        guard let store, let bundleID, !bundleID.isEmpty, !bundleID.contains(","), !bundleID.contains("=") else { return }
        var map = all
        map[bundleID] = script
        store.set(map.keys.sorted().map { "\($0)=\(map[$0]!.rawValue)" }.joined(separator: ","), for: SettingsKeys.scriptByApp)
    }
}

/// The dropdown's state and the per-turn resolution. Main-thread UI, but `resolve`/`consume` are
/// called from the landing path, so the turn pick is lock-guarded.
public final class ScriptChoiceModel: ObservableObject, @unchecked Sendable {
    public let settings: SettingsStore?
    private let frontmostBundleID: () -> String?
    private let lock = NSLock()
    private var pick: (script: OutputScript, bundleID: String?)?

    /// The script shown as selected in the menu for the turn on screen.
    @Published public private(set) var selected: OutputScript?

    public init(settings: SettingsStore?,
                frontmostBundleID: @escaping () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }) {
        self.settings = settings
        self.frontmostBundleID = frontmostBundleID
    }

    /// The menu shows only when a chosen language has a script choice (LANG1: Hindi), or the app
    /// already has a remembered script.
    public var isOffered: Bool {
        LanguagePreferences.load(settings)?.includesHindi == true
            || AppScriptMemory(store: settings).script(for: frontmostBundleID()) != nil
    }

    public var options: [OutputScript] { LanguagePreferences.hindiScripts }

    /// The user picked a script in the notch: this turn, and every later turn in this app.
    public func choose(_ script: OutputScript) {
        let bundleID = frontmostBundleID()
        lock.lock(); pick = (script, bundleID); lock.unlock()
        AppScriptMemory(store: settings).remember(script, for: bundleID)
        setSelected(script)
    }

    /// What a turn landing in `bundleID` is written in, or nil = leave the text's script alone.
    public func resolve(bundleID: String?) -> OutputScript? {
        lock.lock(); let turn = pick; lock.unlock()
        if let turn { return turn.script }
        if let remembered = AppScriptMemory(store: settings).script(for: bundleID) { return remembered }
        return LanguagePreferences.load(settings)?.defaultTurnScript
    }

    /// `resolve` for the landing turn, then the turn pick is spent (the app memory stays).
    public func consume(bundleID: String?) -> OutputScript? {
        let script = resolve(bundleID: bundleID)
        lock.lock(); pick = nil; lock.unlock()
        return script
    }

    /// A new turn opened: show what it will be written in.
    public func refresh() { setSelected(resolve(bundleID: frontmostBundleID())) }

    /// Writes the turn's script into the pipeline context (`UtteranceLander.contextAugmenter`).
    public func augment(_ ctx: StageContext) -> StageContext {
        guard let script = consume(bundleID: ctx.appBundleID) else { return ctx }
        var ctx = ctx
        ctx.extra[ScriptOutputStage.Keys.script] = script.rawValue
        return ctx
    }

    private func setSelected(_ script: OutputScript?) {
        if Thread.isMainThread { selected = script } else { DispatchQueue.main.async { self.selected = script } }
    }
}

/// The badge-as-menu drawn in the pill's status row. Without a model (or when no chosen language
/// has a script choice) it is exactly the old badge text.
public struct PillScriptMenu: View {
    public var badge: String
    @ObservedObject private var model: ScriptChoiceModel

    public init(badge: String, model: ScriptChoiceModel) {
        self.badge = badge
        self.model = model
    }

    public var body: some View {
        if model.isOffered {
            Menu {
                ForEach(model.options, id: \.self) { script in
                    Button {
                        model.choose(script)
                    } label: {
                        if model.selected == script { Label(script.title, systemImage: "checkmark") } else { Text(script.title) }
                    }
                }
            } label: {
                Text(label).font(Tokens.Typography.key.font())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            .foregroundStyle(Tokens.Pill.Token.secondaryInk.color)
            .accessibilityLabel("Script")
            .accessibilityValue(model.selected?.title ?? OutputScript.default.title)
            .accessibilityIdentifier("pill.script")
            .onAppear { model.refresh() }
        } else if !badge.isEmpty {
            Text(badge)
                .font(Tokens.Typography.key.font())
                .foregroundStyle(Tokens.Pill.Token.secondaryInk.color)
                .accessibilityIdentifier("pill.script")
        }
    }

    /// The badge when there is one; otherwise the selected script's short name.
    var label: String {
        if !badge.isEmpty { return badge }
        switch model.selected ?? .default {
        case .roman: return "Aa"
        case .devanagari: return "अ"
        case .mixed: return "Aa·अ"
        }
    }
}
