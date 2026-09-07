import Foundation

/// Pure, synchronous onboarding state machine (Build doc P1.9 T1). The view-model feeds it
/// events; it never touches permissions, audio or models itself, so every branch is unit-testable.
public struct OnboardingStateMachine: Equatable, Sendable {
    public enum Step: Equatable, Sendable, CaseIterable {
        case welcome, permissions, micCheck, modelChoice, firstDictation, done
    }

    /// Sub-state of the permissions step for the permission currently in focus.
    public enum PermissionPhase: Equatable, Sendable {
        /// Showing the "why" + Allow button. Only ever the *pre-request* state.
        case explain
        /// Request issued; waiting for the (fast, usually unhelpful) answer.
        case requesting
        /// The request did not grant it. macOS will not ask again for this code identity, so this
        /// phase always offers: Open System Settings, Re-check, Continue anyway. `recheckAttempts`
        /// counts re-checks that came back still-not-granted; >0 shows the stale-TCC recovery copy.
        case needsSystemSettings(recheckAttempts: Int)

        public var isNeedsSystemSettings: Bool {
            if case .needsSystemSettings = self { return true }
            return false
        }

        /// Short, stable name for the log. The 1.6.2 microphone regression was a *phase* choice
        /// nothing ever recorded, so it could not be seen in the user's own logs.
        public var logLabel: String {
            switch self {
            case .explain: return "explain"
            case .requesting: return "requesting"
            case .needsSystemSettings(let n): return "needsSystemSettings(recheck=\(n))"
            }
        }
    }

    public enum MicVerdict: Equatable, Sendable {
        /// Capture is up; not enough audio yet to judge.
        case waiting
        /// Capture reported success but no sample ever arrived — the stale-grant / wrong-device shape.
        case noAudio
        /// Real audio arrived for long enough and it is genuinely quiet.
        case tooQuiet
        case good
        case clipping
        /// Capture could not start; carries the real error.
        case unavailable(String)
        /// macOS has not granted the microphone, so there is nothing to meter and no possible pass.
        /// Before 1.6.9 this landed on the ordinary mic check with a dead bar (or, worse, skipped
        /// the step silently); it is now its own screen with a route to System Settings.
        case permissionRequired

        /// The one verdict that lets the user believe the microphone works. Nothing but real,
        /// captured audio can produce it.
        public var isPass: Bool { self == .good }
    }

    /// What the screen says when something tried to feed the meter without a live capture stack.
    /// Reachable only from a programming error now that `AppContainer` always builds real capture.
    public static let simulatedCaptureReason =
        "No microphone capture is running, so this check cannot be completed."

    /// Seconds of real audio the meter must have seen before a "too quiet" verdict is honest. The
    /// view model owns the clock and sends `.micSettled` when it elapses — a block *count* would be
    /// at the mercy of how the pipeline coalesces buffers.
    public static let settleSeconds: TimeInterval = 1.5

    public enum DownloadState: Equatable, Sendable {
        case notStarted
        case downloading(ModelDownloadProgress)
        case installed
        case failed(String)

        public var isInFlight: Bool { if case .downloading = self { return true }; return false }

        public var fraction: Double? {
            switch self {
            case .downloading(let p): return p.fraction
            case .installed: return 1
            case .notStarted, .failed: return nil
            }
        }

        /// " — 46%" while a download is running, empty otherwise. Used by `GuidedDictationGate` so
        /// the dictation-test banner can say how far along the thing it is waiting for is.
        public var progressSuffix: String {
            if case .downloading(let p) = self { return " — \(p.percent)%" }
            return ""
        }
    }

    public enum Event: Equatable, Sendable {
        case next
        case back
        case skip
        case allow(OnboardingPermission)
        case permissionResult(OnboardingPermission, OnboardingPermissionStatus)
        case verify(OnboardingPermission)
        /// Background poll (0.5 s timer / app re-activation). Advances on a grant, but never moves the
        /// phase backwards or counts as a failed re-check — the user did not press anything.
        case statusRefreshed(OnboardingPermission, OnboardingPermissionStatus)
        /// The view model has confirmed which kind of source is about to feed the meter. Sent before
        /// any level. `real: false` is a refusal, not a mode: it produces `.unavailable` and no
        /// level is ever accepted afterwards.
        case micCaptureBegan(real: Bool)
        /// A real audio block was measured (normalised 0…1).
        case micLevel(Float)
        /// Capture is up but nothing arrived within the grace period.
        case micNoAudio
        /// `settleSeconds` of real audio have now been heard, so a quiet verdict would be honest.
        case micSettled
        /// Capture failed to start, with the underlying reason.
        case micFailed(String)
        case choose(ModelTier)
        case downloadProgress(ModelDownloadProgress)
        case downloadFinished
        case downloadFailed(String)
        /// What the guided dictation actually achieved — success *and* failure travel through the
        /// same event, but as different cases. Until 1.6.6 failure was reported as
        /// `.dictationLanded("")`, which the view read as success because it only checked for nil.
        case dictationFinished(GuidedDictationOutcome)
        /// "Try again" on the dictation step — drops the previous verdict before a fresh attempt.
        case retryDictation
        /// The recogniser that would run right now changed (a download landed, or the step opened).
        case readinessChanged(RecognizerReadiness)
    }

