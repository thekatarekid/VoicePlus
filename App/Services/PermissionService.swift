import AppKit
import AVFoundation
import ApplicationServices
import Foundation
import Security
import Shared

/// Abstracts the three system checks so the orchestrator and tests don't touch TCC directly.
public protocol PermissionChecking: AnyObject {
    func status(of permission: Permission) -> PermissionStatus
    /// Triggers the system prompt (where the OS offers one). Completion carries the refreshed status.
    func request(_ permission: Permission, completion: @escaping (PermissionStatus) -> Void)
}

public extension PermissionChecking {
    func matrix() -> PermissionMatrix {
        Permission.allCases.reduce(into: [:]) { $0[$1] = status(of: $1) }
    }
}

/// Real TCC-backed checks: AVCaptureDevice (mic), AXIsProcessTrustedWithOptions (accessibility),
/// CGPreflightListenEventAccess / CGRequestListenEventAccess (input monitoring).
public final class SystemPermissionChecker: PermissionChecking {
    public init() {}

    public func status(of permission: Permission) -> PermissionStatus {
        switch permission {
        case .microphone:
            // Q10 — through the live probe: re-read every tick, and a fresh capture that worked
            // outranks a stale `.denied` from the status API.
            return MicrophoneStatusProbe.permissionStatus(MicrophoneStatusProbe.shared.probe(.tick))
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .notDetermined
        case .inputMonitoring:
            return CGPreflightListenEventAccess() ? .granted : .notDetermined
        }
    }

    /// Fire-and-forget on macOS: only `true` is trustworthy. `CGRequestListenEventAccess()` and
    /// `AXIsProcessTrustedWithOptions(prompt:)` are *not* blocking consent dialogs — they return the
    /// current authorization synchronously (measured 0.005 s on a first call, 0.000 s after) and at
    /// most post a notification. Once any TCC row exists for the bundle id — which for an ad-hoc
    /// signed build means "any earlier build, because the cdhash changed" — they return `false`
    /// silently forever. So `false` becomes `.awaitingUserAction`, never `.notDetermined`, and the
    /// caller keeps polling `status(of:)` instead of waiting for a callback that never comes.
    public func request(_ permission: Permission, completion: @escaping (PermissionStatus) -> Void) {
        // The notification is only attributed to (and revealed for) a foreground app.
        NSApp?.activate(ignoringOtherApps: true)
        switch permission {
        case .microphone:
            // Microphone is *promptable*: this is a genuine asynchronous consent dialog, and calling
            // it is the only thing that ever puts VoicePlus into Privacy & Security › Microphone —
            // that pane has no "+" button. So report exactly what TCC says afterwards, with three
            // outcomes rather than two: `.granted`, `.denied` (a real Don't Allow — terminal, but the
            // row and its switch now exist), or `.notDetermined` (the dialog never appeared or was
            // dismissed — retryable). Folding the third case into `.awaitingUserAction` is what used
            // to push the microphone into the settings-recovery phase permanently, pointing the user
            // at a list the app was not in and could not be added to.
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard !granted else { completion(.granted); return }
                    completion(self?.status(of: .microphone) ?? .notDetermined)
                }
            }
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            completion(AXIsProcessTrusted() ? .granted : .awaitingUserAction)
        case .inputMonitoring:
            _ = CGRequestListenEventAccess()
            completion(CGPreflightListenEventAccess() ? .granted : .awaitingUserAction)
        }
    }
}

/// Opens the Privacy & Security pane for a permission, trying the modern pane id before the legacy
/// one (still installed on macOS 26 as `Security.prefPane`).
public enum PermissionSettingsOpener {
    /// Notified every time the user is sent to System Settings for a service. `CapabilityWatcher`
    /// subscribes so it knows a trip is in progress, which is the trigger for the "macOS is holding
    /// this grant until VoicePlus restarts" offer (P6).
    ///
    /// A static hook rather than an injected dependency because the three ways the app opens that
    /// pane — the permission orchestrator, `LivePermissionChecker.openSystemSettings`, and the
    /// onboarding screen's button — share nothing else, and every one of them funnels through here.
    public static var onOpened: ((Permission) -> Void)?

    @discardableResult
    public static func open(_ permission: Permission) -> Bool {
        onOpened?(permission)
        for url in permission.settingsURLs where NSWorkspace.shared.open(url) { return true }
        Log.app.warning("could not open System Settings for \(permission.rawValue)")
        return false
    }
}

