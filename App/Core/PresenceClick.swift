import Foundation

/// What a click on the presence dot does.
///
/// History, because this file has now changed its mind once. 1.7.9 (S6) made the *primary* click
/// explain the dot in place — or, for a blocked dot, jump straight to the fix (relaunch, the
/// Microphone / Input Monitoring privacy pane, our own Settings for a missing speech model) — and
/// moved the status menu to a right-click / ⌃-click. The owner used it and asked for the old
/// behaviour back: "It was ok to open menu on left clicking the notch. No need to make it right
/// click."
///
/// So every click, primary or secondary, pops the status menu. The per-state remedies are gone
/// rather than kept for blocked states only: a control whose click means something different
/// depending on a colour the user has to decode first is exactly the unpredictability being
/// complained about, and the menu is not a dead end for any blocked state — "Check permissions…",
/// "Settings…" (where speech models are downloaded) and "Quit VoicePlus" are all one item away in
/// `StatusItemController.rebuild()`. That is also the guarantee the indicator exists for: when
/// macOS culls the status item from a crowded menu bar, the chin under the notch is the way back in.
///
/// Nothing on this path activates the app: `StatusItemController.popUpMenu` pops a menu, and the
/// panel behind it stays a non-activating `NSPanel`, so focus never leaves what the user is typing in.
public enum PresenceClickAction: Equatable, Sendable {
    /// The status menu — Settings, permissions, mute, Quit.
    case menu
}

public enum PresenceClickRouter {
    /// One answer, deliberately: the state and the mouse button are both accepted and both ignored,
    /// so "which click, in which state?" has exactly one answer and the tests can prove it.
    /// `secondary` = right-click or ⌃-click.
    public static func action(for state: PresenceState, secondary: Bool = false) -> PresenceClickAction {
        _ = (state, secondary)
        return .menu
    }
}

// MARK: - R7.3 — one menu, four ways in

/// Which gesture asked for the menu. It exists to be *ignored* by everything that builds the menu:
/// V3 §9.3 and `DESIGN.md` §10 say left click, right click and ⌃-click, on the status-item glyph or
/// on the idle notch chin, all open **the same menu**. Naming the four ways in is what lets a test
/// prove they agree instead of asserting it in prose.
public enum MenuEntryPoint: String, CaseIterable, Equatable, Sendable {
    /// Left click on the menu-bar glyph.
    case glyph
    /// Right click or ⌃-click on the menu-bar glyph.
    case glyphSecondary
    /// Left click on the notch presence chin.
    case notch
    /// Right click or ⌃-click on the notch presence chin.
    case notchSecondary

    public var isSecondary: Bool { self == .glyphSecondary || self == .notchSecondary }
    public var isNotch: Bool { self == .notch || self == .notchSecondary }

    public static func glyph(secondary: Bool) -> MenuEntryPoint { secondary ? .glyphSecondary : .glyph }
    public static func notch(secondary: Bool) -> MenuEntryPoint { secondary ? .notchSecondary : .notch }
}

public extension PresenceClickRouter {
    /// The notch chin's click, named as a menu entry point. Same answer as `action(for:secondary:)`,
    /// carried in a form the menu builder can log.
    static func entryPoint(secondary: Bool) -> MenuEntryPoint { .notch(secondary: secondary) }
}
