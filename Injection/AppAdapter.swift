import Foundation

/// What readback could prove about a method that already posted (R2.3).
///
/// Note what is *missing*: a verdict that means "did not land". Readback cannot tell "did not
/// land" from "landed but the AX value is stale" — the Brave session proved the second case is
/// common (V3 §2.2, §14.4) — so `unconfirmed` and `unavailable` both mean
/// *delivered, unverified*. They differ only in what the log says.
public enum ReadbackVerdict: String, Sendable, Equatable, CaseIterable {
    /// Readback showed the text in the field: `delivered(verified: true)`.
    case confirmed
    /// Readback ran and did not show it. Possibly stale AX, possibly nothing landed.
    case unconfirmed
    /// There was nothing to read back — verification skipped, not failed.
    case unavailable

    public var isConfirmed: Bool { self == .confirmed }

    /// What goes in `injection_outcomes.detail`.
    public var detail: String {
        switch self {
        case .confirmed: return "verified"
        case .unconfirmed: return "unverified: readback unchanged"
        case .unavailable: return "unverified: readback unavailable"
        }
    }
}

/// The readback comparisons adapters share.
public enum Readback {
    /// Compare `AXValue` before and after: the strongest proof we can get.
    public static func byValue(text: String, before: FocusedElementInfo?, after: FocusedElementInfo?) -> ReadbackVerdict {
        guard let before, let value = before.value, let after = after?.value else { return .unavailable }
        if let sel = before.selectedRange {
            var units = Array(value.utf16)
            let clamped = max(0, min(sel.lowerBound, units.count))..<max(0, min(sel.upperBound, units.count))
            units.replaceSubrange(clamped, with: Array(text.utf16))
            if String(decoding: units, as: UTF16.self) == after { return .confirmed }
        }
        // Adapters may wrap the text (bracketed paste) or the app may normalise whitespace.
        if after != value && after.contains(text) { return .confirmed }
        return .unconfirmed
    }

    /// Compare the caret and `AXSelectedText`: for fields (Chromium's web content among them)
    /// whose `AXValue` is absent or stale but whose selection is live.
    public static func byCaretOrSelection(text: String, before: FocusedElementInfo?, after: FocusedElementInfo?) -> ReadbackVerdict {
        guard let before, let after else { return .unavailable }
        // A field that leaves the insertion selected reads it straight back.
        if let selected = after.selectedText, !text.isEmpty, selected == text { return .confirmed }
        guard let start = before.selectedRange, let end = after.selectedRange else { return .unavailable }
        if text.isEmpty { return .unavailable }
        // The caret sitting exactly `text` further on is the insertion, and any forward move at
        // all means *something* went in — enough for "possibly landed", which is all we claim.
        if end.lowerBound == start.lowerBound + text.utf16.count { return .confirmed }
        return end.lowerBound > start.lowerBound ? .confirmed : .unconfirmed
    }

    /// The verdict for any app whose editor owns its own text model — Chromium's web content,
    /// Electron's ProseMirror/Monaco composers (Slack, VS Code, Claude), Figma's canvas.
    ///
    /// `AXValue` is consulted first, for the cases where it is honest, and the caret / `AXSelectedText`
    /// second, because in these apps the value is routinely absent or stale while the selection is
    /// live. Only a readback that *ran* and showed nothing is `unconfirmed`; when neither side could
    /// answer, verification is skipped (`unavailable`), never reported as a failure.
    public static func byValueOrCaret(text: String, before: FocusedElementInfo?, after: FocusedElementInfo?) -> ReadbackVerdict {
        let byValue = Readback.byValue(text: text, before: before, after: after)
        if byValue == .confirmed { return .confirmed }
        let bySelection = Readback.byCaretOrSelection(text: text, before: before, after: after)
        if bySelection == .confirmed { return .confirmed }
        if byValue == .unavailable && bySelection == .unavailable { return .unavailable }
        return .unconfirmed
    }
}

