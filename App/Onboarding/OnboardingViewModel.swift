import AppKit
import Combine
import Engine
import Foundation
import Shared

/// Drives `OnboardingStateMachine` with real side effects from `OnboardingDependencies`.
@MainActor
public final class OnboardingViewModel: ObservableObject {
    @Published public private(set) var machine: OnboardingStateMachine
    @Published public var micLevel: Float = 0
    @Published public var dictationPreview: String = ""
    /// True while the capture window is open — i.e. between the two presses of the dictation button.
    @Published public private(set) var isDictating = false
    /// True from the moment Stop is pressed until the verdict is in. The button is disabled here:
    /// a second press would otherwise start a second `engine.stop()`, which throws `notListening`
    /// and would overwrite a perfectly good result with a failure the user did not cause.
    @Published public private(set) var isFinalizing = false
    /// When the install started, so the line under the bar can estimate what is left.
    @Published public private(set) var downloadStartedAt: Date?
    @Published public var contactsOutcome: ContactsImportOffer.Outcome?
    @Published public var showContactsOffer = false
    /// Result of the last "Remove the old entry" press, so the panel can say what happened instead
    /// of looking like nothing did.
    @Published public var rowResetOutcome: PermissionRowResetOutcome?

    public let deps: OnboardingDependencies
    public let contactsOffer: ContactsImportOffer
    public var onFinished: ((Bool) -> Void)?

    private var micCancellable: AnyCancellable?
    /// The one install task. One stack, one download — the per-option dictionary went with the
    /// picker in R6.1.
    private var downloadTask: Task<Void, Never>?
    private var dictationTask: Task<Void, Never>?
    private var dictationEvents: Task<Void, Never>?
    private var dictationWatchdog: Timer?
    private var permissionPollTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var micWatchdog: Timer?
    private var settleTimer: Timer?

