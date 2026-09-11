import Foundation

/// Pure, synchronous onboarding state machine (Build doc P1.9 T1). The view-model feeds it
/// events; it never touches permissions, audio or models itself, so every branch is unit-testable.
///
/// R6.2 (`DESIGN.md` §11) fixed the flow at exactly five steps — **Welcome → Microphone →
/// Accessibility → Try the key → Done** — and nothing else. Two things that used to be their own
/// screens are folded in:
///
/// * The microphone **permission ask** and the **level meter** used to be two steps
///   (`permissions`, then `micCheck`); DESIGN §11.2 draws them as one screen, so `.microphone` now
///   owns both — the permission UI shows while the grant is outstanding, the meter shows once it
///   isn't, and a denial greys the meter rather than leaving the step.
/// * The model install used to be its own gated step (`modelInstall`, née `modelChoice`) with
///   Continue held shut until the stack landed. DESIGN §11.1's rule — "never a blocking progress
///   screen" — means installing is not a step at all any more: it starts the moment onboarding
///   opens and runs in the background for the rest of the walk, and every other step is free to
///   mention how far along it is without waiting for it.
public struct OnboardingStateMachine: Equatable, Sendable {
    public enum Step: Equatable, Sendable, CaseIterable {
        case welcome, microphone, accessibility, firstDictation, done
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
        /// Install the one stack — whatever part of it is missing. Sent once when onboarding opens
        /// (whatever step it opens on), and again by Retry. Idempotent: with the stack already on
        /// disk it fetches nothing. Never gates a step any more — see the type doc.
        case installModels
        case cancelDownload
        case downloadProgress(ModelDownloadProgress)
        case downloadFinished
        case downloadFailed(String)
        /// Whether the whole stack is on disk right now, re-read from the model manager. Never
        /// inferred from "a download was started".
        case modelPresenceChanged(Bool)
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
        case startDownload
        case cancelDownload
        /// Ask the model manager whether the stack is fully present on disk, and feed the answer
        /// back as `.modelPresenceChanged`.
        case checkModelPresence
        case beginGuidedDictation
        /// Ask the model manager which recogniser would run, and feed it back as `.readinessChanged`.
        case checkRecognizerReadiness
        case finish(skipped: Bool)
    }

    public private(set) var step: Step = .welcome
    /// Cursor into `permissionOrder`. Index 0 is always `.microphone` (see `permissionOrder`), so
    /// `.microphone` step only ever concerns index 0 and `.accessibility` owns everything after it
    /// — one screen for "whatever is left once the microphone is settled", which is one permission
    /// on a default install and two on the `hotkeyForceEventTap` escape hatch.
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
    /// Where the one install has got to. One state, because there is one stack — the three
    /// per-option states existed only to describe three choices.
    public private(set) var downloadState: DownloadState = .notStarted
    /// Whether every model in the stack is present on disk. Fed from the model manager, never
    /// inferred from "we started a download for it".
    public private(set) var stackInstalled = false
    /// True from the moment an install is asked for until it finishes, fails or is cancelled.
    ///
    /// Not derivable from `downloadState`: a fetch that has been started but has not yet reported a
    /// byte is still `.notStarted`, and without this the same install could be asked for twice —
    /// once for onboarding opening, once by a Retry press — and be fetched twice. It is also what
    /// tells "starting…" apart from "the user cancelled it", which wear the same state.
    public private(set) var installRequested = false
    public private(set) var skippedSteps: Set<Step> = []

    /// The install's state — what every step's footer line and the dictation gate ask about.
    public var download: DownloadState { stackInstalled ? .installed : downloadState }

    /// One honest sentence about the install, or nil once it is done. Never a reason to disable
    /// Continue anywhere — DESIGN §11 is explicit that this is never a blocking screen, only a line
    /// that has to tell the truth wherever it appears (Welcome, Microphone, Accessibility, Done).
    public var modelInstallStatusLine: String? {
        guard !stackInstalled else { return nil }
        switch downloadState {
        case .downloading(let p): return "Speech model still installing — \(p.percent)%."
        case .failed(let why): return "Speech model didn't finish installing (\(why)) — retry it from Settings › Models."
        case .notStarted:
            return installRequested ? "Speech model still installing." : "Setting up the speech model — you can keep going."
        case .installed:
            return nil   // unreachable while `!stackInstalled`, but `DownloadState` doesn't know that
        }
    }
    /// What the last guided-dictation attempt achieved. Nil = not attempted.
    public private(set) var dictation: GuidedDictationOutcome?
    /// What would transcribe right now. `.unavailable` until the step asks.
    public private(set) var readiness: RecognizerReadiness = .unavailable(reason: "Checking which speech model is ready…")