/// Per-app knowledge for the hostile set (P1.8 T2). An adapter can (a) reorder/forbid methods,
/// (b) rewrite the text before it is sent, (c) provide its own `.adapter` method, and
/// (d) decide how readback is judged for this app.
public protocol AppAdapter: AnyObject {
    var id: String { get }
    func matches(bundleID: String) -> Bool
    /// Method preference for this app. Methods not listed are never tried.
    var methodOrder: [InjectionMethod] { get }
    /// Text transformation (e.g. strip smart punctuation for terminals).
    func prepare(_ text: String, focused: FocusedElementInfo?) -> String
    /// Custom `.adapter` injection. Return `false` if not applicable so the stack moves on.
    func injectViaAdapter(_ text: String, focus: FocusSnapshot, focused: FocusedElementInfo?, system: SystemAccess) throws -> Bool
    /// How to judge a method that already posted. Never decides *whether* to try another method —
    /// the readback rule does that, and the answer is always no.
    func verifyReadback(text: String, before: FocusedElementInfo?, after: FocusedElementInfo?) -> ReadbackVerdict
}

public extension AppAdapter {
    func prepare(_ text: String, focused: FocusedElementInfo?) -> String { text }
    func injectViaAdapter(_ text: String, focus: FocusSnapshot, focused: FocusedElementInfo?, system: SystemAccess) throws -> Bool { false }
    func verifyReadback(text: String, before: FocusedElementInfo?, after: FocusedElementInfo?) -> ReadbackVerdict {
        Readback.byValue(text: text, before: before, after: after)
    }
}

// MARK: - Q1 — newlines never send

/// Q1 (P0, safety) — an app where a typed `\n` (↩) would *send* or *commit*: Electron chat
/// composers (Claude, Slack), Cursor's AI composer, web chat boxes and Google Sheets cells. Half a
/// dictated message went out every time a paragraph break was spoken.
///
/// For these adapters the keystroke method never posts a bare ↩: each `\n` is posted as
/// `newlineCombo` (⇧↩, or ⌥↩ in a spreadsheet cell), so a paragraph break (`\n\n`) is two of them.
/// `SubmitPolicy` keeps `allowSubmit` false for them whatever the field claims.
public protocol NewlineSafeAdapter: AppAdapter {
    /// The key combo that inserts a line break without sending / committing.
    func newlineCombo(focused: FocusedElementInfo?) -> KeyCombo
}

public enum NewlineSafety {
    /// Every line-separator spelling becomes `\n`; a Unicode paragraph separator is a paragraph
    /// break (`\n\n`). After this the only line break left in the text is `\n`.
    public static func normalize(_ text: String) -> String {
        guard text.contains(where: { $0 == "\r" || $0 == "\r\n" || $0 == "\u{2028}" || $0 == "\u{2029}" }) else { return text }
        return text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n\n")
    }

    /// `docs.google.com/spreadsheets/…` — the stand-in for the spreadsheet-cell `FieldRole` (E2).
    public static func isSpreadsheetDocument(_ url: String?) -> Bool {
        guard let url, let parsed = URL(string: url), let host = parsed.host?.lowercased() else { return false }
        return host == "docs.google.com" && parsed.path.hasPrefix("/spreadsheets")
    }

    /// Types `text` with every `\n` posted as `combo` — never as a bare ↩ (unicode `\n` or `\r`).
    /// Runs of plain text go out as unicode keystrokes, exactly as the keystroke method does.
    public static func type(_ text: String, newline combo: KeyCombo, toPID pid: Int32, system: SystemAccess) throws {
        let lines = normalize(text).split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            if index > 0 { try system.postKeyCombo(combo, toPID: pid) }
            if !line.isEmpty { try system.postUnicodeKeystrokes(String(line), toPID: pid) }
        }
    }
}

/// Generic app: the full stack in canonical order.
public final class DefaultAdapter: AppAdapter {
    public let id = "default"
    public init() {}
    public func matches(bundleID: String) -> Bool { true }
    public var methodOrder: [InjectionMethod] { [.ax, .keystroke, .paste] }
}

