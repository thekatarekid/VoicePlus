import Engine
import Foundation

/// Pure, synchronous onboarding state machine (Build doc P1.9 T1). The view-model feeds it
/// events; it never touches permissions, audio or models itself, so every branch is unit-testable.
///
/// S8 (design_v1 §8.7, V4.48, I1) — the verified design's six steps plus the owner's Voice step:
/// **Welcome → Microphone → Typing access → Model → Try dictation → Voice → Ready**.
///
/// * The microphone **permission ask** and the **level meter** share `.microphone` (R6.2): the ask
///   shows while the grant is outstanding, the real meter once it isn't.
/// * `.accessibility` is "Typing access": explained just before the real request. Only the selected
///   hotkey backend's permissions are walked (`permissionOrder`); the default bare-modifier monitor
///   costs none, so Input Monitoring appears only on the event-tap escape hatch.
/// * `.model` shows the one install as it really is — byte progress → Verifying → Loading — and
///   says "Ready" only once the model is verified *and* loaded. It never blocks Continue: the install
///   starts the moment onboarding opens and keeps running whatever step is showing. With the stack
///   already on disk there is nothing to ask, so the forward path passes straight through it, the
///   way `.accessibility` does once every permission is granted.
/// * `.firstDictation` is "Try dictation": the fn system-action prompt and the key test come first
///   (I1), then a real hold into the practice field.
/// * `.voice` is the owner's addition: prompted enrollment, skippable; skipping leaves the passive
///   enrollment (H2) to learn the voice from the first holds instead.
/// * `.done` is "Ready": ready only with a working recognizer and capture path; copy-only is labelled.
///
/// Every step before Ready can be left with "Set up later" and is resumed on the next open
/// (`resume(at:)`).
public struct OnboardingStateMachine: Equatable, Sendable {
    public enum Step: String, Equatable, Sendable, CaseIterable {
        case welcome, microphone, accessibility, model, firstDictation, voice, done
    }

    /// Where loading the installed stack into memory has got to. "Ready" is only ever said on
    /// `.loaded` (design §8.6: never Ready on download completion before verification and loading).
    public enum ModelLoadState: Equatable, Sendable {
        case notLoaded
        case loading
        case loaded(name: String)
        case failed(String)
    }

    /// What one load attempt reported.
    public enum ModelLoadOutcome: Equatable, Sendable {
        case loaded(name: String)
        case failed(String)
    }

    /// The Model step's one line of truth, derived from the install and the load.
    public enum ModelPhase: Equatable, Sendable {
        /// Nothing on disk and nothing fetching (never asked, or cancelled): "Install model".
        case notStarted
        /// Asked for; no byte reported yet.
        case starting
        /// Real byte progress.
        case downloading(ModelDownloadProgress)
        /// Every byte is in; checksum and integrity checks are running before the files count.
        case verifying
        /// On disk and verified; being loaded into memory.
        case loading
        /// Verified and loaded — the only phase that may say "Ready".
        case ready(name: String)
        /// The download or its verification failed: retry, or use a recogniser already on this Mac.
        case downloadFailed(String)
        /// On disk, but loading it failed (M07): retry loading.
        case loadFailed(String)

        public var isReady: Bool { if case .ready = self { return true }; return false }
    }

    /// Voice step (V4.48): prompted enrollment through the Voice section's own enrollment view.
    public enum VoiceEnrollmentState: Equatable, Sendable {
        case notEnrolled
        /// The enrollment view is up and recording.
        case enrolling
        /// A profile was saved. `filtering` is false when this Mac's embedder cannot tell voices
        /// apart (the MFCC fallback): the voice is kept but speaker filtering stays off (X03).
        case enrolled(filtering: Bool)
        /// No recorder is wired to this window, so enrollment cannot start (X03).
        case unavailable

        public var isEnrolled: Bool { if case .enrolled = self { return true }; return false }
    }

