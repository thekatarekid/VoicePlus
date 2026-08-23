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

    /// Deep link into System Settings › Privacy & Security for the permission.
    public var settingsURL: URL {
        let anchor: String
        switch self {
        case .microphone: anchor = "Privacy_Microphone"
        case .accessibility: anchor = "Privacy_Accessibility"
        case .inputMonitoring: anchor = "Privacy_ListenEvent"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}

public enum PermissionStatus: String, Codable, Equatable, Sendable {
    case notDetermined, granted, denied
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
            case .denied: return .openSettings(permission)
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