enum SmartPunctuation {
    static let map: [Character: String] = ["\u{201C}": "\"", "\u{201D}": "\"", "\u{2018}": "'", "\u{2019}": "'",
                                           "\u{2014}": "--", "\u{2013}": "-", "\u{2026}": "...", "\u{00A0}": " "]
    static func strip(_ text: String) -> String {
        String(text.flatMap { map[$0] ?? String($0) })
    }
}

/// Terminal.app / iTerm2 / Ghostty / tmux-in-any-terminal: no smart punctuation; multi-line text is
/// wrapped in bracketed-paste markers so the shell never auto-executes a newline. Keystrokes first —
/// terminals have no meaningful AX value to set, and paste goes through the shell's own paste handling.
public final class TerminalAdapter: AppAdapter {
    public static let bundleIDs: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
                                               "dev.warp.Warp-Stable", "net.kovidgoyal.kitty", "io.alacritty", "org.alacritty",
                                               "com.github.wez.wezterm", "co.zeit.hyper", "org.tabby", "com.raphaelamorim.rio"]
    public let id = "terminal"
    public init() {}
    public func matches(bundleID: String) -> Bool { Self.bundleIDs.contains(bundleID) }
    public var methodOrder: [InjectionMethod] { [.adapter, .paste] }
    public func prepare(_ text: String, focused: FocusedElementInfo?) -> String { SmartPunctuation.strip(text) }

    public static func bracketed(_ text: String) -> String {
        text.contains("\n") ? "\u{1B}[200~" + text + "\u{1B}[201~" : text
    }

    public func injectViaAdapter(_ text: String, focus: FocusSnapshot, focused: FocusedElementInfo?, system: SystemAccess) throws -> Bool {
        try system.postUnicodeKeystrokes(Self.bracketed(text), toPID: focus.pid)
        return true
    }
}

/// Electron apps (Slack, VS Code, Discord, Notion, Obsidian, Claude…): `AXValue` writes silently
/// desync the editor's model (React/ProseMirror/Monaco), so AX is forbidden; keystrokes land, paste
/// is the backup.
///
/// V4.40: the Claude desktop app (`com.anthropic.claudefordesktop`, verified with
/// `osascript -e 'id of app "Claude"'` against Claude 2.110.0, which ships `Electron Framework`)
/// used to fall through to `DefaultAdapter`, whose `.ax` first write is exactly the ProseMirror
/// desync this adapter exists to avoid.
public final class ElectronAdapter: NewlineSafeAdapter {
    public static let claudeDesktopBundleID = "com.anthropic.claudefordesktop"
    public static let bundleIDs: Set<String> = ["com.tinyspeck.slackmacgap", "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
                                               "com.hnc.Discord", "notion.id", "md.obsidian", "com.figma.Desktop",
                                               claudeDesktopBundleID]
    public let id = "electron"
    public init() {}
    public func matches(bundleID: String) -> Bool { Self.bundleIDs.contains(bundleID) }
    public var methodOrder: [InjectionMethod] { [.keystroke, .paste] }

    /// Q1 — a typed `\n` is ↩, and ↩ sends the message in Claude / Slack / Discord. ⇧↩ everywhere.
    public func newlineCombo(focused: FocusedElementInfo?) -> KeyCombo { .shiftReturn }
    public func prepare(_ text: String, focused: FocusedElementInfo?) -> String { NewlineSafety.normalize(text) }

    /// V4.41 — Electron composers are exactly the Chromium readback case and were never given it:
    /// the default `Readback.byValue` judged a ProseMirror field whose `AXValue` is absent or stale,
    /// so a keystroke write that had landed in the Claude desktop composer was reported as
    /// `delivered(verified: false)` and surfaced as D06 "Couldn't confirm insertion" every time.
    /// The caret and `AXSelectedText` are what these apps can actually answer.
    public func verifyReadback(text: String, before: FocusedElementInfo?, after: FocusedElementInfo?) -> ReadbackVerdict {
        Readback.byValueOrCaret(text: text, before: before, after: after)
    }
}

