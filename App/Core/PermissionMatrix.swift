import Foundation

/// The three permissions the app needs (T5).
public enum Permission: String, CaseIterable, Codable, Sendable, Identifiable {
    case microphone, accessibility, inputMonitoring
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .accessibility: return "Accessibility"
        case .inputMonitoring: return "Input Monitoring"
        }
    }

    /// Plain-language pre-prompt copy shown *before* the system dialog.
    public var rationale: String {
        switch self {
        case .microphone:
            return "VoicePlus listens only while you hold the key. Audio is transcribed on this Mac and never leaves it unless you turn on a cloud provider."
        case .accessibility:
            return "Accessibility lets VoicePlus type what you said into the app you're using and read the field you're in so it can match the style. No screenshots, ever."
        case .inputMonitoring:
            return "Input Monitoring is how VoicePlus notices you holding the dictation key while another app is in front. Keystrokes are not recorded."
        }
    }

    /// `revealElementKeyName` used by macOS' SecurityPrivacyExtension for this service.
    public var settingsAnchor: String {
        switch self {
        case .microphone: return "Privacy_Microphone"
        case .accessibility: return "Privacy_Accessibility"
        case .inputMonitoring: return "Privacy_ListenEvent"
        }
    }

    /// Deep link into System Settings › Privacy & Security for the permission.
    public var settingsURL: URL { PermissionSettingsLink.urls(anchor: settingsAnchor)[0] }

    /// Modern pane id first, legacy `Security.prefPane` second. `NSWorkspace.open` returns false for a
    /// pane id the running macOS doesn't know, so callers walk the list until one opens.
    public var settingsURLs: [URL] { PermissionSettingsLink.urls(anchor: settingsAnchor) }
}

/// One source of truth for the System Settings deep links (shared with `OnboardingPermission`).
/// Anchors verified against `/System/Library/ExtensionKit/Extensions/SecurityPrivacyExtension.appex`
/// `TCCServiceList.plist` on macOS 26.6.2.
public enum PermissionSettingsLink {
    public static func urls(anchor: String) -> [URL] {
        [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)",
            "x-apple.systempreferences:com.apple.preference.security?\(anchor)",
        ].compactMap(URL.init(string:))
    }
}

public enum PermissionStatus: String, Codable, Equatable, Sendable {
    case notDetermined, granted, denied
    /// The request was issued but macOS did not (and will not) answer synchronously — the user has to
    /// flip the switch in System Settings. `CGRequestListenEventAccess()` and
    /// `AXIsProcessTrustedWithOptions(prompt:)` *always* land here on a first call: they return the
    /// current authorization in microseconds and merely post a notification. Never a dead end.
    case awaitingUserAction
}

public typealias PermissionMatrix = [Permission: PermissionStatus]

/// Pure decision table (the "permission-state matrix" test target).
public enum PermissionPlanner {
    public enum Step: Equatable, Sendable {
        /// Show the pre-prompt window, then trigger the system prompt.
        case prePrompt(Permission)
        /// Already denied: system prompt won't show again; send user to System Settings and re-verify.
        case openSettings(Permission)
        case allGranted
    }

    /// Order matters: mic first (needed for anything), then input monitoring (hotkey), then accessibility (landing).
    public static let order: [Permission] = [.microphone, .inputMonitoring, .accessibility]

    public static func nextStep(_ matrix: PermissionMatrix) -> Step {
        for permission in order {
            switch matrix[permission] ?? .notDetermined {
            case .granted: continue
            case .notDetermined: return .prePrompt(permission)
            case .denied, .awaitingUserAction: return .openSettings(permission)
            }
        }
        return .allGranted
    }

    /// What the app can do with the current grants.
    public struct Capabilities: Equatable, Sendable {
        public var canCapture: Bool
        public var canUseGlobalHotkey: Bool
        public var canInjectText: Bool
        /// Hotkey without Input Monitoring falls back to the menu-bar "Start dictation" item.
        public var needsMenuFallback: Bool { canCapture && !canUseGlobalHotkey }
    }

    public static func capabilities(_ matrix: PermissionMatrix) -> Capabilities {
        Capabilities(
            canCapture: matrix[.microphone] == .granted,
            canUseGlobalHotkey: matrix[.inputMonitoring] == .granted,
            canInjectText: matrix[.accessibility] == .granted
        )
    }

    public static func missing(_ matrix: PermissionMatrix) -> [Permission] {
        order.filter { matrix[$0] != .granted }
    }
}
