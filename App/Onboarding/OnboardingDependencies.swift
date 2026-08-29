import Combine
import Foundation
import Shared

// MARK: - Permissions (independent of App/Core so P1.1 can rewrite it freely)

/// The three permissions onboarding walks through, in order.
public enum OnboardingPermission: String, CaseIterable, Codable, Sendable, Identifiable {
    case microphone, inputMonitoring, accessibility
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .inputMonitoring: return "Input Monitoring"
        case .accessibility: return "Accessibility"
        }
    }

    /// Plain-language "why" shown before the system prompt.
    public var why: String {
        switch self {
        case .microphone:
            return "VoicePlus listens only while you hold the key. Audio is transcribed on this Mac and never leaves it unless you turn on a cloud provider."
        case .inputMonitoring:
            return "This is how VoicePlus notices you holding the dictation key while another app is in front. Keystrokes are never recorded."
        case .accessibility:
            return "Lets VoicePlus type what you said into the app you're using and read the field you're in so it can match the style. No screenshots, ever."
        }
    }

    /// What stops working if this one is skipped.
    public var consequenceIfSkipped: String {
        switch self {
        case .microphone: return "Nothing can be transcribed without the microphone."
        case .inputMonitoring: return "You can still dictate from the menu bar, but the hold-to-talk key won't work in other apps."
        case .accessibility: return "Text will be copied to the clipboard instead of landing in the app."
        }
    }

    /// Same three permissions as `Permission`; onboarding keeps its own enum so P1.1 can rewrite the
    /// core independently, but the System Settings links come from one place.
    var core: Permission {
        switch self {
        case .microphone: return .microphone
        case .inputMonitoring: return .inputMonitoring
        case .accessibility: return .accessibility
        }
    }

    public var settingsURL: URL { core.settingsURL }
    public var settingsURLs: [URL] { core.settingsURLs }

    /// Shown in the recovery panel when a re-check still comes back ungranted.
    public var settingsListName: String {
        switch self {
        case .microphone: return "Privacy & Security › Microphone"
        case .inputMonitoring: return "Privacy & Security › Input Monitoring"
        case .accessibility: return "Privacy & Security › Accessibility"
        }
    }

    /// Whether macOS has a real consent dialog for this service — see `Permission.isPromptable`.
    /// The whole `needsSystemSettings`-first design is correct for the non-promptable pair only.
    public var isPromptable: Bool { core.isPromptable }

    /// Copy for the "not granted yet" panel. Promptable and non-promptable services need *opposite*
    /// advice, and the wrong advice is literally unfollowable: the Microphone pane has no "+", so
    /// "add VoicePlus to that list" cannot be done by hand, and "macOS only asks once" is false —
    /// after `tccutil reset Microphone` macOS asks again, but only if the app calls the API again.
    public struct RecoveryCopy: Equatable, Sendable {
        public var headline: String
        public var detail: String?
        /// Title of the button that re-invokes the real system request; nil when no such API exists
        /// (non-promptable) or when calling it could not help (a hard Don't Allow, where the row —
        /// and therefore a working switch — does exist).
        public var retryTitle: String?
        /// Whether the `tccutil reset` copy/paste escape hatch is the honest last resort here.
        public var showsResetCommand: Bool

        public init(headline: String, detail: String? = nil, retryTitle: String? = nil,
                    showsResetCommand: Bool = false) {
            self.headline = headline
            self.detail = detail
            self.retryTitle = retryTitle
            self.showsResetCommand = showsResetCommand
        }
    }

    /// - Parameters:
    ///   - status: what TCC says right now — the source of truth, not a persisted flag.
    ///   - attempts: re-checks that came back still-ungranted, used only to escalate the
    ///     non-promptable copy to the stale-cdhash instructions.
    public func recoveryCopy(status: OnboardingPermissionStatus, attempts: Int) -> RecoveryCopy {
        guard isPromptable else {
            // Input Monitoring / Accessibility: macOS shows no dialog for these, ever, and their
            // panes really do have "+" / "–", so this advice can actually be followed.
            if attempts == 0 {
                return RecoveryCopy(
                    headline: "macOS won't ask for this one. Turn VoicePlus on in \(settingsListName), then come back — this screen notices on its own."
                )
            }
            return RecoveryCopy(
                headline: "Still off. macOS is probably remembering an older copy of VoicePlus.",
                detail: "In \(settingsListName), select VoicePlus, remove it with the “–” button, then add it again with “+”. This build is signed ad-hoc, so each update looks like a new app to macOS.",
                showsResetCommand: true
            )
        }
        switch status {
        case .denied:
            // A hard "Don't Allow" writes a real row, so the switch in that list exists and works.
            // Asking again cannot reopen the dialog, so we do not offer a button that would lie.
            return RecoveryCopy(
                headline: "You chose Don't Allow. VoicePlus is in \(settingsListName) now — switch it back on there.",
                detail: "After a Don't Allow macOS stops showing the dialog and answers from that switch instead. This screen notices the moment you flip it."
            )
        default:
            // notDetermined / awaitingUserAction: nothing is recorded, so there is nothing to switch
            // on and no "+" to add it with. Only the app can create that row, by asking again.
            return RecoveryCopy(
                headline: "macOS hasn't answered for the \(title.lowercased()) yet.",
                detail: "\(settingsListName) has no “+” button, so VoicePlus can only get into that list by asking macOS — opening Settings won't show it there until it has. Press “Ask macOS again”. If no dialog appears at all, copy the reset command below, run it in Terminal, and press it once more.",
                retryTitle: "Ask macOS again",
                showsResetCommand: true
            )
        }
    }
}