/// Cursor is a VS Code fork with an AI composer; same rules as Electron, separate id for routing telemetry.
public final class CursorAdapter: NewlineSafeAdapter {
    public let id = "cursor"
    public init() {}
    public func matches(bundleID: String) -> Bool { bundleID == "com.todesktop.230313mzl4w4u92" || bundleID.lowercased().contains("cursor") }
    public var methodOrder: [InjectionMethod] { [.keystroke, .paste] }

    /// Q1 — ↩ submits the AI composer. ⇧↩ is a line break in both the composer and the editor.
    public func newlineCombo(focused: FocusedElementInfo?) -> KeyCombo { .shiftReturn }
    public func prepare(_ text: String, focused: FocusedElementInfo?) -> String { NewlineSafety.normalize(text) }

    public func verifyReadback(text: String, before: FocusedElementInfo?, after: FocusedElementInfo?) -> ReadbackVerdict {
        Readback.byValueOrCaret(text: text, before: before, after: after)
    }
}

/// Chromium-based browsers (Brave, Chrome, Edge, Arc) — R2.3.
///
/// Why this exists: on the owner's Mac seven of twenty dictations into Brave logged
/// `keystroke failed … readback unchanged` and then `paste failed … readback unchanged`
/// (V3 §2.2). Both methods had posted. Chromium's `AXValue` for web content simply did not
/// reflect the change, so a good delivery was recorded as a failure — and the text landed twice.
///
/// The fix is two-part. The injector never runs a second method after one has posted (the readback
/// rule, `TextInjector.inject`), and this adapter judges readback the way Chromium can actually
/// answer: the caret and `AXSelectedText`, with verification *skipped* — unverified, never failed —
/// when neither is exposed. `AXValue` is still consulted first for the cases where it is honest
/// (the omnibox, `<textarea>` in some builds).
///
/// Order is `[.keystroke, .paste]`: AX value writes desync Blink's own model exactly as they do in
/// Electron, and paste only ever runs when keystrokes threw before posting anything.
public final class ChromiumAdapter: NewlineSafeAdapter {
    public static let bundleIDs: Set<String> = ["com.brave.Browser", "com.google.Chrome",
                                                "com.microsoft.edgemac", "company.thebrowser.Browser"]
    public let id = "chromium"
    public init() {}

    /// Exact ids, plus the release-channel siblings that suffix them
    /// (`com.google.Chrome.canary`, `com.brave.Browser.beta`, `com.microsoft.edgemac.Dev`).
    public func matches(bundleID: String) -> Bool {
        Self.bundleIDs.contains(bundleID) || Self.bundleIDs.contains { bundleID.hasPrefix($0 + ".") }
    }

    public var methodOrder: [InjectionMethod] { [.keystroke, .paste] }

    /// Q1 — a Google Sheets cell commits on ↩ (and moves down a row): ⌥↩ is the in-cell newline.
    /// Everywhere else in web content ↩ sends chat messages (claude.ai, Slack web, Gmail chat) or
    /// submits forms, so ⇧↩ — a line break in `<textarea>` and every contenteditable composer.
    /// Until the spreadsheet `FieldRole` (E2) lands, the host decides "cell".
    public func newlineCombo(focused: FocusedElementInfo?) -> KeyCombo {
        NewlineSafety.isSpreadsheetDocument(focused?.documentURL) ? .optionReturn : .shiftReturn
    }
    public func prepare(_ text: String, focused: FocusedElementInfo?) -> String { NewlineSafety.normalize(text) }

    /// Neither the value nor the caret available: skip verification rather than claim a failure.
    /// If one of them *was* available and showed nothing, say so — but still unverified.
    public func verifyReadback(text: String, before: FocusedElementInfo?, after: FocusedElementInfo?) -> ReadbackVerdict {
        Readback.byValueOrCaret(text: text, before: before, after: after)
    }
}

/// Excel / Numbers / Google Sheets (in a browser): when a cell (not an in-cell editor) is focused, typing
/// enters edit mode automatically; newlines must become ⌥↩ or the cell commits. Paste of multi-line
/// text would spill across rows, so paste is only allowed in single-line form.
public final class SpreadsheetAdapter: AppAdapter {
    public static let bundleIDs: Set<String> = ["com.microsoft.Excel", "com.apple.iWork.Numbers"]
    public let id = "spreadsheet"
    public init() {}
    public func matches(bundleID: String) -> Bool { Self.bundleIDs.contains(bundleID) }
    public var methodOrder: [InjectionMethod] { [.adapter, .ax, .paste] }

