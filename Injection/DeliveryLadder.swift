import Foundation
import Shared

// MARK: - N3 — the delivery ladder: write without a readable field

/// N3 — whether text may be written, and how, decided from structure and focus alone. A readable
/// field is *not* required: when the app and window from key-up are still focused, macOS secure
/// input is off and the focused element is not a password field, the text is delivered — paste
/// for multi-line text or web content, keystrokes otherwise — and verified only when the field can
/// be read ("can't tell" is neutral, N16). Refusal happens only when it is certain.
///
/// Owner decisions (2026-10-02) override the Round-3 text: a focus change is a **hold** (the
/// caller pulls back to the original window first, then asks again), never Notes; Notes is only
/// for a turn that never had a window to write into.
///
/// Pure: no AX, no settings. `TextInjector` feeds it the live facts; L3's pull-back uses it too.
public enum DeliveryLadder {
    /// The key-up window compared with now.
    public enum WindowState: String, Equatable, Sendable {
        /// Same window (or the caller cannot tell windows apart: treated as same — the app check stands).
        case same
        /// Same app, another of its windows is focused.
        case changed
        /// The key-up window no longer exists.
        case gone
        /// There was no window at key-up and there is none now (desktop, a menu-bar app).
        case none
        /// No window evidence either way.
        case unknown
    }

    public enum Method: String, Equatable, Sendable {
        case paste, keystrokes, ax
    }

    public enum Reason: String, Equatable, Sendable {
        case focusMoved = "focus moved to another app"
        case windowChanged = "another window took focus"
        case windowGone = "the window was closed"
        case noWindow = "no window to write into"
        case passwordField = "password field"
        case secureInputBlind = "secure input on, field unreadable"
        /// N15 — canvas-like focus with no editable text element.
        case notEditable = "Click into a text box first"
    }

    public enum Decision: Equatable, Sendable {
        /// Write with `method` first; `verify` is false when readback cannot run (the result is
        /// "delivered, unverified", which is neutral — never a failure, never a retry).
        case deliver(method: Method, verify: Bool)
        /// Store in Notes: there never was a destination.
        case notes(Reason)
        /// Keep the text for Insert here / Copy (after a pull-back, if the caller tries one).
        case hold(Reason)

        public var isDelivery: Bool { if case .deliver = self { return true }; return false }
    }

    /// - Parameters:
    ///   - focusSame: the key-up app (pid + bundle) is still frontmost.
    ///   - window: key-up window vs now.
    ///   - secureInput: `IsSecureEventInputEnabled()` right now.
    ///   - fieldReadable: the focused element exposes its value.
    ///   - surface: the N9 resolver's kind, when known.
    ///   - multiline: the text contains a line break.
    ///   - webContent: an `AXWebArea` ancestor or a Chromium/Electron runtime (N5/N10).
    ///   - passwordField: the focused element is `AXSecureTextField` (role or subrole).
    ///   - editable: the focused element is editable text; `nil` = unknown (never refuse on unknown).
    public static func decide(focusSame: Bool, window: WindowState, secureInput: Bool, fieldReadable: Bool,
                              surface: SurfaceKind?, multiline: Bool, webContent: Bool = false,
                              passwordField: Bool = false, editable: Bool? = nil) -> Decision {
        // Certain refusals first — a password field is never typed into, whatever else holds.
        if passwordField || surface == .secure { return .hold(.passwordField) }
        guard focusSame else { return .hold(.focusMoved) }
        switch window {
        case .gone: return .hold(.windowGone)
        case .changed: return .hold(.windowChanged)
        case .none: return .notes(.noWindow)
        case .same, .unknown: break
        }
        // N4 — a blind write while secure input is on: the likeliest target is a password prompt.
        if secureInput, !fieldReadable { return .hold(.secureInputBlind) }
        // N15 — a canvas with nothing editable focused: typing would fire tool shortcuts.
        if surface == .canvas, editable != true { return .hold(.notEditable) }

        // Terminals: bracketed paste (the terminal adapter), never Return.
        if surface == .terminal { return .deliver(method: .paste, verify: fieldReadable) }
        guard fieldReadable else {
            // Unreadable: deliver anyway. Paste carries line breaks without a Return key and is
            // one event in web content (Chromium drops fast keystrokes); single-line native → keys.
            return .deliver(method: (multiline || webContent) ? .paste : .keystrokes, verify: false)
        }
        // Readable web content: keystrokes with ⇧↩ (N5) — an AX value write desyncs the page editor.
        if webContent || surface == .chatComposer { return .deliver(method: .keystrokes, verify: true) }
        return .deliver(method: .ax, verify: true)
    }

    /// The ladder's method as the injector's `InjectionMethod`.
    public static func injectionMethod(_ method: Method) -> InjectionMethod {
        switch method {
        case .paste: return .paste
        case .keystrokes: return .keystroke
        case .ax: return .ax
        }
    }

    /// N3 — the method order the injector tries. With a readable field the adapter + history order
    /// stands (readback can verify it). With an unreadable field the ladder's method goes first.
    /// Adapters that own their write (terminal bracketed paste, spreadsheet cell mode, our own
    /// process) keep their order: they are already the safe plan for that surface.
    public static func order(_ methods: [InjectionMethod], ladder: Method, fieldReadable: Bool,
                             adapter: AppAdapter) -> [InjectionMethod] {
        guard !fieldReadable, !(adapter is TerminalAdapter), !(adapter is SpreadsheetAdapter),
              !(adapter is OwnProcessAdapter) else { return methods }
        let first = injectionMethod(ladder)
        // An AX write needs a readable element; with none it would be skipped anyway.
        guard first != .ax else { return methods }
        return [first] + methods.filter { $0 != first }
    }

    /// The window state from key-up's token and what is focused now. A `nil` key-up token with a
    /// window now means the caller recorded none: `.unknown`, not a change.
    public static func windowState(expected: String?, current: String?, expectedStillExists: Bool) -> WindowState {
        guard let expected else { return .unknown }
        if current == expected { return .same }
        return expectedStillExists ? .changed : .gone
    }
}

/// N3 — the focused window's identity (an opaque token, stable while the window lives) and
/// whether a window still exists. Additive protocol: a system that cannot answer gives `.unknown`.
public protocol FocusedWindowReading: AnyObject {
    func focusedWindowToken(pid: Int32) -> String?
    func windowExists(pid: Int32, token: String) -> Bool
}