    /// I1 — the dictation key on the Try step. For fn / 🌐 the macOS system-action prompt comes
    /// first, then the key test; three prompted presses with no fn event offer Right ⌥ instead.
    public enum KeyCheck: Equatable, Sendable {
        /// The bound key has not been read yet.
        case unknown
        /// fn is the key and macOS also acts on it. Shown before the key test.
        case conflict(FnKeyConflict)
        /// Asking for presses. `prompting` is true while a press window is open.
        case testing(attempts: Int, prompting: Bool)
        /// No fn event in `FnKeyProbe.attemptsBeforeFallback` prompted presses.
        case offerFallback(HotkeyBinding.Kind)
        /// The key works: fn confirmed by a real event, the fallback chosen, or a key that is not fn.
        case ready(HotkeyBinding.Kind)
    }

    /// What Ready can honestly say (design §8.7: "Ready requires a working recognizer and capture
    /// path; copy-only setup is labelled").
    public enum ReadyVerdict: Equatable, Sendable {
        case ready
        /// Capture and recognition work; typing access is off, so text waits to be copied (P02).
        case copyOnly
        /// What still stops dictation, as recovery-catalogue entries, most basic first.
        case notReady([RecoveryID])
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

        // MARK: Model step — loading (S8)
        /// The view model started loading the installed stack (it does so whenever `needsModelLoad`).
        case modelLoadStarted
        case modelLoadFinished(ModelLoadOutcome)
        /// "Retry loading" (M07).
        case retryModelLoad

        // MARK: Try step — the dictation key (I1)
        /// The bound key, macOS's own fn action, and how many fn events the hotkey service has seen
        /// so far in this process (one is proof enough).
        case keyStatus(HotkeyBinding.Kind, conflict: FnKeyConflict?, fnEventsSeen: Int)
        /// "Open Keyboard settings" on the fn system-action prompt.
        case fixFnConflict
        /// "Continue anyway" past the fn system-action prompt.
        case dismissFnConflict
        /// "Check the key": opens one prompted-press window.
        case checkKey
        /// An fn `flagsChanged` edge reached the hotkey service.
        case fnKeyEvent
        /// A prompted-press window closed without an fn event (or the user said they pressed).
        case keyPromptElapsed
        /// "Use Right Option instead" after three silent presses.
        case useFallbackKey
        /// "Try fn / 🌐 again": forget the attempts.
        case retryFnKey

        // MARK: Voice step (V4.48)
        case beginVoiceEnrollment
        /// No recorder could be built for enrollment in this window.
        case voiceEnrollmentUnavailable
        case voiceEnrolled(filtering: Bool)
        case cancelVoiceEnrollment
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
        /// System Settings › Keyboard ("Press 🌐 key to").
        case openKeyboardSettings
        /// Open one prompted-press window; the view model answers with `.keyPromptElapsed` unless an
        /// fn event arrives first.
        case startKeyPromptWindow
        /// Bind the dictation key (the Right ⌥ fallback).
        case rebindDictationKey(HotkeyBinding.Kind)
        /// Build the recorder-backed enrollment view and show it on the Voice step.
        case startVoiceEnrollment
        /// Drop a running enrollment (the step was left, or the user stopped it).
        case stopVoiceEnrollment
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
    /// Loading the installed stack into memory (S8). Reset whenever the files change.
    public private(set) var modelLoad: ModelLoadState = .notLoaded
    /// The dictation key as last read (`.keyStatus`); nil until the Try step reads it.
    public private(set) var dictationKey: HotkeyBinding.Kind?
    /// macOS's own fn / 🌐 action, when it fights an fn binding.
    public private(set) var fnConflict: FnKeyConflict?
    /// "Continue anyway" was pressed on the fn system-action prompt.
    public private(set) var fnConflictDismissed = false
    /// I1's probe: fn events seen vs prompted presses.
    public private(set) var fnProbe = FnKeyProbe()
    /// A prompted-press window is open.
    public private(set) var keyPrompting = false
    public private(set) var voice: VoiceEnrollmentState = .notEnrolled

