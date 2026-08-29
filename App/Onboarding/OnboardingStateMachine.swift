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
    }

    /// Seconds of real audio the meter must have seen before a "too quiet" verdict is honest. The
    /// view model owns the clock and sends `.micSettled` when it elapses — a block *count* would be
    /// at the mercy of how the pipeline coalesces buffers.
    public static let settleSeconds: TimeInterval = 1.5

    public enum DownloadState: Equatable, Sendable {
        case notStarted, downloading(Double), installed, failed(String)
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
        /// A real audio block was measured (normalised 0…1).
        case micLevel(Float)
        /// Capture is up but nothing arrived within the grace period.
        case micNoAudio
        /// `settleSeconds` of real audio have now been heard, so a quiet verdict would be honest.
        case micSettled
        /// Capture failed to start, with the underlying reason.
        case micFailed(String)
        case choose(ModelTier)
        case downloadProgress(Double)
        case downloadFinished
        case downloadFailed(String)
        case dictationLanded(String)
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
    /// Permissions that have been requested at least once (persisted across launches): macOS will not
    /// notify again for them, so the "Allow" button would be a lie on a second run.
    public private(set) var requestedPermissions: Set<OnboardingPermission> = []
    public private(set) var chosenTier: ModelTier?
    public private(set) var download: DownloadState = .notStarted
    public private(set) var landedText: String?
    public private(set) var skippedSteps: Set<Step> = []

    public static let permissionOrder = OnboardingPermission.allCases

    public init(initialStatuses: [OnboardingPermission: OnboardingPermissionStatus] = [:],
                alreadyRequested: Set<OnboardingPermission> = []) {
        statuses = initialStatuses
        requestedPermissions = alreadyRequested
        permissionIndex = Self.firstUndecidedIndex(in: initialStatuses)
    }

    public var currentPermission: OnboardingPermission? {
        step == .permissions && permissionIndex < Self.permissionOrder.count ? Self.permissionOrder[permissionIndex] : nil
    }

    public var allPermissionsGranted: Bool { Self.permissionOrder.allSatisfy { statuses[$0] == .granted } }
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
        case (.micCheck, .micLevel(let level)):
            micLevelEvents += 1
            peakLevel = max(peakLevel, level)
            micVerdict = Self.verdict(for: level, peak: peakLevel, settled: micSettled)
            return []
        case (.micCheck, .micSettled):
            micSettled = true
            if micLevelEvents > 0 { micVerdict = Self.verdict(for: 0, peak: peakLevel, settled: true) }
            return []
        case (.micCheck, .micNoAudio):
            // Only meaningful while nothing has ever arrived; a late timer must not undo a good verdict.
            if micLevelEvents == 0 { micVerdict = .noAudio }
            return []
        case (.micCheck, .micFailed(let reason)):
            micVerdict = .unavailable(reason)
            return []
        case (.micCheck, .verify):
            // "Try again" on the mic-check screen.
            peakLevel = 0; micLevelEvents = 0; micSettled = false; micVerdict = .waiting
            return [.stopMicMonitoring, .startMicMonitoring]
        case (.micCheck, .next):
            return enter(.modelChoice)

        // Model choice
        case (.modelChoice, .choose(let tier)):
            chosenTier = tier
            return [.selectModel(tier)] + (download == .notStarted ? [.startDownload(tier)] : [])
        case (.modelChoice, .downloadProgress(let p)):
            download = .downloading(min(max(p, 0), 1)); return []
        case (.modelChoice, .downloadFinished):
            download = .installed; return []
        case (.modelChoice, .downloadFailed(let reason)):
            download = .failed(reason); return []
        case (.modelChoice, .next):
            if chosenTier == nil { chosenTier = .fast }  // bundled tiny model stays active; never blocking
            return enter(.firstDictation)

        // First dictation
        case (.firstDictation, .dictationLanded(let text)):
            landedText = text; return []
        case (.firstDictation, .next):
            return enter(.done)

        // Download events can arrive after leaving the model screen; keep state coherent.
        case (_, .downloadProgress(let p)): download = .downloading(p); return []
        case (_, .downloadFinished): download = .installed; return []
        case (_, .downloadFailed(let r)): download = .failed(r); return []
        default:
            return []
        }
    }

    // MARK: Helpers

    private mutating func enter(_ next: Step) -> [SideEffect] {
        var effects: [SideEffect] = []
        if step == .micCheck { effects.append(.stopMicMonitoring) }
        step = next
        switch next {
        case .permissions:
            permissionIndex = Self.firstUndecidedIndex(in: statuses)
            if permissionIndex >= Self.permissionOrder.count { return effects + enter(.micCheck) }
            let p = Self.permissionOrder[permissionIndex]
            permissionPhase = Self.initialPhase(for: p, requested: requestedPermissions,
                                                status: statuses[p] ?? .notDetermined)
        case .micCheck:
            if statuses[.microphone] != .granted { step = .modelChoice; return effects }  // no mic → nothing to meter
            peakLevel = 0; micLevelEvents = 0; micSettled = false; micVerdict = .waiting
            effects.append(.startMicMonitoring)
        case .firstDictation:
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

    static func firstUndecidedIndex(in statuses: [OnboardingPermission: OnboardingPermissionStatus]) -> Int {
        permissionOrder.firstIndex { statuses[$0] != .granted } ?? permissionOrder.count
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
