import Foundation

/// Pure, synchronous onboarding state machine (Build doc P1.9 T1). The view-model feeds it
/// events; it never touches permissions, audio or models itself, so every branch is unit-testable.
public struct OnboardingStateMachine: Equatable, Sendable {
    public enum Step: Equatable, Sendable, CaseIterable {
        case welcome, permissions, micCheck, modelChoice, firstDictation, done
    }

    /// Sub-state of the permissions step for the permission currently in focus.
    public enum PermissionPhase: Equatable, Sendable {
        /// Showing the "why" + Allow button.
        case explain
        /// System prompt in flight.
        case requesting
        /// Denied: show "Open System Settings" + "Verify" buttons.
        case denied
    }

    public enum MicVerdict: Equatable, Sendable { case waiting, tooQuiet, good, clipping }

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
        case micLevel(Float)
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
    public private(set) var chosenTier: ModelTier?
    public private(set) var download: DownloadState = .notStarted
    public private(set) var landedText: String?
    public private(set) var skippedSteps: Set<Step> = []

    public static let permissionOrder = OnboardingPermission.allCases

    public init(initialStatuses: [OnboardingPermission: OnboardingPermissionStatus] = [:]) {
        statuses = initialStatuses
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
            return [.requestPermission(p)]
        case (.permissions, .permissionResult(let p, let status)):
            statuses[p] = status
            guard p == currentPermission else { return [] }
            switch status {
            case .granted: return advancePermission()
            case .denied: permissionPhase = .denied; return []
            case .notDetermined: permissionPhase = .explain; return []
            }
        case (.permissions, .verify(let p)) where p == currentPermission:
            return [.checkPermission(p)]
        case (.permissions, .next):
            // "Skip this one" for a denied/undecided permission.
            return advancePermission()

        // Mic check
        case (.micCheck, .micLevel(let level)):
            peakLevel = max(peakLevel, level)
            micVerdict = Self.verdict(for: level, peak: peakLevel)
            return []
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
            permissionPhase = .explain
            if permissionIndex >= Self.permissionOrder.count { return effects + enter(.micCheck) }
        case .micCheck:
            if statuses[.microphone] != .granted { step = .modelChoice; return effects }  // no mic → nothing to meter
            peakLevel = 0; micVerdict = .waiting
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
        permissionIndex += 1
        permissionPhase = .explain
        while let p = currentPermission, statuses[p] == .granted { permissionIndex += 1 }
        if currentPermission == nil { return enter(.micCheck) }
        return []
    }

    private mutating func skipCurrent() -> [SideEffect] {
        skippedSteps.insert(step)
        switch step {
        case .welcome, .permissions: return enter(.micCheck)
        case .micCheck: return enter(.modelChoice)
        case .modelChoice: return enter(.firstDictation)
        case .firstDictation, .done: return enter(.done)
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

    static func verdict(for level: Float, peak: Float) -> MicVerdict {
        if level >= 0.98 { return .clipping }
        if peak < 0.08 { return .tooQuiet }
        return .good
    }
}