    public enum SideEffect: Equatable, Sendable {
        case requestPermission(OnboardingPermission)
        case checkPermission(OnboardingPermission)
        case openSystemSettings(OnboardingPermission)
        /// Persist "macOS has been asked for this once" so a later launch skips the useless Allow button.
        case rememberRequested(OnboardingPermission)
        /// Clear that flag: TCC went back to `notDetermined` behind our back (`tccutil reset`, a
        /// reinstall), so the recorded attempt no longer describes any state macOS holds.
        case forgetRequested(OnboardingPermission)
        case startMicMonitoring
        case stopMicMonitoring
        case startDownload(ModelTier)
        case selectModel(ModelTier)
        case beginGuidedDictation
        /// Ask the model manager which recogniser would run, and feed it back as `.readinessChanged`.
        case checkRecognizerReadiness
        case finish(skipped: Bool)
    }

    public private(set) var step: Step = .welcome
    public private(set) var permissionIndex = 0
    public private(set) var permissionPhase: PermissionPhase = .explain
    public private(set) var statuses: [OnboardingPermission: OnboardingPermissionStatus] = [:]
    public private(set) var micVerdict: MicVerdict = .waiting
    public private(set) var peakLevel: Float = 0
    /// How many real audio blocks the mic check has seen. Zero means the meter has never been fed.
    public private(set) var micLevelEvents = 0
    /// True once enough real audio has been heard to judge "quiet" honestly.
    public private(set) var micSettled = false
    /// Default-deny provenance for the meter. Only a `.micCaptureBegan(real: true)` — which the view
    /// model sends solely for a `MicLevelPublishing` that reports `isRealCapture` — flips this on,
    /// and `.micLevel` is discarded while it is off. This is what makes a `.good` verdict
    /// unreachable without a live microphone rather than merely unlikely.
    public private(set) var micCaptureIsReal = false
    /// Permissions that have been requested at least once (persisted across launches): macOS will not
    /// notify again for them, so the "Allow" button would be a lie on a second run.
    public private(set) var requestedPermissions: Set<OnboardingPermission> = []
    public private(set) var chosenTier: ModelTier?
    public private(set) var download: DownloadState = .notStarted
    /// The tier the current `download` belongs to, so re-choosing a *different* tier is recognised
    /// as needing its own download instead of inheriting the first one's state.
    public private(set) var downloadingTier: ModelTier?
    /// What the last guided-dictation attempt achieved. Nil = not attempted.
    public private(set) var dictation: GuidedDictationOutcome?
    /// What would transcribe right now. `.unavailable` until the step asks.
    public private(set) var readiness: RecognizerReadiness = .unavailable(reason: "Checking which speech model is ready…")
    public private(set) var skippedSteps: Set<Step> = []

    /// Text VoicePlus actually typed into the app the user was in — the only thing that may be
    /// reported as "It landed". Deliberately not "the dictation returned something".
    public var landedText: String? { dictation?.landedText }
    /// Text VoicePlus heard, whether or not it was typed anywhere.
    public var heardText: String? { dictation?.text }
    /// The failure to show, in the words the user should read. Nil when the attempt worked.
    public var dictationError: String? { dictation?.failureMessage }

    /// Which permissions this run walks, in order.
    ///
    /// Not `OnboardingPermission.allCases` any more. Input Monitoring was in that list because the
    /// only hotkey mechanism was a `.listenOnly` CGEvent tap; the default mechanism now consults no
    /// TCC service, so the step is skipped unless the active backend actually needs it
    /// (`OnboardingPermission.order(hotkeyRequires:)`). Onboarding is where that cost was charged to
    /// every user, and it is where it stops being charged.
    public let permissionOrder: [OnboardingPermission]

