import AppKit
import Combine
import Foundation
import Shared

/// Drives `OnboardingStateMachine` with real side effects from `OnboardingDependencies`.
@MainActor
public final class OnboardingViewModel: ObservableObject {
    @Published public private(set) var machine: OnboardingStateMachine
    @Published public var micLevel: Float = 0
    @Published public var dictationPreview: String = ""
    @Published public var isDictating = false
    @Published public var contactsOutcome: ContactsImportOffer.Outcome?
    @Published public var showContactsOffer = false

    public let deps: OnboardingDependencies
    public let contactsOffer: ContactsImportOffer
    public var onFinished: ((Bool) -> Void)?

    private var micCancellable: AnyCancellable?
    private var downloadTask: Task<Void, Never>?
    private var dictationTask: Task<Void, Never>?
    private var permissionPollTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var micWatchdog: Timer?
    private var settleTimer: Timer?

    /// How long capture may be up with zero audio before the screen says so rather than blaming volume.
    public static let noAudioGrace: TimeInterval = 2.5
    /// Poll cadence while the permissions step is on screen — the only way to notice a grant made in
    /// System Settings, since `kTCCServiceListenEvent` has no notification.
    public static let permissionPollInterval: TimeInterval = 0.5
    static func requestedKey(_ p: OnboardingPermission) -> String { "onboarding.requested.\(p.rawValue)" }

    public init(dependencies: OnboardingDependencies) {
        deps = dependencies
        var initial: [OnboardingPermission: OnboardingPermissionStatus] = [:]
        var requested: Set<OnboardingPermission> = []
        for p in OnboardingPermission.allCases {
            initial[p] = dependencies.permissions.status(of: p)
            if dependencies.settingsStore.bool(Self.requestedKey(p)) == true { requested.insert(p) }
        }
        machine = OnboardingStateMachine(initialStatuses: initial, alreadyRequested: requested)
        contactsOffer = ContactsImportOffer(store: dependencies.contacts, database: dependencies.database,
                                            settings: dependencies.settingsStore)
        observeAppActivation()
    }

    deinit {
        permissionPollTimer?.invalidate()
        micWatchdog?.invalidate()
        settleTimer?.invalidate()
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }

    public var step: OnboardingStateMachine.Step { machine.step }

    /// Last (permission, phase) pair we logged, so the 0.5 s poll cannot spam the log: a tick that
    /// changes nothing produces nothing.
    private var loggedPermissionFocus: (permission: OnboardingPermission, phase: OnboardingStateMachine.PermissionPhase)?

    public func send(_ event: OnboardingStateMachine.Event) {
        let before = machine.step
        let effects = machine.handle(event)
        for effect in effects { perform(effect) }
        if machine.step != before || before == .permissions { syncPermissionPolling() }
        logPermissionTransition()
    }

    /// FIX B — one line whenever a permission step is entered or advanced. Without it the phase
    /// chosen by `initialPhase` was never recorded anywhere, so the 1.6.2 microphone regression
    /// (opening on the settings-recovery phase, where the Allow button that calls
    /// `AVCaptureDevice.requestAccess` does not exist) was invisible in the user's own logs — the
    /// happy path logged nothing at all, and a verifier could not tell the two phases apart.
    private func logPermissionTransition() {
        let focus = machine.permissionFocus
        guard focus?.permission != loggedPermissionFocus?.permission
                || focus?.phase != loggedPermissionFocus?.phase else { return }
        loggedPermissionFocus = focus
        guard let focus else { return }
        let status = machine.statuses[focus.permission] ?? .notDetermined
        Log.app.info("\(OnboardingStateMachine.transitionLog(permission: focus.permission, status: status, phase: focus.phase))")
    }

    // MARK: Permission polling

