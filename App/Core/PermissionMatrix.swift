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
            return "Accessibility lets VoicePlus type what you said into the app you're using and read the field you're in so it can match the style. Accessibility never takes screenshots."
        case .inputMonitoring:
            return "Optional. VoicePlus only needs this if you switch it to the legacy event-tap listener; the normal dictation key needs no permission at all. Turning it on also means quitting and reopening VoicePlus, because macOS hands this one service over only at launch."
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

    /// The permissions VoicePlus needs no matter how the hotkey is delivered: the microphone to
    /// hear, Accessibility to type the result back. Order matters — mic first (nothing works
    /// without it), Accessibility last (it only affects landing).
    ///
    /// Input Monitoring is deliberately **absent**. Through 1.6.7 it sat in the middle of this list
    /// because the only hotkey mechanism was a `.listenOnly` CGEvent tap. The default mechanism is
    /// now `NSEvent.addGlobalMonitorForEvents`, which consults no TCC service at all (measured — see
    /// `HotkeyBackendKind`), so demanding it of every user was a cost with nothing on the other side
    /// of it: an extra pane to find, a switch macOS only honours after a forced quit-and-relaunch,
    /// and four rounds of debugging when the grant went stale.
    public static let baselineOrder: [Permission] = [.microphone, .accessibility]

    /// Every permission the app knows about, in walk order. Only reached when the active hotkey
    /// backend actually needs Input Monitoring.
    public static let fullOrder: [Permission] = [.microphone, .inputMonitoring, .accessibility]

    /// The permissions to walk, given what the *active hotkey backend* costs.
    /// `hotkeyRequires` is `HotkeyBackendSelector.requiredPermission(for:)` — nil for every binding
    /// the shipped picker can produce.
    public static func order(hotkeyRequires: Permission? = nil) -> [Permission] {
        guard let hotkeyRequires, !baselineOrder.contains(hotkeyRequires) else { return baselineOrder }
        return [.microphone, hotkeyRequires, .accessibility]
    }

    public static func nextStep(_ matrix: PermissionMatrix, hotkeyRequires: Permission? = nil) -> Step {
        for permission in order(hotkeyRequires: hotkeyRequires) {
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

        public init(canCapture: Bool = false, canUseGlobalHotkey: Bool = false, canInjectText: Bool = false) {
            self.canCapture = canCapture
            self.canUseGlobalHotkey = canUseGlobalHotkey
            self.canInjectText = canInjectText
        }

        /// A hotkey the active backend cannot deliver falls back to the menu-bar "Start dictation"
        /// item. With the default (permission-free) backend this is never true.
        public var needsMenuFallback: Bool { canCapture && !canUseGlobalHotkey }
    }

    /// What the app can do with the current grants.
    ///
    /// `hotkeyRequires` is the permission the *active hotkey backend* needs, or nil when it needs
    /// none — which is the shipping default. A backend that consults no TCC service can always be
    /// armed, so `canUseGlobalHotkey` is unconditionally true there; passing `.inputMonitoring`
    /// restores the pre-1.6.8 gate for the `hotkeyForceEventTap` escape hatch.
    public static func capabilities(_ matrix: PermissionMatrix, hotkeyRequires: Permission? = nil) -> Capabilities {
        Capabilities(
            canCapture: matrix[.microphone] == .granted,
            canUseGlobalHotkey: hotkeyRequires.map { matrix[$0] == .granted } ?? true,
            canInjectText: matrix[.accessibility] == .granted
        )
    }

    public static func missing(_ matrix: PermissionMatrix, hotkeyRequires: Permission? = nil) -> [Permission] {
        order(hotkeyRequires: hotkeyRequires).filter { matrix[$0] != .granted }
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

// MARK: - Does a mid-session grant reach a running app? (P6)

public extension Permission {
    /// Whether a grant made **while VoicePlus is already running** becomes visible to it without a
    /// relaunch.
    ///
    /// This is Apple's answer, not ours. `PrivacyTCCServices.plist` inside
    /// `/System/Library/PreferencePanes/Security.prefPane` carries a `quitAllowTitleForAppName`
    /// string for `kTCCServiceMicrophone` and `kTCCServiceListenEvent` — the two alerts the 1.6.6
    /// user photographed, worded as flat assertions ("will not have access…", "will not be able
    /// to…", not the hedged "may not" that screen recording gets) — and has **no entry at all** for
    /// `kTCCServiceAccessibility`. macOS never asks you to quit for Accessibility.
    ///
    /// Corroborated on the reporting machine (macOS 26.6.2) by three consecutive VoicePlus processes
    /// against tccd's own grant timestamps:
    /// * Microphone was granted 6 s into PID 76635's life; that process polled once a second for its
    ///   remaining 25 s and never stopped reading `denied`.
    /// * Input Monitoring was granted 16 s into PID 76861's life; it read `notDetermined` for its
    ///   remaining 18 s.
    /// * Each *following* process read the new value on its very first query.
    /// * In the same window, in the same build, Accessibility flipped **inside** a running process
    ///   in about a second, via the `com.apple.accessibility.api` distributed notification.
    /// A control ruled out the obvious confound: a background `LSUIElement` process ticked a
    /// `.default`-mode 1 Hz timer 49 times in 50 s, so nothing was App-Napped.
    ///
    /// What this deliberately does **not** claim: that the underlying capability is dead. Only that
    /// the status API stays stale for the life of the process — and since every VoicePlus feature is
    /// gated on that status, for this app the two are the same thing. Nothing here should ever be
    /// upgraded to a claim about capture or event delivery without a measurement of *those*.
    var grantReachesRunningApp: Bool {
        switch self {
        case .accessibility: return true
        case .microphone, .inputMonitoring: return false
        }
    }

    /// macOS' own sentence for this service, from `Security.prefPane`'s `Localizable.loctable` (en)
    /// with the app name filled in — so our copy agrees with the alert the user just dismissed
    /// instead of contradicting it. nil for Accessibility, which has no such string.
    var systemQuitWarning: String? {
        switch self {
        case .microphone:
            return "“VoicePlus” will not have access to your microphone until it is quit."
        case .inputMonitoring:
            return "“VoicePlus” will not be able to monitor input from your keyboard until it is quit."
        case .accessibility:
            return nil
        }
    }
}

/// Decides when offering "Quit & Reopen" is honest, and for which service.
///
/// Pure and clock-injected, so the rule is a unit test rather than a thing that can only be seen by
/// toggling switches on a real Mac.
///
/// The rule has to thread a needle. Offering a relaunch whenever a permission is missing nags every
/// user who simply hasn't granted it yet; offering it only after `CapabilityWatcher.onTapProvenDead`
/// — which is what 1.6.6 shipped — can never fire in the case that actually happens, because that
/// path requires the tap to have been armed and `HotkeyService.start()` refuses to arm while
/// `CGPreflightListenEventAccess()` is false, which is exactly the stale value the relaunch would
/// fix. So the trigger is the moment where the user's own action makes the offer meaningful: they
/// were sent to System Settings for a service macOS only hands over at launch, they came back, and
/// it still reads off.
public struct RelaunchAdvisor: Equatable, Sendable {
    /// Seconds after the user returns to VoicePlus before a still-ungranted service is called out.
    /// Long enough not to fire on someone who alt-tabbed through Settings without touching anything;
    /// short enough to be the next thing they see.
    public static let grace: TimeInterval = 3

    /// When we last sent the user to System Settings for each service, this process.
    public private(set) var sentToSettings: [Permission: Date] = [:]
    /// When VoicePlus last came back to the foreground.
    public private(set) var becameActiveAt: Date?
    /// Services already advised, so the offer is made once per trip rather than once per tick.
    public private(set) var advised: Set<Permission> = []

    public init() {}

    /// Only these can ever produce an offer: a service macOS re-reads live never needs a relaunch,
    /// and saying otherwise is the 1.6.5 mistake in the opposite direction.
    public static let candidates: [Permission] = Permission.allCases
        .filter { !$0.grantReachesRunningApp }
        .sorted { $0.rawValue < $1.rawValue }

    public mutating func noteSentToSettings(_ permission: Permission, at now: Date) {
        guard !permission.grantReachesRunningApp else { return }
        sentToSettings[permission] = now
        advised.remove(permission)
    }

    public mutating func noteBecameActive(at now: Date) { becameActiveAt = now }

    /// The services that have *newly* earned a relaunch offer. Returns each one once; a service that
    /// becomes granted is forgotten, so a later trip through Settings can advise again.
    public mutating func evaluate(matrix: PermissionMatrix, now: Date) -> [Permission] {
        var newly: [Permission] = []
        for permission in Self.candidates {
            guard let sent = sentToSettings[permission] else { continue }
            if matrix[permission] == .granted {
                // It landed live after all — forget everything, and never claim it didn't.
                sentToSettings.removeValue(forKey: permission)
                advised.remove(permission)
                continue
            }
            guard !advised.contains(permission) else { continue }
            // The user has to have come back *after* being sent out, and then settled.
            guard let active = becameActiveAt, active >= sent, now.timeIntervalSince(active) >= Self.grace else { continue }
            advised.insert(permission)
            newly.append(permission)
        }
        return newly
    }
}

// MARK: - G2 · optional permissions (Screen Recording for the deixis box)

/// Permissions VoicePlus can use but never needs. They sit beside `Permission`, not in it, on
/// purpose: `Permission.allCases` is the *required* walk (onboarding, `PermissionPlanner`,
/// `RelaunchAdvisor`, the recovery screen), and an optional grant must never block dictation or
/// appear as something missing. A declined optional permission degrades one feature, quietly.
public enum OptionalPermission: String, CaseIterable, Codable, Sendable, Identifiable {
    /// V4.29 / V4.53 — the screenshot of a drawn box and text recognition over it.
    case screenRecording
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .screenRecording: return "Screen Recording"
        }
    }

    /// The one-line explanation shown the first time it is needed (a box was drawn), before the
    /// system asks.
    public var rationale: String {
        switch self {
        case .screenRecording:
            return "Optional. Lets VoicePlus read the text inside a box you draw when the app doesn't share it — the image stays in memory for that dictation and is never saved."
        }
    }

    /// `CGRequestScreenCaptureAccess()` shows its alert once and returns the current state at
    /// once; the user flips the switch in System Settings. Same shape as Input Monitoring.
    public var isPromptable: Bool { false }

    /// `revealElementKeyName` for System Settings › Privacy & Security.
    public var settingsAnchor: String {
        switch self {
        case .screenRecording: return "Privacy_ScreenCapture"
        }
    }

    public var settingsURLs: [URL] { PermissionSettingsLink.urls(anchor: settingsAnchor) }

    /// Apple's `PrivacyTCCServices.plist` carries a (hedged, "may not") quit string for screen
    /// capture, so a mid-session grant is not promised to reach a running app.
    public var grantReachesRunningApp: Bool { false }
}