/// The app's TCC code identity. An ad-hoc signature has no Team ID, so TCC stores a bare
/// `cdhash H"…"` requirement: every rebuild produces a new hash and silently fails to match the
/// stored grant. Logged at launch and shown in the onboarding recovery panel so a stale row is
/// recognisable instead of looking like a broken button.
public enum PermissionDiagnostics {
    public static var bundleIdentifier: String { Bundle.main.bundleIdentifier ?? "unknown" }

    /// Short hex cdhash of the running code, or nil when it cannot be read.
    public static func codeHash() -> String? {
        var codeRef: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &codeRef) == errSecSuccess, let codeRef else { return nil }
        var staticRef: SecStaticCode?
        guard SecCodeCopyStaticCode(codeRef, SecCSFlags(), &staticRef) == errSecSuccess, let staticRef else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticRef, SecCSFlags(rawValue: 0), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let data = dict[kSecCodeInfoUnique as String] as? Data else { return nil }
        return data.map { String(format: "%02x", $0) }.joined()
    }

    /// The app's *designated requirement*, the string TCC actually stores when a switch is turned on
    /// and re-evaluates on every later query — `codesign -d -r-` prints the same thing.
    ///
    /// This is the single most diagnostic fact about a stuck permission. `cdhash H"…"` means the
    /// requirement names one exact binary, so the row the user toggled belongs to whichever build was
    /// installed when they toggled it and can never match again. Anything else (an `identifier`
    /// clause, a `certificate leaf`) is a property of the identity rather than of the bytes, so the
    /// grant survives every rebuild.
    public static func designatedRequirement() -> String? {
        var codeRef: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &codeRef) == errSecSuccess, let codeRef else { return nil }
        var staticRef: SecStaticCode?
        guard SecCodeCopyStaticCode(codeRef, SecCSFlags(), &staticRef) == errSecSuccess, let staticRef else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticRef, SecCSFlags(), &requirement) == errSecSuccess,
              let requirement else { return nil }
        var text: CFString?
        guard SecRequirementCopyString(requirement, SecCSFlags(), &text) == errSecSuccess,
              let text else { return nil }
        return text as String
    }

    /// Live identity of the running build, for the recovery copy and the relaunch decision.
    public static func identity() -> AppCodeIdentity {
        AppCodeIdentity(designatedRequirement: designatedRequirement(),
                        bundlePath: Bundle.main.bundleURL.path)
    }

    public static func summary() -> String {
        "\(bundleIdentifier) cdhash=\(codeHash() ?? "unavailable") dr=\(designatedRequirement() ?? "unavailable")"
    }

    /// One block naming every fact that decides whether a granted switch is honoured, printed to
    /// stdout *and* written to the unified log so it can be read back with
    /// `log show --predicate 'subsystem == "in.adityakatare.voiceplus"'` from a real launch.
    ///
    /// The point is to state the API answers outright. Before this, the only evidence that
    /// `CGPreflightListenEventAccess()` had returned false was an *inference* from an onboarding
    /// phase label; a report that says so in words is what a stuck user can paste.
    public static func report() -> [String] {
        let identity = identity()
        var lines = [
            "permission report: bundle=\(bundleIdentifier)",
            "permission report: path=\(identity.bundlePath)",
            "permission report: cdhash=\(codeHash() ?? "unavailable")",
            "permission report: designatedRequirement=\(identity.designatedRequirement ?? "unavailable")",
            "permission report: identityStable=\(identity.isStable) translocated=\(identity.isTranslocated)",
            // V4.41 — a copy running from a mounted DMG is a *different app* to TCC than the copy in
            // /Applications, so Accessibility can read false with the switch visibly on. Said outright.
            "permission report: mountedVolume=\(identity.isRunningFromMountedVolume) installedCopy=\(identity.installedCopyPath ?? "none")",
            "permission report: AXIsProcessTrusted()=\(AXIsProcessTrusted())",
            "permission report: CGPreflightListenEventAccess()=\(CGPreflightListenEventAccess())",
            "permission report: AVCaptureDevice.authorizationStatus(.audio)=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)",
        ]
        let checker = SystemPermissionChecker()
        for p in Permission.allCases {
            lines.append("permission report: \(p.rawValue)=\(checker.status(of: p).rawValue)")
        }
        return lines
    }

    /// Emits `report()` to both sinks. Returns the lines so a caller can assert on them.
    @discardableResult
    public static func emitReport() -> [String] {
        let lines = report()
        for line in lines {
            print(line)
            Log.app.info("\(line)")
        }
        // V4.41 — loud, because every downstream symptom (no AX trust, AX insertion unavailable,
        // readback that can never confirm) looks like a bug in delivery instead of a launched copy
        // that TCC has never heard of.
        let identity = identity()
        if identity.isRunningFromMountedVolume, let installed = identity.installedCopyPath {
            Log.app.fault("""
                running from a mounted volume (\(identity.bundlePath)) while \(installed) exists — \
                Accessibility is granted per code identity, so this copy may have no grant at all. \
                Quit, eject the volume and open the installed copy.
                """)
        }
        return lines
    }

    /// Headless self-test: `VoicePlus --request-permission microphone`.
    ///
    /// Runs the *real* system request for one service and reports what TCC answered, so a build can
    /// be verified against the tccd log without driving the onboarding UI. This is how the 1.6.2
    /// microphone regression is caught on real hardware: a build that never reaches
    /// `AVCaptureDevice.requestAccess` produces only `preflight=yes` status queries in tccd and no
    /// `AUTHREQ_PROMPTING` line, and no unit test can see that. See Packaging/SIGNING.md.
    ///
    /// Launch it through LaunchServices (`open -n -a VoicePlus.app --args …`), not by running the
    /// executable from a shell: TCC attributes a shell-launched binary to the terminal.
    public static func parseRequestCLI(_ arguments: [String]) -> Permission? {
        guard let i = arguments.firstIndex(of: "--request-permission"), i + 1 < arguments.count else { return nil }
        return Permission(rawValue: arguments[i + 1])
    }

    /// Returns a process exit code: 0 when the service ended up granted, 1 otherwise.
    public static func runRequestCLI(_ permission: Permission) -> Int32 {
        let checker = SystemPermissionChecker()
        let before = checker.status(of: permission)
        Log.app.info("permission self-test: \(summary()) requesting \(permission.rawValue) (was \(before.rawValue))")
        print("before: \(permission.rawValue)=\(before.rawValue) (\(summary()))")
        // `request` answers on the main queue, so the main run loop has to be pumped by hand here —
        // there is no NSApplication in this mode.
        var result: PermissionStatus?
        checker.request(permission) { result = $0 }
        let deadline = Date().addingTimeInterval(120)
        while result == nil, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        let final = result ?? checker.status(of: permission)
        Log.app.info("permission self-test: \(permission.rawValue) -> \(final.rawValue)")
        print("after: \(permission.rawValue)=\(final.rawValue)")
        return final == .granted ? 0 : 1
    }

    /// The command that clears a stale row. Shown for copy/paste — never run from the app.
    public static func resetCommand(for permission: Permission) -> String {
        let service: String
        switch permission {
        case .microphone: service = "Microphone"
        case .accessibility: service = "Accessibility"
        case .inputMonitoring: service = "ListenEvent"
        }
        return "tccutil reset \(service) \(bundleIdentifier)"
    }
}