    /// Keeps a 0.5 s poll running for exactly as long as the permissions step is visible, so the
    /// checkmark flips the instant the user toggles the switch in System Settings.
    private func syncPermissionPolling() {
        guard step == .permissions, let p = machine.currentPermission else {
            permissionPollTimer?.invalidate(); permissionPollTimer = nil
            return
        }
        guard permissionPollTimer == nil else { return }
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: Self.permissionPollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollCurrentPermission() }
        }
        _ = p
    }

    private func pollCurrentPermission() {
        guard step == .permissions, let p = machine.currentPermission else {
            permissionPollTimer?.invalidate(); permissionPollTimer = nil
            return
        }
        let fresh = deps.permissions.status(of: p)
        if fresh != machine.statuses[p] {
            Log.app.info("onboarding poll: \(p.rawValue) \(self.machine.statuses[p]?.rawValue ?? "unknown") → \(fresh.rawValue)")
        }
        send(.statusRefreshed(p, fresh))
    }

    /// The user comes back from System Settings; re-check immediately rather than waiting for the tick.
    private func observeAppActivation() {
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollCurrentPermission() }
        }
    }

    /// Called by the window controller so closing mid-check never leaves capture running.
    public func teardown() {
        permissionPollTimer?.invalidate(); permissionPollTimer = nil
        micWatchdog?.invalidate(); micWatchdog = nil
        settleTimer?.invalidate(); settleTimer = nil
        micCancellable = nil
        deps.micLevel.stopMonitoring()
        downloadTask?.cancel()
        dictationTask?.cancel()
    }

    // MARK: Side effects

    private func perform(_ effect: OnboardingStateMachine.SideEffect) {
        switch effect {
        case .requestPermission(let p):
            Task { [weak self] in
                guard let self else { return }
                let status = await deps.permissions.request(p)
                send(.permissionResult(p, status))
            }
        case .checkPermission(let p):
            send(.permissionResult(p, deps.permissions.status(of: p)))
        case .openSystemSettings(let p):
            deps.permissions.openSystemSettings(for: p)
        case .rememberRequested(let p):
            deps.settingsStore.set(true, for: Self.requestedKey(p))
        case .forgetRequested(let p):
            Log.app.info("onboarding: \(p.rawValue) is notDetermined again — clearing the stale asked-once flag")
            deps.settingsStore.set(false, for: Self.requestedKey(p))
        case .startMicMonitoring:
            micLevel = 0
            // Subscribe *before* starting: a publisher that emits synchronously during start()
            // would otherwise lose its first values (and the failure, which arrives immediately).
            micCancellable = deps.micLevel.signalPublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] signal in
                    guard let self else { return }
                    switch signal {
                    case .starting:
                        break
                    case .level(let level):
                        let first = machine.micLevelEvents == 0
                        micLevel = level
                        send(.micLevel(level))
                        if first { startSettleTimer() }
                    case .failed(let reason):
                        micLevel = 0
                        send(.micFailed(reason))
                    }
                }
            deps.micLevel.startMonitoring()
            startMicWatchdog()
        case .stopMicMonitoring:
            micWatchdog?.invalidate(); micWatchdog = nil
            settleTimer?.invalidate(); settleTimer = nil
            micCancellable = nil
            deps.micLevel.stopMonitoring()
        case .selectModel(let tier):
            deps.models.select(tier)
        case .startDownload(let tier):
            guard !deps.models.isInstalled(tier) else { send(.downloadFinished); return }
            downloadTask?.cancel()
            downloadTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await deps.models.download(tier) { progress in
                        Task { @MainActor [weak self] in self?.send(.downloadProgress(progress)) }
                    }
                    send(.downloadFinished)
                } catch {
                    send(.downloadFailed(error.localizedDescription))
                }
            }
        case .beginGuidedDictation:
            break  // user holds the key / presses the button; see `runGuidedDictation`
        case .finish(let skipped):
            deps.settingsStore.set(true, for: SettingsKeys.onboardingCompleted)
            showContactsOffer = !contactsOffer.alreadyOffered
            onFinished?(skipped)
        }
    }

    public func openSettings(for p: OnboardingPermission) { perform(.openSystemSettings(p)) }

    /// Says "nothing is arriving" instead of "very quiet" when capture reported success but the tap
    /// never fired — the exact signature of a stale/denied microphone grant.
    private func startMicWatchdog() {
        micWatchdog?.invalidate()
        micWatchdog = Timer.scheduledTimer(withTimeInterval: Self.noAudioGrace, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.machine.step == .micCheck else { return }
                if self.machine.micLevelEvents == 0 {
                    Log.app.warning("mic check: no audio after \(Self.noAudioGrace)s of capture")
                    self.send(.micNoAudio)
                }
            }
        }
    }

    /// Starts when the *first* real block arrives, so "too quiet" is only ever said after
    /// `settleSeconds` of actual audio — never about audio that never came.
    private func startSettleTimer() {
        settleTimer?.invalidate()
        settleTimer = Timer.scheduledTimer(withTimeInterval: OnboardingStateMachine.settleSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.machine.step == .micCheck else { return }
                self.send(.micSettled)
            }
        }
    }

    /// Copy/paste helper for the stale-TCC recovery panel; the app never runs `tccutil` itself.
    public func copyResetCommand(for p: OnboardingPermission) {
        let command = PermissionDiagnostics.resetCommand(for: p.core)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    /// Copy/paste helper for the translocation escape hatch; the app never runs `xattr` itself.
    public func copyDequarantineCommand(identity: AppCodeIdentity = PermissionDiagnostics.identity()) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(identity.dequarantineCommand, forType: .string)
    }

    /// "Quit & Reopen": open a second instance of this bundle, then terminate this one.
    ///
    /// Deliberately **not** the headline cure. Measured on the reporting machine (macOS 26.6.2): a
    /// brand-new process of the installed app still read `AXIsProcessTrusted() == false` and
    /// `CGPreflightListenEventAccess() == false` while both switches were on, because the failure is
    /// a stored-requirement mismatch that tccd re-evaluates from scratch on every query — there is no
    /// per-process cache to defeat. It stays offered as cheap insurance for the cases a restart *can*
    /// fix (the bundle was replaced under the running process; a row that was just re-added), and it
    /// refuses outright from a translocated copy, where relaunching only makes another temporary copy.
    @discardableResult
    public func relaunchApp(identity: AppCodeIdentity = PermissionDiagnostics.identity(),
                            relauncher: AppRelaunching = NSWorkspaceRelauncher()) -> AppCodeIdentity.RelaunchOutcome {
        let outcome = identity.relaunchOutcome
        switch outcome {
        case .translocated:
            Log.app.warning("relaunch refused: running translocated from \(identity.bundlePath)")
        case .relaunch(let path):
            Log.app.info("relaunching \(path) at the user's request")
            relauncher.relaunch(bundlePath: path)
        }
        return outcome
    }

    /// Runs one utterance through the engine so the last step is *doing*, not watching.
    public func runGuidedDictation() {
        guard !isDictating else { return }
        isDictating = true
        dictationPreview = ""
        dictationTask = Task { [weak self] in
            guard let self else { return }
            let engine = deps.engine
            let events = engine.events()
            let consumer = Task { [weak self] in
                for await event in events {
                    if case .partial(let spans) = event {
                        await MainActor.run { self?.dictationPreview = spans.map(\.text).joined(separator: " ") }
                    }
                }
            }
            do {
                try await engine.start(prewarm: true)
                let spans = try await engine.stop()
                let text = spans.map(\.text).joined(separator: " ")
                dictationPreview = text
                send(.dictationLanded(text))
            } catch {
                send(.dictationLanded(""))
            }
            consumer.cancel()
            isDictating = false
        }
    }

    /// Headless self-test for the FIX B phase line: `VoicePlus --onboarding-selftest`.
    ///
    /// Same rationale as `PermissionDiagnostics.runRequestCLI` — the thing worth checking is what a
    /// *build* writes to the log on the real code path, and no unit test can see that. This walks
    /// the real view model from welcome through every permission with the **live** TCC checker, so
    /// each `onboarding: <permission> status=… phase=…` line lands in the log with no window, no
    /// click, and (because `.next` only ever advances) no authorization request.
    @discardableResult
    public static func runPhaseSelfTest() -> Int32 {
        // The identity block first: which binary this is, what requirement TCC will evaluate it
        // against, and what the two non-promptable APIs answer *in this fresh process*. Those three
        // facts decide everything the permission screens can honestly say, and none of them were
        // previously stated anywhere — they had to be inferred from a phase label.
        PermissionDiagnostics.emitReport()
        var deps = OnboardingDependencies.mock()
        deps.permissions = LivePermissionChecker(checker: SystemPermissionChecker())
        // The real persisted `onboarding.requested.*` flags, because a stale one combined with a
        // live notDetermined status *was* the 1.6.2 dead end — a self-test over an empty store
        // could never reproduce the case it exists to expose. Writes are dropped so reporting on
        // the state can never change it.
        deps.settingsStore = ReadOnlySettingsStore(UserDefaultsSettingsStore())
        let vm = OnboardingViewModel(dependencies: deps)
        vm.send(.next)
        while vm.step == .permissions { vm.send(.next) }
        vm.teardown()
        return 0
    }

    public func acceptContactsImport() {
        Task { [weak self] in
            guard let self else { return }
            contactsOutcome = await contactsOffer.accept()
            showContactsOffer = false
        }
    }

    public func declineContactsImport() {
        contactsOutcome = contactsOffer.decline()
        showContactsOffer = false
    }
}

/// Injected so the relaunch *decision* can be tested without actually quitting the test process.
public protocol AppRelaunching: AnyObject {
    func relaunch(bundlePath: String)
}

/// Opens a fresh instance and then terminates this one. `createsNewApplicationInstance` is required:
/// without it LaunchServices simply activates the process that is already running, and nothing
/// restarts.
public final class NSWorkspaceRelauncher: AppRelaunching {
    public init() {}

    public func relaunch(bundlePath: String) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: bundlePath),
                                           configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error {
                    Log.app.error("relaunch failed: \(error.localizedDescription)")
                    return
                }
                NSApp.terminate(nil)
            }
        }
    }
}

/// Records the request instead of performing it.
public final class MockRelauncher: AppRelaunching {
    public private(set) var relaunched: [String] = []
    public init() {}
    public func relaunch(bundlePath: String) { relaunched.append(bundlePath) }
}
