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