public enum OnboardingPermissionStatus: String, Codable, Equatable, Sendable {
    case notDetermined, granted, denied
    /// Requested, but macOS answers this one only in System Settings. See `PermissionStatus`.
    case awaitingUserAction
}

/// Wired by P1.1 / P1.12 to the real `PermissionService`.
public protocol OnboardingPermissionChecking: AnyObject {
    func status(of permission: OnboardingPermission) -> OnboardingPermissionStatus
    /// Triggers the system prompt (or no-ops when already decided) and returns the resulting status.
    func request(_ permission: OnboardingPermission) async -> OnboardingPermissionStatus
    func openSystemSettings(for permission: OnboardingPermission)
}

// MARK: - Mic level

/// What the mic-check screen learns from the capture stack. The distinction between "capture is up
/// but no sample has arrived" and "samples are arriving and they're quiet" is the whole point: a
/// denied/stale microphone grant produces a *successful* `AVAudioEngine.start()` and zero tap
/// callbacks, which the old EngineState-derived meter reported as "very quiet".
public enum MicCheckSignal: Equatable, Sendable {
    /// Capture requested; nothing has arrived yet.
    case starting
    /// A real audio block was measured. `level` is normalised 0…1.
    case level(Float)
    /// Capture could not start, or failed after starting.
    case failed(String)
}

/// Publishes the mic-check signal for the meter.
public protocol MicLevelPublishing: AnyObject {
    var signalPublisher: AnyPublisher<MicCheckSignal, Never> { get }
    func startMonitoring()
    func stopMonitoring()
    /// False when the meter is synthetic (mock engine): the UI must not claim a real mic works.
    var isRealCapture: Bool { get }
}

public extension MicLevelPublishing {
    var isRealCapture: Bool { true }
}

// MARK: - Models

/// Plain-language local ASR tiers (PRODUCT-SPEC Part 4.6). Mapping to `Engine.ModelID` happens in P1.12.
public enum ModelTier: String, CaseIterable, Codable, Sendable, Identifiable {
    case fast, balanced, best
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .fast: return "Fast"
        case .balanced: return "Balanced"
        case .best: return "Best"
        }
    }

    public var sizeMB: Int {
        switch self {
        case .fast: return 120
        case .balanced: return 450
        case .best: return 1200
        }
    }

    public var tradeoff: String {
        switch self {
        case .fast: return "Instant on any Mac. Fine for chat and notes; misses rarer names."
        case .balanced: return "The sweet spot. Accurate on names and jargon, still feels instant."
        case .best: return "Most accurate. Slightly slower first word on older Macs."
        }
    }

    /// Suggested default for a fresh install.
    public static let recommended: ModelTier = .balanced
}

public protocol ModelManaging: AnyObject {
    func isInstalled(_ tier: ModelTier) -> Bool
    /// Background download; `progress` is 0…1. Must be cancellable via the returned task being cancelled.
    func download(_ tier: ModelTier, progress: @escaping @Sendable (Double) -> Void) async throws
    func select(_ tier: ModelTier)
    var selectedTier: ModelTier { get }
}

// MARK: - Dependencies

/// Everything onboarding + settings need. P1.1 / P1.12 build the real one; `mock()` drives tests and previews.
public struct OnboardingDependencies {
    public var permissions: OnboardingPermissionChecking
    public var micLevel: MicLevelPublishing
    public var models: ModelManaging
    public var engine: EngineProtocol
    public var database: AppDatabase?
    public var flags: FeatureFlagService
    public var contacts: ContactsStoreProtocol
    public var settingsStore: SettingsStore
    /// Called by "connect what you pay for" — P1.12 wires this to the Providers settings tab.
    public var openProvidersSettings: () -> Void

