import Foundation

/// Per-app knowledge for the hostile set (P1.8 T2). An adapter can (a) reorder/forbid methods,
/// (b) rewrite the text before it is sent, and (c) provide its own `.adapter` method.
public protocol AppAdapter: AnyObject {
    var id: String { get }
    func matches(bundleID: String) -> Bool
    /// Method preference for this app. Methods not listed are never tried.
    var methodOrder: [InjectionMethod] { get }
    /// Text transformation (e.g. strip smart punctuation for terminals).
    func prepare(_ text: String, focused: FocusedElementInfo?) -> String
    /// Custom `.adapter` injection. Return `false` if not applicable so the stack moves on.
    func injectViaAdapter(_ text: String, focus: FocusSnapshot, focused: FocusedElementInfo?, system: SystemAccess) throws -> Bool
}

public extension AppAdapter {
    func prepare(_ text: String, focused: FocusedElementInfo?) -> String { text }
    func injectViaAdapter(_ text: String, focus: FocusSnapshot, focused: FocusedElementInfo?, system: SystemAccess) throws -> Bool { false }
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
                                               "dev.warp.Warp-Stable", "net.kovidgoyal.kitty", "io.alacritty", "org.alacritty"]
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

/// Electron apps (Slack, VS Code, Discord, Notion, Obsidian…): `AXValue` writes silently desync the
/// editor's model (React/ProseMirror/Monaco), so AX is forbidden; keystrokes land, paste is the backup.
public final class ElectronAdapter: AppAdapter {
    public static let bundleIDs: Set<String> = ["com.tinyspeck.slackmacgap", "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
                                               "com.hnc.Discord", "notion.id", "md.obsidian", "com.figma.Desktop"]
    public let id = "electron"
    public init() {}
    public func matches(bundleID: String) -> Bool { Self.bundleIDs.contains(bundleID) }
    public var methodOrder: [InjectionMethod] { [.keystroke, .paste] }
}

/// Cursor is a VS Code fork with an AI composer; same rules as Electron, separate id for routing telemetry.
public final class CursorAdapter: AppAdapter {
    public let id = "cursor"
    public init() {}
    public func matches(bundleID: String) -> Bool { bundleID == "com.todesktop.230313mzl4w4u92" || bundleID.lowercased().contains("cursor") }
    public var methodOrder: [InjectionMethod] { [.keystroke, .paste] }
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
}

/// Ordered registry; first match wins, `DefaultAdapter` is the catch-all.
public final class AdapterRegistry {
    public private(set) var adapters: [AppAdapter]

    public init(adapters: [AppAdapter]) { self.adapters = adapters }

    public static func standard() -> AdapterRegistry {
        AdapterRegistry(adapters: [TerminalAdapter(), FigmaAdapter(), CursorAdapter(), SpreadsheetAdapter(), ElectronAdapter(), DefaultAdapter()])
    }

    public func register(_ adapter: AppAdapter, first: Bool = true) {
        if first { adapters.insert(adapter, at: 0) } else { adapters.append(adapter) }
    }

    public func adapter(for bundleID: String) -> AppAdapter {
        adapters.first { $0.matches(bundleID: bundleID) } ?? DefaultAdapter()
    }
}
