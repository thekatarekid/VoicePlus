import Foundation

/// S6 — what a click on the presence dot does.
///
/// The bug: every click, in every state, popped the status-bar menu ("I clicked on the green dot
/// notch and it opened menu bar's app menu"). That was deliberate — the indicator exists because
/// macOS culls the status item — but it is the wrong *primary* affordance. A small status light
/// answers one question, "what are you telling me?", and when it is telling you something is broken
/// it should offer the fix. A menu is neither.
///
/// So: the primary click explains or repairs; the *secondary* click (right-click, or ⌃-click) keeps
/// the menu, which is what preserves the "way back in when the status item is gone" guarantee.
///
/// Nothing here activates the app except a remedy the user explicitly asked for by clicking a
/// broken state — `.explain` and `.menu` never take focus from what they are typing into.
public enum PresenceClickAction: Equatable, Sendable {
    /// Pin the expanded row open so the sentence behind the glyph can be read without hovering.
    case explain
    /// `blocked(.relaunchNeeded)`: quit and reopen, the only fix for a dead event tap.
    case relaunch
    /// Take the user to the thing that is missing.
    case remedy(PresenceRemedy)
    /// The status menu — Settings, mute, Quit.
    case menu
}

/// Where a blocked indicator sends the user to unblock itself.
public enum PresenceRemedy: Equatable, Sendable {
    case microphonePrivacy
    case inputMonitoringPrivacy
    /// VoicePlus' own Settings, where speech models are downloaded.
    case speechModelSettings

    /// System Settings deep link; `nil` for panes that are ours, not the system's.
    public var systemSettingsURL: String? {
        switch self {
        case .microphonePrivacy: return "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .inputMonitoringPrivacy: return "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        case .speechModelSettings: return nil
        }
    }
}

public enum PresenceClickRouter {
    /// `secondary` = right-click or ⌃-click.
    public static func action(for state: PresenceState, secondary: Bool = false) -> PresenceClickAction {
        if secondary { return .menu }
        switch state {
        case .blocked(.relaunchNeeded): return .relaunch
        case .blocked(.microphoneDenied): return .remedy(.microphonePrivacy)
        case .blocked(.hotkeyUnavailable): return .remedy(.inputMonitoringPrivacy)
        case .blocked(.modelMissing): return .remedy(.speechModelSettings)
        // A download is already doing the only thing that would help; say how far along it is.
        case .blocked(.modelDownloading): return .explain
        case .off, .ready, .listening, .processing, .muted, .paused: return .explain
        }
    }

    /// How long a clicked-open row stays pinned. Longer than the hover row (which the pointer
    /// controls) and shorter than the launch announcement.
    public static let explainDuration: TimeInterval = 5

    public static func isExplaining(since: Date?, now: Date = Date()) -> Bool {
        guard let since else { return false }
        return now.timeIntervalSince(since) < explainDuration
    }
}