    /// Text VoicePlus actually typed into the app the user was in — the only thing that may be
    /// reported as "It landed". Deliberately not "the dictation returned something".
    public var landedText: String? { dictation?.landedText }
    /// Text VoicePlus heard, whether or not it was typed anywhere.
    public var heardText: String? { dictation?.text }
    /// The failure to show, in the words the user should read. Nil when the attempt worked.
    public var dictationError: String? { dictation?.failureMessage }

    /// Which permissions this run walks, in order. Element 0 is always `.microphone` — every caller
    /// of `order(hotkeyRequires:)` guarantees that — which is what lets `.microphone` and
    /// `.accessibility` split the list at index 0 without either step needing to know what is in it.
    ///
    /// Not `OnboardingPermission.allCases` any more. Input Monitoring is in this walk only when the
    /// active hotkey backend actually needs it (`hotkeyForceEventTap`); the default backend consults
    /// no TCC service, so the step most installs never see is simply absent from the list.
    public let permissionOrder: [OnboardingPermission]

    public init(initialStatuses: [OnboardingPermission: OnboardingPermissionStatus] = [:],
                alreadyRequested: Set<OnboardingPermission> = [],
                permissionOrder: [OnboardingPermission] = OnboardingPermission.baselineOrder) {
        statuses = initialStatuses
        requestedPermissions = alreadyRequested
        self.permissionOrder = permissionOrder
        permissionIndex = Self.firstUndecidedIndex(in: initialStatuses, order: permissionOrder)
    }