/// G2 — the Screen Recording decision each time a box is drawn, as a pure state machine.
///
/// * Granted → capture the box and recognise its text.
/// * Never asked → show the one-line explanation and ask (once, ever); this box carries AX text
///   only, because the grant does not reach it in time.
/// * Asked before, or denied → AX text only, and the pill says "Screen text isn't available".
public struct ScreenRecordingConsent: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        /// Take the screenshot; OCR when the tree has no text.
        case capture
        /// First box ever without the grant: explain, then call the system request.
        case explainAndRequest(explanation: String)
        /// No screenshot, no OCR: the box carries AX text only.
        case axOnly(notice: String)
    }

    /// The pill's line whenever a box goes without screen text.
    public static let unavailableNotice = "Screen text isn't available"

    public private(set) var status: PermissionStatus
    /// Whether the system request has ever been made (persisted by the caller).
    public private(set) var hasRequested: Bool

    public init(status: PermissionStatus = .notDetermined, hasRequested: Bool = false) {
        self.status = status
        self.hasRequested = hasRequested
    }

    /// A box was drawn. `preflight` is `CGPreflightScreenCaptureAccess()` read now.
    public mutating func boxDrawn(preflight granted: Bool) -> Decision {
        if granted {
            status = .granted
            return .capture
        }
        if status == .granted { status = .denied }   // revoked since we last looked
        guard hasRequested else {
            hasRequested = true
            status = .awaitingUserAction
            return .explainAndRequest(explanation: OptionalPermission.screenRecording.rationale)
        }
        if status == .notDetermined { status = .denied }
        return .axOnly(notice: Self.unavailableNotice)
    }

    /// What `CGRequestScreenCaptureAccess()` returned (true only when already granted).
    public mutating func requestReturned(granted: Bool) {
        status = granted ? .granted : .awaitingUserAction
    }

    /// Screen text can be used for boxes drawn now.
    public var allowsCapture: Bool { status == .granted }
}
