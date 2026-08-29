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