    public init(permissions: OnboardingPermissionChecking, micLevel: MicLevelPublishing, models: ModelManaging,
                engine: EngineProtocol, database: AppDatabase?, flags: FeatureFlagService,
                contacts: ContactsStoreProtocol, settingsStore: SettingsStore = UserDefaultsSettingsStore(),
                openProvidersSettings: @escaping () -> Void = {}) {
        self.permissions = permissions
        self.micLevel = micLevel
        self.models = models
        self.engine = engine
        self.database = database
        self.flags = flags
        self.contacts = contacts
        self.settingsStore = settingsStore
        self.openProvidersSettings = openProvidersSettings
    }

    /// Fully in-memory dependencies: all permissions grant on request, synthetic mic level, instant "downloads".
    public static func mock(permissionResults: [OnboardingPermission: OnboardingPermissionStatus] = [:],
                            contactNames: [String] = []) -> OnboardingDependencies {
        let fixture = TranscriptFixture(name: "onboarding", spans: [
            .init(text: "The quick brown fox jumps over the lazy dog.", confidence: 0.97, audioStart: 0, audioEnd: 2.4),
        ])
        return OnboardingDependencies(
            permissions: OnboardingMockPermissionChecker(results: permissionResults),
            micLevel: OnboardingMockMicLevelPublisher(),
            models: OnboardingMockModelManager(),
            engine: MockEngine(fixture: fixture, delayScale: 0.01),
            database: try? AppDatabase.inMemory(),
            flags: .inMemory(),
            contacts: MockContactsStore(names: contactNames),
            settingsStore: InMemorySettingsStore()
        )
    }
}

// MARK: - Mocks (used by tests and SwiftUI previews; tiny, so they live in the app target)

public final class OnboardingMockPermissionChecker: OnboardingPermissionChecking {
    public var statuses: [OnboardingPermission: OnboardingPermissionStatus] = [:]
    /// What `request` resolves to; defaults to granted.
    public var results: [OnboardingPermission: OnboardingPermissionStatus]
    public private(set) var openedSettings: [OnboardingPermission] = []
    /// Every `request` call, in order. Tests assert the real system API was actually reached — for a
    /// promptable service that call is the only thing that registers the app with TCC.
    public private(set) var requests: [OnboardingPermission] = []

    public init(results: [OnboardingPermission: OnboardingPermissionStatus] = [:]) { self.results = results }

    public func status(of permission: OnboardingPermission) -> OnboardingPermissionStatus {
        statuses[permission] ?? .notDetermined
    }

    public func request(_ permission: OnboardingPermission) async -> OnboardingPermissionStatus {
        requests.append(permission)
        let result = results[permission] ?? .granted
        statuses[permission] = result
        return result
    }

    public func openSystemSettings(for permission: OnboardingPermission) { openedSettings.append(permission) }
}

public final class OnboardingMockMicLevelPublisher: MicLevelPublishing {
    public let subject = CurrentValueSubject<MicCheckSignal, Never>(.starting)
    public private(set) var monitoring = false
    public var isRealCapture = true
    public init() {}
    public var signalPublisher: AnyPublisher<MicCheckSignal, Never> { subject.eraseToAnyPublisher() }
    public func startMonitoring() { monitoring = true }
    public func stopMonitoring() { monitoring = false }
    /// Test convenience: push a level as if a real audio block had arrived.
    public func send(_ level: Float) { subject.send(.level(level)) }
    public func fail(_ reason: String) { subject.send(.failed(reason)) }
}

public final class OnboardingMockModelManager: ModelManaging {
    public var installed: Set<ModelTier>
    public var selectedTier: ModelTier
    public var failDownload = false
    public private(set) var downloads: [ModelTier] = []

    public init(installed: Set<ModelTier> = [.fast], selected: ModelTier = .fast) {
        self.installed = installed
        self.selectedTier = selected
    }

    public func isInstalled(_ tier: ModelTier) -> Bool { installed.contains(tier) }

    public func download(_ tier: ModelTier, progress: @escaping @Sendable (Double) -> Void) async throws {
        downloads.append(tier)
        if failDownload { throw URLError(.notConnectedToInternet) }
        for step in 1...4 { progress(Double(step) / 4) }
        installed.insert(tier)
    }

    public func select(_ tier: ModelTier) { selectedTier = tier }
}