    // MARK: S8 — derived state

    /// Where the Model step stands: the only place "Ready" is decided for the model.
    public var modelPhase: ModelPhase {
        if stackInstalled {
            switch modelLoad {
            case .loaded(let name): return .ready(name: name)
            case .failed(let why): return .loadFailed(why)
            case .notLoaded, .loading: return .loading
            }
        }
        switch downloadState {
        case .downloading(let p): return p.fraction >= 1 ? .verifying : .downloading(p)
        case .failed(let why): return .downloadFailed(why)
        case .notStarted: return installRequested ? .starting : .notStarted
        case .installed: return .loading   // unreachable while `!stackInstalled`
        }
    }

    /// True when the view model should load the installed stack now: the files are here, nothing
    /// has loaded them, and the user is on (or past) the step that is about them. Kept off the
    /// earlier steps so it never races the app's own launch warm-up for the same model.
    public var needsModelLoad: Bool {
        guard stackInstalled, modelLoad == .notLoaded else { return false }
        switch step {
        case .model, .firstDictation, .voice, .done: return true
        case .welcome, .microphone, .accessibility: return false
        }
    }

    /// I1 on the Try step, in the order the design asks for it: conflict prompt, then key test.
    public var keyCheck: KeyCheck {
        guard let key = dictationKey else { return .unknown }
        guard key == .fn else { return .ready(key) }
        if let conflict = fnConflict, !fnConflictDismissed { return .conflict(conflict) }
        switch fnProbe.verdict {
        case .confirmed: return .ready(.fn)
        case .offerFallback(let kind): return .offerFallback(kind)
        case .waiting(let attempts): return .testing(attempts: attempts, prompting: keyPrompting)
        }
    }

    /// 1-based position for "Setup · 3 of 7".
    public var stepNumber: Int { (Step.allCases.firstIndex(of: step) ?? 0) + 1 }
    public static var stepCount: Int { Step.allCases.count }

    /// Whether a recogniser is known to work: a real transcription happened here, the installed
    /// stack is loaded, or (while the stack is still missing) a fallback on this Mac stands in.
    public var recognizerWorks: Bool {
        if heardText != nil { return true }
        if stackInstalled {
            if case .loaded = modelLoad { return true }
            return false
        }
        if case .fallback = readiness { return true }
        return false
    }

    /// Ready's verdict. The capture path needs the microphone grant and must not have been seen
    /// failing (no audio, capture error); the recogniser must work; typing access decides full vs
    /// copy-only.
    public var readyVerdict: ReadyVerdict {
        var blockers: [RecoveryID] = []
        if statuses[.microphone] != .granted {
            blockers.append(.P01)
        } else {
            switch micVerdict {
            case .noAudio: blockers.append(.A05)
            case .unavailable: blockers.append(.A03)
            default: break
            }
        }
        if !recognizerWorks {
            if stackInstalled { blockers.append(.M07) }
            else if case .failed = downloadState { blockers.append(.M02) }
            else { blockers.append(.M01) }
        }
        if !blockers.isEmpty { return .notReady(blockers) }
        return statuses[.accessibility] == .granted ? .ready : .copyOnly
    }

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

    /// - Parameter voiceEnrolled: a voice profile is already saved on this Mac; the Voice step then
    ///   has nothing to ask and the forward path passes through it.
    public init(initialStatuses: [OnboardingPermission: OnboardingPermissionStatus] = [:],
                alreadyRequested: Set<OnboardingPermission> = [],
                permissionOrder: [OnboardingPermission] = OnboardingPermission.baselineOrder,
                voiceEnrolled: Bool = false) {
        statuses = initialStatuses
        requestedPermissions = alreadyRequested
        self.permissionOrder = permissionOrder
        permissionIndex = Self.firstUndecidedIndex(in: initialStatuses, order: permissionOrder)
        if voiceEnrolled { voice = .enrolled(filtering: true) }
    }

