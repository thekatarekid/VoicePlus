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

    /// Whether macOS has a real consent dialog for this service.
    ///
    /// **Promptable** (`true`): the `request…` API puts an asynchronous dialog in front of the user —
    /// `AVCaptureDevice.requestAccess(for: .audio)`, `SFSpeechRecognizer.requestAuthorization`,
    /// `CNContactStore.requestAccess`, `EKEventStore.requestFullAccessToEvents`, camera,
    /// notifications. Critically, **calling that API is the only way the app ever appears in its
    /// System Settings list**: those panes have no "+" button, so a user cannot add the app by hand.
    /// Never route a promptable service to a "turn it on in System Settings" recovery screen before
    /// the API has actually been called — that is an unrecoverable dead end (the 1.6.2 microphone
    /// regression), and it stays a dead end after `tccutil reset` because there is no row to toggle.
    ///
    /// **Non-promptable** (`false`): `CGRequestListenEventAccess()` and
    /// `AXIsProcessTrustedWithOptions(prompt:)` return the current authorization synchronously and at
    /// most post a notification. The user must flip the switch themselves — and those two panes do
    /// have "+" / "–" buttons, so the settings-recovery UI is the right (and only) shape for them.
    public var isPromptable: Bool {
        switch self {
        case .microphone: return true
        case .accessibility, .inputMonitoring: return false
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

// MARK: - Code identity (why a granted switch can still read "off")

/// The two facts about the running build that decide what the permission-recovery screen may
/// honestly say. Kept as a plain value type — no Security framework here — so the copy and the
/// relaunch decision are unit-testable without a signed bundle. `PermissionDiagnostics.identity()`
/// builds the live one.
///
/// TCC does not store "VoicePlus may listen to key events". It stores the app's **designated
/// requirement** (`codesign -d -r-`) at the moment the switch is turned on, and re-evaluates that
/// requirement on every later query. An ad-hoc signature with no explicit requirement degrades to
/// `cdhash H"<this exact binary>"`, so the next build fails the stored requirement and tccd answers
/// "not granted" — while System Settings keeps showing the switch as on, because the switch is a
/// different column (`auth_value`) from the requirement (`csreq`). Flipping it rewrites neither.
public struct AppCodeIdentity: Equatable, Sendable {
    /// The designated requirement, exactly as `codesign -d -r-` prints it after `designated => `.
    /// nil when it cannot be read (unsigned, or the Security call failed).
    public var designatedRequirement: String?
    /// Absolute path of the running bundle.
    public var bundlePath: String

    public init(designatedRequirement: String?, bundlePath: String) {
        self.designatedRequirement = designatedRequirement
        self.bundlePath = bundlePath
    }

    /// True when the requirement names this exact binary, so every rebuild is a different app to
    /// TCC and no grant can survive an update. Unknown counts as pinned: never promise stability we
    /// cannot see.
    public var pinsThisBuild: Bool {
        guard let requirement = designatedRequirement?.lowercased() else { return true }
        return requirement.contains("cdhash")
    }

    /// The requirement is a property of the *identity* (bundle id, and a certificate leaf when one
    /// exists), not of the bytes — so a grant made once keeps matching after every rebuild.
    public var isStable: Bool { !pinsThisBuild }

    /// Gatekeeper runs a quarantined, un-notarized app from a randomised read-only path. Grants made
    /// against that path evaporate, and relaunching only produces another translocated copy.
    public var isTranslocated: Bool { bundlePath.contains("/AppTranslocation/") }

    /// What "Quit & Reopen" may actually do.
    public enum RelaunchOutcome: Equatable, Sendable {
        /// Open a fresh instance of this bundle, then terminate this one.
        case relaunch(bundlePath: String)
        /// Refuse: a translocated copy can only relaunch into another translocated copy. The user
        /// has to move the app out of the dmg/Downloads and clear quarantine first.
        case translocated
    }

    public var relaunchOutcome: RelaunchOutcome {
        isTranslocated ? .translocated : .relaunch(bundlePath: bundlePath)
    }

    /// The Terminal one-liner that ends translocation for good. Shown, never run by the app.
    public var dequarantineCommand: String {
        "xattr -dr com.apple.quarantine /Applications/VoicePlus.app"
    }
}