    static func isCell(_ focused: FocusedElementInfo?) -> Bool {
        guard let role = focused?.role else { return true }
        return role == "AXCell" || role == "AXTable" || role == "AXLayoutItem" || role == "AXGroup"
    }

    public func prepare(_ text: String, focused: FocusedElementInfo?) -> String {
        Self.isCell(focused) ? text.replacingOccurrences(of: "\n", with: " ") : text
    }

    public func injectViaAdapter(_ text: String, focus: FocusSnapshot, focused: FocusedElementInfo?, system: SystemAccess) throws -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (i, line) in lines.enumerated() {
            if i > 0 { try system.postKeyCombo(.optionReturn, toPID: focus.pid) }
            try system.postUnicodeKeystrokes(String(line), toPID: focus.pid)
        }
        return true
    }
}

/// Figma: canvas text objects are invisible to AX; only keystrokes reach the text editor. Paste works
/// inside an active text edit but would create a new text layer otherwise, so it is last.
public final class FigmaAdapter: AppAdapter {
    public let id = "figma"
    public init() {}
    public func matches(bundleID: String) -> Bool { bundleID == "com.figma.Desktop" }
    public var methodOrder: [InjectionMethod] { [.keystroke, .paste] }

    public func verifyReadback(text: String, before: FocusedElementInfo?, after: FocusedElementInfo?) -> ReadbackVerdict {
        Readback.byValueOrCaret(text: text, before: before, after: after)
    }
}

/// FX1 — VoicePlus's own windows: the onboarding practice field, Settings' text fields.
///
/// Never AX. An AX write aimed at our own process runs AppKit's handler on the calling thread;
/// from the turn's background thread that edits an `NSTextView` off the main thread and deadlocks
/// TextKit 2 against the main thread's layout (the 1.11 onboarding freeze). The `.adapter` method
/// inserts through `InProcessTextDelivering` — `NSTextView.insertText` on the main thread, the
/// same path as typing. Keystrokes are the fallback when the first responder is not text: they
/// arrive through the main run loop like any key press.
///
/// `TextInjector` picks this adapter itself for a focus `OwnProcess.owns`; it is not in
/// `AdapterRegistry.standard()`, so no other bundle ID can ever match it.
public final class OwnProcessAdapter: AppAdapter {
    public let id = "own-process"
    public init() {}
    public func matches(bundleID: String) -> Bool {
        guard let own = Bundle.main.bundleIdentifier, !own.isEmpty else { return false }
        return bundleID == own
    }
    public var methodOrder: [InjectionMethod] { [.adapter, .keystroke] }

    public func injectViaAdapter(_ text: String, focus: FocusSnapshot, focused: FocusedElementInfo?, system: SystemAccess) throws -> Bool {
        guard let local = system as? InProcessTextDelivering else { return false }
        return try local.insertIntoOwnFocusedText(text)
    }
}

/// Ordered registry; first match wins, `DefaultAdapter` is the catch-all.
public final class AdapterRegistry {
    public private(set) var adapters: [AppAdapter]

    public init(adapters: [AppAdapter]) { self.adapters = adapters }

    public static func standard() -> AdapterRegistry {
        AdapterRegistry(adapters: [TerminalAdapter(), FigmaAdapter(), CursorAdapter(), SpreadsheetAdapter(),
                                   ElectronAdapter(), ChromiumAdapter(), DefaultAdapter()])
    }

    public func register(_ adapter: AppAdapter, first: Bool = true) {
        if first { adapters.insert(adapter, at: 0) } else { adapters.append(adapter) }
    }

    public func adapter(for bundleID: String) -> AppAdapter {
        adapters.first { $0.matches(bundleID: bundleID) } ?? DefaultAdapter()
    }
}