    /// "Resume setup at unfinished step" (design §8.7). Opens `target` as if the user had walked to
    /// it, with the same entry effects; the permission cursor is placed where that step expects it.
    /// Only from a fresh machine, and never onto Welcome (already there) or Ready (finishing is not
    /// resuming).
    @discardableResult
    public mutating func resume(at target: Step) -> [SideEffect] {
        guard step == .welcome, target != .welcome, target != .done else { return [] }
        switch target {
        case .accessibility:
            // The microphone half is behind the user; the cursor starts on whatever after it is open.
            permissionIndex = max(permissionIndex, 1)
            while permissionIndex < permissionOrder.count, statuses[permissionOrder[permissionIndex]] == .granted {
                permissionIndex += 1
            }
        case .model, .firstDictation, .voice:
            permissionIndex = permissionOrder.count
        case .welcome, .microphone, .done:
            break
        }
        // A voice enrolled since (in Voice) would fall straight through to Ready and finish setup
        // the instant the window opened; resuming lands on the step and lets Continue finish it.
        return enter(target, fallThroughIfResolved: target != .voice)
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
    /// The prototype's bar: `(step + 1) / count` — Welcome already shows the first segment.
    public var progress: Double { Double(stepNumber) / Double(Self.stepCount) }

    // MARK: Transitions

    @discardableResult
    public mutating func handle(_ event: Event) -> [SideEffect] {
        switch (step, event) {
        // Model install can be asked for on any step — onboarding opening, or a Retry press — and
        // the background events it produces (progress, finished, failed, presence, load) can land
        // on any step too, Ready included: Ready's verdict is live. None of this ever depends on
        // where the user is standing.
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
            // New files: whatever an earlier load said about the old ones no longer applies.
            if modelLoad != .loading { modelLoad = .notLoaded }
            return [.checkModelPresence, .checkRecognizerReadiness]
        case (_, .downloadFailed(let r)):
            downloadState = .failed(r)
            installRequested = false
            return [.checkModelPresence, .checkRecognizerReadiness]
        case (_, .modelPresenceChanged(let present)):
            stackInstalled = present
            // A stack that turned out to be present keeps no stale progress or failure beside it,
            // and nothing left to ask for. One that vanished has nothing loaded any more.
            if present { downloadState = .installed; installRequested = false } else { modelLoad = .notLoaded }
            return []
        case (_, .modelLoadStarted):
            guard stackInstalled else { return [] }
            modelLoad = .loading
            return []
        case (_, .modelLoadFinished(let outcome)):
            guard stackInstalled else { modelLoad = .notLoaded; return [] }
            switch outcome {
            case .loaded(let name): modelLoad = .loaded(name: name)
            case .failed(let why): modelLoad = .failed(why)
            }
            return [.checkRecognizerReadiness]
        case (_, .retryModelLoad):
            if case .failed = modelLoad { modelLoad = .notLoaded }
            return []
        // fn events prove the key wherever they arrive; a press on Welcome counts.
        case (_, .fnKeyEvent):
            fnProbe.noteFnEvent()
            keyPrompting = false
            return []
        case (_, .keyStatus(let key, let conflict, let seen)):
            if dictationKey != key { fnProbe = FnKeyProbe(); keyPrompting = false }
            dictationKey = key
            fnConflict = key == .fn ? conflict : nil
            if seen > 0 { fnProbe.noteFnEvent() }
            return []

        // Ready is final: navigation and step actions stop here (the background events above, and
        // permission statuses below, still update its live verdict).
        case (.done, .permissionResult(let p, let status)), (.done, .statusRefreshed(let p, let status)):
            statuses[p] = status
            return []
        case (.done, _):
            return []
        case (_, .skip):
            return skipCurrent()
        case (_, .back):
            return goBack()

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

        // Model ("Bring speech recognition on device") — never blocks Continue (§11.1).
        case (.model, .next):
            return enter(.firstDictation)

        // First dictation ("Try dictation")
        case (.firstDictation, .dictationFinished(let outcome)):
            dictation = outcome; return []
        case (.firstDictation, .retryDictation):
            // Clear the last verdict so the screen cannot show a stale error beside a fresh attempt.
            dictation = nil; return [.checkRecognizerReadiness]
        case (.firstDictation, .next):
            return enter(.voice)
        // I1 — the fn system-action prompt, before the key test.
        case (.firstDictation, .fixFnConflict):
            return fnConflict == nil ? [] : [.openKeyboardSettings]
        case (.firstDictation, .dismissFnConflict):
            fnConflictDismissed = true; return []
        // I1 — the key test: one prompted window at a time, three silent ones offer Right ⌥.
        case (.firstDictation, .checkKey):
            guard case .testing(_, false) = keyCheck else { return [] }
            keyPrompting = true
            return [.startKeyPromptWindow]
        case (.firstDictation, .keyPromptElapsed):
            guard keyPrompting else { return [] }
            keyPrompting = false
            fnProbe.notePromptedPress()
            return []
        case (.firstDictation, .useFallbackKey):
            guard case .offerFallback(let kind) = keyCheck else { return [] }
            dictationKey = kind
            fnConflict = nil
            return [.rebindDictationKey(kind)]
        case (.firstDictation, .retryFnKey):
            fnProbe.reset(); keyPrompting = false; return []

        // Voice (V4.48) — prompted enrollment, skippable.
        case (.voice, .beginVoiceEnrollment):
            guard voice != .enrolling else { return [] }
            voice = .enrolling
            return [.startVoiceEnrollment]
        case (.voice, .voiceEnrollmentUnavailable):
            voice = .unavailable; return []
        case (.voice, .voiceEnrolled(let filtering)):
            voice = .enrolled(filtering: filtering); return []
        case (.voice, .cancelVoiceEnrollment):
            guard voice == .enrolling else { return [] }
            voice = .notEnrolled
            return [.stopVoiceEnrollment]
        case (.voice, .next):
            // Continue without a profile is the same choice as Skip: passive enrollment takes over.
            if !voice.isEnrolled { skippedSteps.insert(.voice) }
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
        if step == .voice, next != .voice, voice == .enrolling {
            voice = .notEnrolled
            effects.append(.stopVoiceEnrollment)
        }
        if step == .firstDictation, next != .firstDictation { keyPrompting = false }
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
                return effects + enter(.model)
            }
            permissionPhase = Self.initialPhase(for: p, requested: requestedPermissions,
                                                status: statuses[p] ?? .notDetermined)
        case .model:
            // Nothing to install and nothing to decide: the forward path passes through, exactly as
            // `.accessibility` does once every permission is granted. The load (never "Ready"
            // before it) is reported on Try dictation and Ready instead.
            if stackInstalled, fallThroughIfResolved { return effects + enter(.firstDictation) }
            effects.append(.checkRecognizerReadiness)
        case .voice:
            if voice.isEnrolled, fallThroughIfResolved { return effects + enter(.done) }
            if voice == .unavailable { voice = .notEnrolled }
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
            guard let next = currentPermission else { return enter(.model) }
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
            return enter(step == .microphone ? .accessibility : .model)
        case .welcome: skippedSteps.insert(step); return enter(.microphone)
        case .model: skippedSteps.insert(step); return enter(.firstDictation)
        case .firstDictation: skippedSteps.insert(step); return enter(.voice)
        case .voice, .done: skippedSteps.insert(step); return enter(.done)
        }
    }

    /// Back never falls through a resolved step: it has to land *on* the step behind, showing its
    /// resolved state, not bounce forward again the instant it gets there.
    private mutating func goBack() -> [SideEffect] {
        switch step {
        case .welcome, .done: return []
        case .microphone: return enter(.welcome)
        case .accessibility: return enter(.microphone)
        case .model: return enter(.accessibility, fallThroughIfResolved: false)
        case .firstDictation: return enter(.model, fallThroughIfResolved: false)
        case .voice: return enter(.firstDictation, fallThroughIfResolved: false)
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