    public init(initialStatuses: [OnboardingPermission: OnboardingPermissionStatus] = [:],
                alreadyRequested: Set<OnboardingPermission> = [],
                permissionOrder: [OnboardingPermission] = OnboardingPermission.baselineOrder) {
        statuses = initialStatuses
        requestedPermissions = alreadyRequested
        self.permissionOrder = permissionOrder
        permissionIndex = Self.firstUndecidedIndex(in: initialStatuses, order: permissionOrder)
    }

    public var currentPermission: OnboardingPermission? {
        step == .permissions && permissionIndex < permissionOrder.count ? permissionOrder[permissionIndex] : nil
    }

    public var allPermissionsGranted: Bool { permissionOrder.allSatisfy { statuses[$0] == .granted } }
    public var progress: Double {
        let idx = Step.allCases.firstIndex(of: step) ?? 0
        return Double(idx) / Double(Step.allCases.count - 1)
    }

    // MARK: Transitions

    @discardableResult
    public mutating func handle(_ event: Event) -> [SideEffect] {
        switch (step, event) {
        // Global
        case (.done, _):
            return []
        case (_, .skip):
            return skipCurrent()
        case (_, .back):
            return goBack()

        // Welcome
        case (.welcome, .next):
            return enter(.permissions)

        // Permissions
        case (.permissions, .allow(let p)) where p == currentPermission:
            permissionPhase = .requesting
            requestedPermissions.insert(p)
            return [.requestPermission(p), .rememberRequested(p)]
        case (.permissions, .permissionResult(let p, let status)):
            statuses[p] = status
            requestedPermissions.insert(p)
            guard p == currentPermission else { return [] }
            guard status != .granted else { return advancePermission() }
            // A promptable service that is *still* undecided means the dialog never landed (dismissed,
            // or the call raced a reset). Retrying is the only cure — System Settings cannot help,
            // because with no TCC row the app is not in that list and the pane has no "+" to add it.
            if p.isPromptable, status == .notDetermined {
                permissionPhase = .explain
                return []
            }
            // Anything else lands in the one phase that always has a way forward. A re-check that
            // comes back ungranted increments the counter, which switches the copy to the stale-TCC
            // recovery instructions instead of repeating the same advice.
            if case .needsSystemSettings(let n) = permissionPhase {
                permissionPhase = .needsSystemSettings(recheckAttempts: n + 1)
            } else {
                permissionPhase = .needsSystemSettings(recheckAttempts: 0)
            }
            return []
        case (.permissions, .statusRefreshed(let p, let status)):
            statuses[p] = status
            guard p == currentPermission else { return [] }
            guard status != .granted else { return advancePermission() }
            // TCC dropped back to undecided while we were sitting in the recovery phase — the
            // `tccutil reset` signature. For a promptable service the prompt is available again, so
            // both the phase and the persisted "asked once" flag that put us here are stale. Heal.
            if p.isPromptable, status == .notDetermined, permissionPhase.isNeedsSystemSettings {
                permissionPhase = .explain
                requestedPermissions.remove(p)
                return [.forgetRequested(p)]
            }
            return []
        case (.permissions, .verify(let p)) where p == currentPermission:
            // "Re-check" on a promptable service macOS has not decided is not a status question: a
            // status read can never change on its own, and for the microphone the API call is the
            // only thing that puts VoicePlus into the System Settings list at all. Ask for real.
            if p.isPromptable, (statuses[p] ?? .notDetermined) == .notDetermined {
                permissionPhase = .requesting
                requestedPermissions.insert(p)
                return [.requestPermission(p), .rememberRequested(p)]
            }
            return [.checkPermission(p)]
        case (.permissions, .next):
            // "Continue anyway" / "Skip this one": advance exactly one permission, never the step.
            return advancePermission()

        // Mic check
        case (.micCheck, .micCaptureBegan(let real)):
            micCaptureIsReal = real
            if !real { micVerdict = .unavailable(Self.simulatedCaptureReason) }
            return []
        case (.micCheck, .micLevel(let level)):
            // The gate. A level that did not come from declared, live capture is not evidence about
            // this user's microphone, so it never touches the peak and never reaches `verdict`.
            guard micCaptureIsReal else { return [] }
            micLevelEvents += 1
            peakLevel = max(peakLevel, level)
            micVerdict = Self.verdict(for: level, peak: peakLevel, settled: micSettled)
            return []
        case (.micCheck, .micSettled):
            micSettled = true
            if micCaptureIsReal, micLevelEvents > 0 { micVerdict = Self.verdict(for: 0, peak: peakLevel, settled: true) }
            return []
        case (.micCheck, .micNoAudio):
            // Only meaningful while nothing has ever arrived; a late timer must not undo a good verdict.
            if micLevelEvents == 0, micVerdict != .permissionRequired, micCaptureIsReal { micVerdict = .noAudio }
            return []
        case (.micCheck, .micFailed(let reason)):
            micVerdict = .unavailable(reason)
            return []
        case (.micCheck, .permissionResult(.microphone, let status)),
             (.micCheck, .statusRefreshed(.microphone, let status)):
            // The blocked screen's "Re-check" answer. A grant re-enters the step for real; anything
            // else leaves it blocked rather than opening a meter that cannot move.
            statuses[.microphone] = status
            guard micVerdict == .permissionRequired, status == .granted else { return [] }
            return enter(.micCheck)
        case (.micCheck, .verify):
            // "Try again". While the grant is missing that is a permission question, not an audio
            // one — restarting capture would just redraw the same dead bar.
            if micVerdict == .permissionRequired { return [.checkPermission(.microphone)] }
            peakLevel = 0; micLevelEvents = 0; micSettled = false; micVerdict = .waiting
            micCaptureIsReal = false
            return [.stopMicMonitoring, .startMicMonitoring]
        case (.micCheck, .next):
            return enter(.modelChoice)

        // Model choice
        case (.modelChoice, .choose(let tier)):
            chosenTier = tier
            // A download is started for any tier that does not already have one in flight or
            // finished. The old rule was `download == .notStarted`, which meant that once *any*
            // download had begun, picking a different tier silently persisted the choice and
            // fetched nothing — the user's model never arrived and nothing said so. The view model
            // still short-circuits to `.downloadFinished` when the tier is already on disk, so this
            // costs nothing in the common case.
            guard needsDownload(tier) else { return [.selectModel(tier)] }
            downloadingTier = tier
            download = .notStarted
            return [.selectModel(tier), .startDownload(tier)]
        case (.modelChoice, .downloadProgress(let p)):
            download = .downloading(p); return []
        case (.modelChoice, .downloadFinished):
            download = .installed; return [.checkRecognizerReadiness]
        case (.modelChoice, .downloadFailed(let reason)):
            download = .failed(reason); return [.checkRecognizerReadiness]
        case (.modelChoice, .next):
            if chosenTier == nil { chosenTier = .fast }
            return enter(.firstDictation)

        // First dictation
        case (.firstDictation, .dictationFinished(let outcome)):
            dictation = outcome; return []
        case (.firstDictation, .retryDictation):
            // Clear the last verdict so the screen cannot show a stale error beside a fresh attempt.
            dictation = nil; return [.checkRecognizerReadiness]
        case (.firstDictation, .next):
            return enter(.done)

        // Readiness and download events can arrive on any step (a background download finishing, the
        // dictation step opening); keep the state coherent wherever the user is.
        case (_, .readinessChanged(let r)): readiness = r; return []
        case (_, .downloadProgress(let p)): download = .downloading(p); return []
        case (_, .downloadFinished): download = .installed; return [.checkRecognizerReadiness]
        case (_, .downloadFailed(let r)): download = .failed(r); return [.checkRecognizerReadiness]
        default:
            return []
        }
    }