/// In-memory checker for tests and `swift run` demos without TCC.
public final class MockPermissionChecker: PermissionChecking {
    public var statuses: PermissionMatrix
    public var grantOnRequest: Set<Permission>
    public private(set) var requested: [Permission] = []

    public init(statuses: PermissionMatrix = [:], grantOnRequest: Set<Permission> = []) {
        self.statuses = statuses
        self.grantOnRequest = grantOnRequest
    }

    public func status(of permission: Permission) -> PermissionStatus { statuses[permission] ?? .notDetermined }

    public func request(_ permission: Permission, completion: @escaping (PermissionStatus) -> Void) {
        requested.append(permission)
        let result: PermissionStatus = grantOnRequest.contains(permission) ? .granted : .denied
        statuses[permission] = result
        completion(result)
    }
}

/// Walks the matrix: pre-prompt → system prompt → verify, one permission at a time (T5).
/// UI is injected (`presentPrePrompt`) so the flow is testable headless.
public final class PermissionOrchestrator {
    public enum PrePromptChoice { case proceed, skip }

    public let checker: PermissionChecking
    public var presentPrePrompt: (Permission, @escaping (PrePromptChoice) -> Void) -> Void
    public var openSettings: (Permission) -> Void
    /// Called after `openSettings` so the walk can resume the moment the user flips the switch,
    /// instead of stopping there. The closure polls and invokes its callback once granted; nil (the
    /// default, used by tests) keeps the old stop-and-report behaviour.
    public var watchUntilGranted: ((Permission, @escaping () -> Void) -> Void)?
    /// The permission the *active hotkey backend* needs, or nil when it needs none — which is the
    /// shipping default, and the reason the walk no longer stops on Input Monitoring. See
    /// `HotkeyBackendKind`.
    public var hotkeyRequires: Permission?
    public private(set) var log: [String] = []