    /// The permission in focus, or nil once this step's own share of the walk is resolved (granted
    /// or continued-past). `.microphone` only ever answers for index 0; `.accessibility` only ever
    /// answers for everything after it — so a permission cannot be "in focus" on the wrong screen.
    public var currentPermission: OnboardingPermission? {
        guard permissionIndex < permissionOrder.count else { return nil }
        let p = permissionOrder[permissionIndex]
        switch step {
        case .microphone: return permissionIndex == 0 ? p : nil
        case .accessibility: return permissionIndex > 0 ? p : nil
        default: return nil
        }
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
        // Model install can be asked for on any step — onboarding opening, or a Retry press — and
        // the background events it produces (progress, finished, failed, presence) can land on any
        // step too. None of this ever depends on where the user is standing.
        case (_, .installModels):
            return [.checkModelPresence] + startInstall() + [.checkRecognizerReadiness]
        case (_, .cancelDownload):
            guard installRequested else { return [] }
            installRequested = false
            downloadState = .notStarted
            return [.cancelDownload]
        case (_, .readinessChanged(let r)): readiness = r; return []
        case (_, .downloadProgress(let p)):
            guard !stackInstalled else { return [] }
            downloadState = .downloading(p); return []
        case (_, .downloadFinished):
            downloadState = .installed
            stackInstalled = true
            installRequested = false
            return [.checkModelPresence, .checkRecognizerReadiness]
        case (_, .downloadFailed(let r)):
            downloadState = .failed(r)
            installRequested = false
            return [.checkModelPresence, .checkRecognizerReadiness]
        case (_, .modelPresenceChanged(let present)):
            stackInstalled = present
            // A stack that turned out to be present keeps no stale progress or failure beside it,
            // and nothing left to ask for.
            if present { downloadState = .installed; installRequested = false }
            return []

        // Welcome
        case (.welcome, .next):
            return enter(.microphone)

        // Microphone — permission ask and real meter, merged (DESIGN §11.2)
        case (.microphone, .allow(let p)) where p == .microphone && p == currentPermission:
            permissionPhase = .requesting
            requestedPermissions.insert(p)
            return [.requestPermission(p), .rememberRequested(p)]
        case (.microphone, .permissionResult(.microphone, let status)):
            statuses[.microphone] = status
            requestedPermissions.insert(.microphone)
            guard currentPermission == .microphone else { return [] }
            guard status == .granted else { return escalate(status) }
            return resolveMicrophonePermission()   // stay on this step; the meter is what's left to show
        case (.microphone, .statusRefreshed(.microphone, let status)):
            statuses[.microphone] = status
            guard currentPermission == .microphone else { return [] }
            guard status != .granted else { return resolveMicrophonePermission() }
            // TCC dropped back to undecided while sitting in the recovery phase — the `tccutil
            // reset` signature. Heal both the phase and the persisted "asked once" flag that put us
            // here, since both are now stale.
            if OnboardingPermission.microphone.isPromptable, status == .notDetermined, permissionPhase.isNeedsSystemSettings {
                permissionPhase = .explain
                requestedPermissions.remove(.microphone)
                return [.forgetRequested(.microphone)]
            }
            return []
        case (.microphone, .verify(.microphone)) where currentPermission == .microphone:
            // "Re-check" on a promptable service macOS has not decided is not a status question: a
            // status read can never change on its own, and for the microphone the API call is the
            // only thing that puts VoicePlus into the System Settings list at all. Ask for real.
            if OnboardingPermission.microphone.isPromptable,
               (statuses[.microphone] ?? .notDetermined) == .notDetermined {
                permissionPhase = .requesting
                requestedPermissions.insert(.microphone)
                return [.requestPermission(.microphone), .rememberRequested(.microphone)]
            }
            return [.checkPermission(.microphone)]
        case (.microphone, .micCaptureBegan(let real)):
            micCaptureIsReal = real
            if !real { micVerdict = .unavailable(Self.simulatedCaptureReason) }
            return []
        case (.microphone, .micLevel(let level)):
            // The gate. A level that did not come from declared, live capture is not evidence about
            // this user's microphone, so it never touches the peak and never reaches `verdict`.
            guard micCaptureIsReal else { return [] }
            micLevelEvents += 1
            peakLevel = max(peakLevel, level)
            micVerdict = Self.verdict(for: level, peak: peakLevel, settled: micSettled)
            return []
        case (.microphone, .micSettled):
            micSettled = true
            if micCaptureIsReal, micLevelEvents > 0 { micVerdict = Self.verdict(for: 0, peak: peakLevel, settled: true) }
            return []
        case (.microphone, .micNoAudio):
            // Only meaningful while nothing has ever arrived; a late timer must not undo a good verdict.
            if micLevelEvents == 0, micVerdict != .permissionRequired, micCaptureIsReal { micVerdict = .noAudio }
            return []
        case (.microphone, .micFailed(let reason)):
            micVerdict = .unavailable(reason)
            return []
        case (.microphone, .verify):
            // "Try again". While the grant is missing that is a permission question, not an audio
            // one — restarting capture would just redraw the same dead bar.
            if micVerdict == .permissionRequired { return [.checkPermission(.microphone)] }
            peakLevel = 0; micLevelEvents = 0; micSettled = false; micVerdict = .waiting
            micCaptureIsReal = false
            return [.stopMicMonitoring, .startMicMonitoring]
        case (.microphone, .next):
            // "Continue anyway" / "Skip this one" while still asking; a plain Continue once the
            // permission side of the screen has nothing left to say. Either way this is the one
            // step no denial can wall shut (DESIGN §11.2 — "Continue is also always enabled").
            if currentPermission == .microphone { return advancePermission() }
            return enter(.accessibility)

        // Accessibility — permission ask only (and, on the escape hatch, Input Monitoring first)
        case (.accessibility, .allow(let p)) where p == currentPermission:
            permissionPhase = .requesting
            requestedPermissions.insert(p)
            return [.requestPermission(p), .rememberRequested(p)]
        case (.accessibility, .permissionResult(let p, let status)):
            statuses[p] = status
            requestedPermissions.insert(p)
            guard p == currentPermission else { return [] }
            guard status != .granted else { return advancePermission() }
            return escalate(status)
        case (.accessibility, .statusRefreshed(let p, let status)):
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
        case (.accessibility, .verify(let p)) where p == currentPermission:
            if p.isPromptable, (statuses[p] ?? .notDetermined) == .notDetermined {
                permissionPhase = .requesting
                requestedPermissions.insert(p)
                return [.requestPermission(p), .rememberRequested(p)]
            }
            return [.checkPermission(p)]
        case (.accessibility, .next):
            // "Continue anyway" / "Skip this one": advance exactly one permission, never the step.
            return advancePermission()

        // First dictation ("Try the key")
        case (.firstDictation, .dictationFinished(let outcome)):
            dictation = outcome; return []
        case (.firstDictation, .retryDictation):
            // Clear the last verdict so the screen cannot show a stale error beside a fresh attempt.
            dictation = nil; return [.checkRecognizerReadiness]
        case (.firstDictation, .next):
            return enter(.done)

        // A result or refresh about a permission that is not the one this screen is focused on
        // (e.g. a background poll of an Accessibility grant made while Microphone is still on
        // screen) is still recorded — the checklist reads every status, not only the focused one —
        // it just never advances anything.
        case (_, .permissionResult(let p, let status)):
            statuses[p] = status
            requestedPermissions.insert(p)
            return []
        case (_, .statusRefreshed(let p, let status)):
            statuses[p] = status
            return []

        default:
            return []
        }
    }

    // MARK: Helpers

    /// A promptable service that is *still* undecided means the dialog never landed (dismissed, or
    /// the call raced a reset). Retrying is the only cure — System Settings cannot help, because
    /// with no TCC row the app is not in that list and the pane has no "+" to add it. Anything else
    /// lands in the one phase that always has a way forward; a re-check that comes back ungranted
    /// increments the counter, which switches the copy to the stale-TCC recovery instructions
    /// instead of repeating the same advice.
    private mutating func escalate(_ status: OnboardingPermissionStatus) -> [SideEffect] {
        guard let p = currentPermission else { return [] }
        if p.isPromptable, status == .notDetermined {
            permissionPhase = .explain
            return []
        }
        if case .needsSystemSettings(let n) = permissionPhase {
            permissionPhase = .needsSystemSettings(recheckAttempts: n + 1)
        } else {
            permissionPhase = .needsSystemSettings(recheckAttempts: 0)
        }
        return []
    }

    /// - Parameter fallThroughIfResolved: when entering `.accessibility` with nothing left to ask
    ///   (every remaining permission already granted), the *forward* path auto-skips straight to
    ///   "Try the key" rather than drawing an empty screen. Backward navigation must NOT do that —
    ///   Back from "Try the key" has to land ON Accessibility (showing its checklist / all-set
    ///   state), not bounce forward again the instant it gets there. `goBack()` is the one caller
    ///   that passes `false`.
    private mutating func enter(_ next: Step, fallThroughIfResolved: Bool = true) -> [SideEffect] {
        var effects: [SideEffect] = []
        if step == .microphone, next != .microphone { effects.append(.stopMicMonitoring) }
        step = next
        switch next {
        case .microphone:
            if currentPermission == .microphone {
                let p = OnboardingPermission.microphone
                permissionPhase = Self.initialPhase(for: p, requested: requestedPermissions,
                                                    status: statuses[p] ?? .notDetermined)
                micVerdict = .permissionRequired
                return effects
            }
            // Granted (or the meter is what is left to show): reset the meter and start capture.
            peakLevel = 0; micLevelEvents = 0; micSettled = false; micCaptureIsReal = false
            guard statuses[.microphone] == .granted else {
                // Skipped past without a grant: no capture, no possible pass. This used to fall
                // through wordlessly; it is now its own screen with a route to System Settings.
                micVerdict = .permissionRequired
                return effects
            }
            micVerdict = .waiting
            effects.append(.startMicMonitoring)
        case .accessibility:
            guard let p = currentPermission else {
                guard fallThroughIfResolved else { return effects }
                return effects + enter(.firstDictation)
            }
            permissionPhase = Self.initialPhase(for: p, requested: requestedPermissions,
                                                status: statuses[p] ?? .notDetermined)
        case .firstDictation:
            // Readiness first: the screen must know which recogniser it is about to offer before it
            // draws the button, or it is back to presenting a test that cannot work.
            dictation = nil
            effects.append(.checkRecognizerReadiness)
            effects.append(.beginGuidedDictation)
        case .done:
            effects.append(.finish(skipped: !skippedSteps.isEmpty))
        case .welcome: break
        }
        return effects
    }

    /// Ask for the one install, at most once at a time. Onboarding opening and pressing Retry are
    /// the same thing, and neither may schedule a second fetch of the same model.
    private mutating func startInstall() -> [SideEffect] {
        guard !stackInstalled, !installRequested else { return [] }
        installRequested = true
        downloadState = .notStarted
        return [.startDownload]
    }

    /// The microphone grant landed while `.microphone` is on screen. Unlike `advancePermission`,
    /// this must NOT leave the step — DESIGN §11.2 draws the ask and the meter as one screen, so a
    /// grant reveals the meter right here rather than advancing to Accessibility. It still has to
    /// move `permissionIndex` past index 0, though: `.accessibility`'s own walk (and `currentPermission`
    /// generally) depends on the invariant that the cursor never points at an already-granted
    /// permission, the same invariant `advancePermission` maintains for everything after it.
    private mutating func resolveMicrophonePermission() -> [SideEffect] {
        if permissionIndex == 0 { permissionIndex = 1 }
        while permissionIndex < permissionOrder.count, statuses[permissionOrder[permissionIndex]] == .granted {
            permissionIndex += 1
        }
        peakLevel = 0; micLevelEvents = 0; micSettled = false; micCaptureIsReal = false
        micVerdict = .waiting
        return [.startMicMonitoring]
    }

    /// Moves past the permission currently in focus. Within `.accessibility` that can mean the next
    /// permission on the same screen (the escape hatch's Input Monitoring → Accessibility); leaving
    /// `.microphone` always means the next *step*, because `.microphone` only ever owns index 0.
    private mutating func advancePermission() -> [SideEffect] {
        if let p = currentPermission, statuses[p] != .granted { skippedSteps.insert(step) }
        permissionIndex += 1
        while permissionIndex < permissionOrder.count, statuses[permissionOrder[permissionIndex]] == .granted {
            permissionIndex += 1
        }
        switch step {
        case .microphone:
            return enter(.accessibility)
        case .accessibility:
            guard let next = currentPermission else { return enter(.firstDictation) }
            permissionPhase = Self.initialPhase(for: next, requested: requestedPermissions,
                                                status: statuses[next] ?? .notDetermined)
            return []
        default:
            return []
        }
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
        // Skipping on a permission screen skips *this* permission, not the whole step — otherwise
        // a second permission on the same screen (the escape hatch's Accessibility, behind Input
        // Monitoring) would be unreachable whenever the first one stalls.
        case .microphone, .accessibility:
            skippedSteps.insert(step)
            if currentPermission != nil { return advancePermission() }
            return enter(step == .microphone ? .accessibility : .firstDictation)
        case .welcome: skippedSteps.insert(step); return enter(.microphone)
        case .firstDictation, .done: skippedSteps.insert(step); return enter(.done)
        }
    }

    private mutating func goBack() -> [SideEffect] {
        switch step {
        case .welcome, .done: return []
        case .microphone: return enter(.welcome)
        case .accessibility: return enter(.microphone)
        case .firstDictation: return enter(.accessibility, fallThroughIfResolved: false)
        }
    }

    /// The one line emitted per permission transition. Pure on purpose — the state machine stays
    /// side-effect free, the view model does the emitting.
    public static func transitionLog(permission: OnboardingPermission,
                                     status: OnboardingPermissionStatus,
                                     phase: PermissionPhase) -> String {
        "onboarding: \(permission.rawValue) status=\(status.rawValue) phase=\(phase.logLabel)"
    }

    /// Which permission the current step is focused on, and in which phase — nil once the screen has
    /// nothing left to ask (granted, or continued past).
    public var permissionFocus: (permission: OnboardingPermission, phase: PermissionPhase)? {
        guard let p = currentPermission else { return nil }
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