    /// Whether choosing `tier` should kick off a fetch: anything except a download already running
    /// or already finished *for that same tier*.
    private func needsDownload(_ tier: ModelTier) -> Bool {
        guard downloadingTier == tier else { return true }
        switch download {
        case .downloading, .installed: return false
        case .notStarted, .failed: return true
        }
    }

    // MARK: Helpers

    private mutating func enter(_ next: Step) -> [SideEffect] {
        var effects: [SideEffect] = []
        if step == .micCheck { effects.append(.stopMicMonitoring) }
        step = next
        switch next {
        case .permissions:
            permissionIndex = Self.firstUndecidedIndex(in: statuses, order: permissionOrder)
            if permissionIndex >= permissionOrder.count { return effects + enter(.micCheck) }
            let p = permissionOrder[permissionIndex]
            permissionPhase = Self.initialPhase(for: p, requested: requestedPermissions,
                                                status: statuses[p] ?? .notDetermined)
        case .micCheck:
            peakLevel = 0; micLevelEvents = 0; micSettled = false; micCaptureIsReal = false
            // No grant → no capture → no possible pass. This used to fall through to `.modelChoice`
            // without a word, which meant a user who denied (or skipped) the microphone was never
            // told the one thing standing between them and a working app.
            guard statuses[.microphone] == .granted else {
                micVerdict = .permissionRequired
                return effects
            }
            micVerdict = .waiting
            effects.append(.startMicMonitoring)
        case .firstDictation:
            // Readiness first: the screen must know which recogniser it is about to offer before it
            // draws the button, or it is back to presenting a test that cannot work.
            dictation = nil
            effects.append(.checkRecognizerReadiness)
            effects.append(.beginGuidedDictation)
        case .done:
            effects.append(.finish(skipped: !skippedSteps.isEmpty))
        default: break
        }
        return effects
    }