    public init(checker: PermissionChecking,
                presentPrePrompt: @escaping (Permission, @escaping (PrePromptChoice) -> Void) -> Void,
                openSettings: @escaping (Permission) -> Void = { PermissionSettingsOpener.open($0) },
                hotkeyRequires: Permission? = HotkeyService.currentRequiredPermission()) {
        self.checker = checker
        self.presentPrePrompt = presentPrePrompt
        self.openSettings = openSettings
        self.hotkeyRequires = hotkeyRequires
    }

    public var matrix: PermissionMatrix { checker.matrix() }

    /// Runs until all granted, or the user skips / a permission is denied. Completion gets the final matrix.
    public func run(completion: @escaping (PermissionMatrix) -> Void) {
        step(skipped: [], completion: completion)
    }

    private func step(skipped: Set<Permission>, completion: @escaping (PermissionMatrix) -> Void) {
        var current = matrix
        for p in skipped { current[p] = .granted } // treated as handled for this run; re-verified on next run
        switch PermissionPlanner.nextStep(current, hotkeyRequires: hotkeyRequires) {
        case .allGranted:
            log.append(skipped.isEmpty ? "all granted" : "done (skipped: \(skipped.map(\.rawValue).sorted()))")
            completion(matrix)
        case .openSettings(let permission):
            log.append("settings:\(permission.rawValue)")
            openSettings(permission)
            resumeAfterSettings(permission, skipped: skipped, completion: completion)
        case .prePrompt(let permission):
            log.append("preprompt:\(permission.rawValue)")
            // Publish what is already granted *before* the pre-prompt window goes up. Until 1.6.5
            // this completion was withheld until the whole walk finished, so a granted Input
            // Monitoring stayed unreported — and the hotkey unarmed — for as long as the user left
            // the Accessibility pre-prompt on screen. Capabilities are independent per permission
            // (`PermissionPlanner.capabilities`), so there is nothing to wait for.
            completion(matrix)
            presentPrePrompt(permission) { [weak self] choice in
                guard let self else { return }
                switch choice {
                case .skip:
                    self.log.append("skip:\(permission.rawValue)")
                    self.step(skipped: skipped.union([permission]), completion: completion)
                case .proceed:
                    self.checker.request(permission) { status in
                        self.log.append("verify:\(permission.rawValue)=\(status.rawValue)")
                        if status == .granted {
                            self.step(skipped: skipped, completion: completion)
                        } else {
                            // Denied, or AX/IM not toggled yet (the usual case — see `request`).
                            // Send the user to Settings and keep watching so this never dead-ends.
                            self.log.append("settings:\(permission.rawValue)")
                            self.openSettings(permission)
                            self.resumeAfterSettings(permission, skipped: skipped, completion: completion)
                        }
                    }
                }
            }
        }
    }

    /// Report now (so capabilities update immediately) and, when a watcher is installed, continue the
    /// walk as soon as the permission is actually granted in System Settings.
    private func resumeAfterSettings(_ permission: Permission, skipped: Set<Permission>,
                                     completion: @escaping (PermissionMatrix) -> Void) {
        completion(matrix)
        guard let watch = watchUntilGranted else { return }
        watch(permission) { [weak self] in
            guard let self else { return }
            self.log.append("granted-after-settings:\(permission.rawValue)")
            self.step(skipped: skipped, completion: completion)
        }
    }
}

/// Polls `status(of:)` on a timer until a permission is granted (or the deadline passes). This is the
/// only public mechanism for Input Monitoring — there is no notification for `kTCCServiceListenEvent`.
@MainActor
public final class PermissionPoller {
    private let checker: PermissionChecking
    private var timer: Timer?
    public var interval: TimeInterval = 0.5
    /// nil = watch until it is granted or cancelled. It used to be 300 s, which is shorter than a
    /// real trip through System Settings (find the pane, find the app, "–", "+", the file picker) —
    /// and when it expired it did so silently, so the walk simply never resumed.
    public var timeout: TimeInterval?

    public init(checker: PermissionChecking) { self.checker = checker }

    public func watch(_ permission: Permission, granted: @escaping () -> Void) {
        cancel()
        guard checker.status(of: permission) != .granted else { granted(); return }
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { t.invalidate(); return }
                if self.checker.status(of: permission) == .granted {
                    t.invalidate(); self.timer = nil
                    Log.app.info("permission granted while polling: \(permission.rawValue)")
                    granted()
                } else if let deadline, Date() >= deadline {
                    Log.app.warning("permission watch for \(permission.rawValue) timed out")
                    t.invalidate(); self.timer = nil
                }
            }
        }
    }

    public func cancel() {
        timer?.invalidate()
        timer = nil
    }
}