    /// How long capture may be up with zero audio before the screen says so rather than blaming volume.
    public static let noAudioGrace: TimeInterval = 2.5
    /// A guided dictation that is never stopped by hand stops itself here, so a forgotten window
    /// cannot leave the microphone open behind the onboarding screen.
    public static let maxDictationSeconds: TimeInterval = 30
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
        // The walk is as long as the hotkey backend makes it. `hotkeyRequires` is nil for every
        // binding the shipped picker can produce, so the Input Monitoring screen simply is not part
        // of onboarding any more.
        machine = OnboardingStateMachine(initialStatuses: initial, alreadyRequested: requested,
                                         permissionOrder: OnboardingPermission.order(hotkeyRequires: dependencies.hotkeyRequiresPermission))
        contactsOffer = ContactsImportOffer(store: dependencies.contacts, database: dependencies.database,
                                            settings: dependencies.settingsStore)
        observeAppActivation()
    }

    deinit {
        permissionPollTimer?.invalidate()
        micWatchdog?.invalidate()
        settleTimer?.invalidate()
        dictationWatchdog?.invalidate()
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

    /// Refreshes **all three** statuses, not only the focused one.
    ///
    /// The checklist at the bottom of the screen draws a dot per permission from `machine.statuses`,
    /// and until 1.6.5 only the focused permission was ever re-read — so a permission the user
    /// granted while a *different* one was in focus kept an empty dot until the walk happened to
    /// reach it. Asking about all three costs three mach round trips and removes a whole class of
    /// "the app is stuck" misreadings. The focused one goes last, because a grant there advances the
    /// step and the permission it advances to should already be up to date when it does.
    ///
    /// What polling can **not** do (corrected in 1.6.7): notice a Microphone or Input Monitoring
    /// grant made while this process is running. macOS withholds those from an already-running app —
    /// measured, and stated in macOS' own "…until it is quit" alerts — so those two statuses are
    /// frozen for the life of the process no matter how often they are read. That is what the
    /// per-service `liveNote` and the "Quit & Reopen" button are for; the poll still catches
    /// Accessibility, and catches everything after a relaunch.
    func pollCurrentPermission() {
        guard step == .permissions, let current = machine.currentPermission else {
            permissionPollTimer?.invalidate(); permissionPollTimer = nil
            return
        }
        for p in OnboardingPermission.allCases where p != current { refreshStatus(p) }
        refreshStatus(current)
    }

    private func refreshStatus(_ p: OnboardingPermission) {
        let fresh = deps.permissions.status(of: p)
        if fresh != machine.statuses[p] {
            Log.app.notice("onboarding poll: \(p.rawValue) \(self.machine.statuses[p]?.rawValue ?? "unknown") → \(fresh.rawValue)")
        }
        send(.statusRefreshed(p, fresh))
    }

    /// The corroborating grants the recovery copy is allowed to mention: other non-promptable
    /// services that macOS is honouring *right now*, for this same signature. See `RecoveryEvidence`.
    public func recoveryEvidence(for p: OnboardingPermission) -> OnboardingPermission.RecoveryEvidence {
        let others = OnboardingPermission.allCases.filter {
            $0 != p && !$0.isPromptable && deps.permissions.status(of: $0) == .granted
        }
        return .init(corroboratingGrants: others)
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
        dictationWatchdog?.invalidate(); dictationWatchdog = nil
        micCancellable = nil
        deps.micLevel.stopMonitoring()
        downloadTask?.cancel()
        downloadTask = nil
        dictationTask?.cancel()
        dictationEvents?.cancel(); dictationEvents = nil
        // Closing the window mid-utterance must release the microphone, not leave the engine
        // listening behind a screen that is gone.
        if isDictating {
            isDictating = false
            isFinalizing = false
            let engine = deps.engine
            Task { await engine.cancel() }
        }
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
            // Provenance before anything else. A source that is not live capture is refused outright
            // — the meter stays at zero and the screen says the check cannot be completed, instead
            // of animating someone else's numbers. `AppContainer` never builds such a source; this
            // is the structural guarantee that it could not pass the step if it did.
            guard deps.micLevel.isRealCapture else {
                Log.app.error("onboarding mic check: level source is not live capture — refusing to meter")
                send(.micCaptureBegan(real: false))
                return
            }
            send(.micCaptureBegan(real: true))
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
        case .checkModelPresence:
            send(.modelPresenceChanged(deps.models.isStackInstalled))
        case .cancelDownload:
            downloadTask?.cancel()
            downloadTask = nil
            downloadStartedAt = nil
            Log.app.notice("onboarding: model install cancelled by the user")
        case .startDownload:
            // Nothing missing, or a fetch already running: schedule no second download. This is the
            // whole of "existing installs are kept" on the app side — the step can be entered as
            // often as the user likes and it never re-fetches what is on disk.
            guard !deps.models.isStackInstalled else { send(.downloadFinished); return }
            guard downloadTask == nil else { return }
            downloadStartedAt = Date()
            Log.app.notice("onboarding: installing \(ModelStack.displayNames.joined(separator: " + ")) (\(ByteText.short(deps.models.remainingStackBytes)) still to fetch)")
            downloadTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await deps.models.downloadStack { progress in
                        Task { @MainActor [weak self] in self?.send(.downloadProgress(progress)) }
                    }
                    Log.app.notice("onboarding: model install finished")
                    downloadTask = nil
                    send(.downloadFinished)
                } catch is CancellationError {
                    // The user pressed Cancel; the state machine already moved back to "not
                    // started". Reporting a failure here would blame them for their own choice.
                    downloadTask = nil
                    return
                } catch {
                    guard !Task.isCancelled else { downloadTask = nil; return }
                    // `localizedDescription` on a bare Swift enum is a generic bridge string; this
                    // is the same reason the pill used to show "invalidAudioData".
                    let reason = EngineMessage.describe(error)
                    Log.app.error("onboarding: model install failed — \(reason)")
                    downloadTask = nil
                    send(.downloadFailed(reason))
                }
            }
        case .checkRecognizerReadiness:
            refreshReadiness()
        case .beginGuidedDictation:
            break  // user presses the button; see `startGuidedDictation`
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

    /// Puts the text the dictation test heard on the clipboard — on request, never behind the
    /// user's back, since a test they ran to see whether dictation works should not quietly replace
    /// whatever they had copied.
    public func copyDictationText() {
        guard let text = machine.heardText, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Copy/paste helper for the stale-TCC recovery panel; the app never runs `tccutil` itself.
    public func copyResetCommand(for p: OnboardingPermission) {
        let command = PermissionDiagnostics.resetCommand(for: p.core)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    /// Removes VoicePlus' own entry for one service — the same `tccutil reset` the panel has always
    /// offered for copy/paste, run for the user.
    ///
    /// This collapses the recovery from four fiddly steps to two: with the entry gone, the list no
    /// longer contains VoicePlus, so "select the right row, press –" disappears and only "+ and
    /// switch it on" is left. The caller only exposes it from the escalated non-promptable phase,
    /// where the service is already not granted, so no working grant can be destroyed by pressing it.
    @discardableResult
    public func resetPermissionRow(for p: OnboardingPermission,
                                   using reset: PermissionRowResetting = TCCUtilRowReset()) -> PermissionRowResetOutcome {
        let outcome = reset.reset(p.core)
        rowResetOutcome = outcome
        switch outcome {
        case .removed, .noEntry:
            // The status can only have gone *down* (granted is impossible after a reset), and the
            // phase must not keep claiming a stale entry that is now gone.
            refreshStatus(p)
        case .failed(let reason):
            Log.app.error("could not remove the \(p.rawValue) entry: \(reason)")
        }
        return outcome
    }

    /// Copy/paste helper for the translocation escape hatch; the app never runs `xattr` itself.
    public func copyDequarantineCommand(identity: AppCodeIdentity = PermissionDiagnostics.identity()) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(identity.dequarantineCommand, forType: .string)
    }

    /// "Quit & Reopen": open a second instance of this bundle, then terminate this one.
    ///
    /// Offered for Microphone and Input Monitoring, never for Accessibility, and never from a
    /// translocated copy — where relaunching only produces another temporary copy. Corrected in
    /// 1.6.7; 1.6.6 had this backwards for two services out of three.
    ///
    /// * **Not a cure for a stale TCC row.** A brand-new process still read
    ///   `AXIsProcessTrusted() == false` and `CGPreflightListenEventAccess() == false` while both
    ///   switches were on, because that failure is a stored-requirement mismatch tccd re-evaluates
    ///   from scratch on every query. There is no per-process cache to defeat, so restarting cannot
    ///   fix it. That is why this stays a *secondary* button under the remove-and-re-add steps.
    /// * **The cure for a grant that landed mid-session, for two services.** Measured on the
    ///   reporting machine: Microphone was granted 6 s into a process's life and that process read
    ///   `denied` for its remaining 25 s; Input Monitoring was granted 16 s in and read
    ///   `notDetermined` for its remaining 18 s; each following process read the new value at once.
    ///   macOS says the same thing in its own alert.
    /// * **Never for Accessibility.** The user's toggle made the already-running app re-query tccd
    ///   213 ms later, and macOS ships no quit string for it at all
    ///   (`ACCESSIBILITY_QUIT_ALLOW_TITLE` does not exist in the Privacy pane's strings, while 25
    ///   other services have one).
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

    // MARK: Guided dictation

    /// Which recogniser would run right now, and whether the test may be offered at all.
    public var dictationGate: GuidedDictationGate.Decision {
        GuidedDictationGate.decide(readiness: machine.readiness, download: machine.download)
    }

    /// The line under the bar: bytes, percent and an estimate once one means anything.
    public var downloadLine: String? {
        guard case .downloading(let progress) = machine.download else { return nil }
        let elapsed = downloadStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        return DownloadProgressText.line(progress, elapsed: elapsed)
    }

    /// What the stack costs from here. Counts only the models actually missing, so a user who
    /// already has Parakeet TDT v3 is told about the EOU model alone rather than 900 MB again.
    public var remainingLabel: String { ByteText.short(deps.models.remainingStackBytes) }

    /// The models being installed, named — the friendly words ("Balanced") are gone, so the screen
    /// says what is really being fetched.
    public var stackNameLine: String { ModelStack.displayNames.joined(separator: " + ") }

    /// True when only part of the stack is missing: something is already on disk and stays there.
    public var isPartialDownload: Bool {
        let remaining = deps.models.remainingStackBytes
        return remaining > 0 && remaining < ModelStack.approximateBytes
    }

    /// Re-reads which recogniser would actually transcribe the next utterance. Cheap (a few
    /// `fileExists` calls), and the answer changes exactly when a download lands.
    private func refreshReadiness() {
        let fresh = deps.models.stackReadiness
        guard fresh != machine.readiness else { return }
        Log.app.notice("onboarding: recogniser is \(String(describing: fresh))")
        send(.readinessChanged(fresh))
    }

    /// The dictation button. Two presses, because one press cannot contain an utterance.
    public func toggleGuidedDictation() {
        guard !isFinalizing else { return }
        isDictating ? finishGuidedDictation() : startGuidedDictation()
    }

    /// Opens the capture window and leaves it open.
    ///
    /// The 1.6.6 bug lived in two consecutive statements: `try await engine.start(prewarm: true)`
    /// immediately followed by `try await engine.stop()`. Nothing waited for the user to speak, and
    /// nothing waited for the microphone either — a measured 2.3 s of HAL setup happens *inside*
    /// `start`, and the first audio block lands after it returns. So the final pass ran over ~0
    /// samples, tripped FluidAudio's 300 ms floor, and threw `ASRError.invalidAudioData`.
    public func startGuidedDictation() {
        guard !isDictating, !isFinalizing, machine.step == .firstDictation else { return }
        guard dictationGate.canRun else {
            Log.app.notice("onboarding: dictation test refused — \(self.dictationGate.banner)")
            return
        }
        send(.retryDictation)
        isDictating = true
        dictationPreview = ""
        let engine = deps.engine
        let events = engine.events()
        dictationEvents = Task { [weak self] in
            for await event in events {
                if case .partial(let spans) = event {
                    await MainActor.run { self?.dictationPreview = spans.map(\.text).joined(separator: " ") }
                }
            }
        }
        let prepare = deps.prepareEngine
        dictationTask = Task { [weak self] in
            guard let self else { return }
            do {
                // Re-resolve first: the model this test is about may have landed a second ago.
                await prepare?()
                try await engine.start(prewarm: true)
                startDictationWatchdog()
            } catch {
                finishDictation(.failed(reason: EngineMessage.describe(error)))
            }
        }
    }

    /// Closes the capture window, transcribes, and reports what actually happened.
    public func finishGuidedDictation() {
        guard isDictating, !isFinalizing else { return }
        isFinalizing = true
        dictationWatchdog?.invalidate(); dictationWatchdog = nil
        let starting = dictationTask
        dictationTask = Task { [weak self] in
            // A stop that races a still-prewarming start would otherwise throw `notListening` and be
            // reported as a failure the user did not cause.
            _ = await starting?.value
            guard let self, self.isDictating else { return }
            await self.finalizeGuidedDictation()
        }
    }

    private func finalizeGuidedDictation() async {
        let engine = deps.engine
        var captured: Double?
        // Ask the engine how much audio it is holding *before* finalising. Below its own floor the
        // recogniser can only throw, and "invalidAudioData" is not something to show a person.
        if let reporting = engine as? CapturedAudioReporting {
            let seconds = await reporting.capturedSeconds
            captured = seconds
            if seconds < reporting.minimumUtteranceSeconds {
                await engine.cancel()
                finishDictation(.noSpeech(seconds: seconds))
                return
            }
        }
        let recognizer = machine.readiness.recognizerName ?? "the on-device recogniser"
        do {
            let spans = try await engine.stop()
            let text = spans.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                finishDictation(.noSpeech(seconds: captured ?? 0))
                return
            }
            dictationPreview = text
            // "It landed" is allowed only when a real injection reported success. With no landing
            // path wired, the screen says the text was heard — which is the truth for a button that
            // lives inside the onboarding window, since pressing it makes VoicePlus frontmost and
            // there is no longer a field in another app to type into.
            guard let land = deps.landUtterance else {
                finishDictation(.heard(text: text, recognizer: recognizer))
                return
            }
            let landing = await land(spans)
            let landedText = landing.text.isEmpty ? text : landing.text
            finishDictation(landing.injected ? .landed(text: landedText, app: landing.appName)
                                             : .heard(text: landedText, recognizer: recognizer))
        } catch {
            finishDictation(.failed(reason: EngineMessage.describe(error)))
        }
    }

    private func finishDictation(_ outcome: GuidedDictationOutcome) {
        isDictating = false
        isFinalizing = false
        dictationWatchdog?.invalidate(); dictationWatchdog = nil
        dictationEvents?.cancel(); dictationEvents = nil
        Log.app.notice("onboarding dictation: \(outcome.logLabel)")
        send(.dictationFinished(outcome))
    }

    private func startDictationWatchdog() {
        dictationWatchdog?.invalidate()
        dictationWatchdog = Timer.scheduledTimer(withTimeInterval: Self.maxDictationSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isDictating else { return }
                Log.app.notice("onboarding: dictation stopped itself after \(Self.maxDictationSeconds)s")
                self.finishGuidedDictation()
            }
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