    private mutating func advancePermission() -> [SideEffect] {
        if let p = currentPermission, statuses[p] != .granted { skippedSteps.insert(.permissions) }
        permissionIndex += 1
        while let p = currentPermission, statuses[p] == .granted { permissionIndex += 1 }
        guard let next = currentPermission else { return enter(.micCheck) }
        permissionPhase = Self.initialPhase(for: next, requested: requestedPermissions,
                                            status: statuses[next] ?? .notDetermined)
        return []
    }

    /// Which phase a permission opens on.
    ///
    /// For a **promptable** service, `notDetermined` ALWAYS means "offer the real request", whatever
    /// the persisted flag claims. The flag records a past attempt, not a TCC state, and TCC can be
    /// reset behind its back — which is exactly the 1.6.2 regression: `onboarding.requested.microphone`
    /// survived a `tccutil reset Microphone`, so the screen opened on the settings-recovery phase, the
    /// only path to `AVCaptureDevice.requestAccess` (the Allow button, rendered in `.explain`) was
    /// never shown, the app never registered with TCC, and it could therefore never appear in the
    /// Microphone pane — which has no "+" to add it with. A permanent dead end.
    ///
    /// For a **non-promptable** service the old rule stands: macOS will not prompt for it at all, so
    /// an "Allow" button on a second run would itself be the lie.
    static func initialPhase(for p: OnboardingPermission,
                             requested: Set<OnboardingPermission>,
                             status: OnboardingPermissionStatus) -> PermissionPhase {
        if p.isPromptable, status == .notDetermined { return .explain }
        return requested.contains(p) ? .needsSystemSettings(recheckAttempts: 0) : .explain
    }

    private mutating func skipCurrent() -> [SideEffect] {
        switch step {
        // Skipping on the permissions step skips *this* permission, not the whole step — otherwise
        // the third permission (Accessibility) is unreachable whenever the second one stalls.
        case .permissions: return advancePermission()
        case .welcome: skippedSteps.insert(step); return enter(.micCheck)
        case .micCheck: skippedSteps.insert(step); return enter(.modelChoice)
        case .modelChoice: skippedSteps.insert(step); return enter(.firstDictation)
        case .firstDictation, .done: skippedSteps.insert(step); return enter(.done)
        }
    }

    private mutating func goBack() -> [SideEffect] {
        switch step {
        case .welcome, .done: return []
        case .permissions: return enter(.welcome)
        case .micCheck: return enter(.permissions)
        case .modelChoice: return statuses[.microphone] == .granted ? enter(.micCheck) : enter(.permissions)
        case .firstDictation: return enter(.modelChoice)
        }
    }

    /// The one line emitted per permission transition. Pure on purpose — the state machine stays
    /// side-effect free, the view model does the emitting.
    public static func transitionLog(permission: OnboardingPermission,
                                     status: OnboardingPermissionStatus,
                                     phase: PermissionPhase) -> String {
        "onboarding: \(permission.rawValue) status=\(status.rawValue) phase=\(phase.logLabel)"
    }

    /// Which permission the permissions step is focused on, and in which phase — nil off the step.
    /// The view model logs whenever this pair changes, which is exactly "entered or advanced".
    public var permissionFocus: (permission: OnboardingPermission, phase: PermissionPhase)? {
        guard step == .permissions, let p = currentPermission else { return nil }
        return (p, permissionPhase)
    }

    static func firstUndecidedIndex(in statuses: [OnboardingPermission: OnboardingPermissionStatus],
                                    order: [OnboardingPermission]) -> Int {
        order.firstIndex { statuses[$0] != .granted } ?? order.count
    }

    /// Only ever called with a level that came from a real audio block. "Quiet" is withheld until
    /// enough blocks have arrived to mean it — the old code returned `.tooQuiet` from the single
    /// synthetic `level: 0` the engine emitted at start, before any sample existed.
    static func verdict(for level: Float, peak: Float, settled: Bool) -> MicVerdict {
        if level >= 0.98 { return .clipping }
        if peak >= 0.08 { return .good }
        return settled ? .tooQuiet : .waiting
    }
}
