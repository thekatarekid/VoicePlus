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
        /// The cure, in order, as separate imperative steps. This is the *primary* content of the
        /// panel — the 1.6.5 report is a user who read an orange headline, acted on the switch it
        /// mentioned, and never reached the instructions, which were rendered as small grey caption
        /// text underneath. Steps render at body size, numbered.
        public var steps: [String]
        /// Secondary explanation, rendered under the steps. Never the place to put an instruction.
        public var detail: String?
        /// Title of the button that re-invokes the real system request; nil when no such API exists
        /// (non-promptable) or when calling it could not help (a hard Don't Allow, where the row —
        /// and therefore a working switch — does exist).
        public var retryTitle: String?
        /// Whether the `tccutil reset` copy/paste escape hatch is the honest last resort here.
        public var showsResetCommand: Bool
        /// Whether the app may offer to remove its own entry for this service itself (the same
        /// `tccutil reset` as the copy/paste command, run for the user). Only ever true in the
        /// escalated non-promptable case, where the service is already not granted — so there is no
        /// working grant that pressing it could destroy.
        public var showsRowReset: Bool
        /// Title of a *secondary* "quit and come back" button, or nil when relaunching cannot help.
        /// Never the primary action, and never offered for a service macOS re-reads live.
        public var relaunchTitle: String?
        /// One line saying whether VoicePlus has to be restarted for this service — stated outright,
        /// because "do I need to restart it?" is the question the 1.6.5 user actually asked and the
        /// screen had no answer for.
        public var restartNote: String?
        /// Whether the `xattr -dr com.apple.quarantine` escape hatch is what this case needs — true
        /// only for a translocated copy, where nothing done in System Settings can ever stick.
        public var showsDequarantineCommand: Bool

        public init(headline: String, steps: [String] = [], detail: String? = nil, retryTitle: String? = nil,
                    showsResetCommand: Bool = false, showsRowReset: Bool = false, relaunchTitle: String? = nil,
                    restartNote: String? = nil, showsDequarantineCommand: Bool = false) {
            self.headline = headline
            self.steps = steps
            self.detail = detail
            self.retryTitle = retryTitle
            self.showsResetCommand = showsResetCommand
            self.showsRowReset = showsRowReset
            self.relaunchTitle = relaunchTitle
            self.restartNote = restartNote
            self.showsDequarantineCommand = showsDequarantineCommand
        }
    }

    /// What the app can actually *observe* about why a non-promptable switch reads off.
    ///
    /// This type exists because the 1.6.4 copy asserted a fact it had no access to. It said "that
    /// switch belongs to an older build of VoicePlus" whenever `attempts >= 1` and the bundle was not
    /// translocated — establishing neither that an entry exists, nor that its switch is on, nor that
    /// its stored code requirement mismatches. TCC.db is SIP-protected; the app cannot read any of
    /// those. On the reporting machine the claim happened to be true. On a clean Mac, one impatient
    /// press of Re-check made every clause of it false.
    ///
    /// So the copy states the cure (which is identical for "no entry" and "stale entry") and
    /// describes the cause conditionally. This carries the one corroborating signal the app *does*
    /// have.
    public struct RecoveryEvidence: Equatable, Sendable {
        /// Other non-promptable services granted right now, under this same signature. Their
        /// existence proves TCC accepts this build's designated requirement, which narrows the causes
        /// for the failing one to "no entry" or "an entry recorded for an older build" — and rules
        /// out "our signature is broken". It still does not prove which, so the copy stays
        /// conditional either way.
        public var corroboratingGrants: [OnboardingPermission]

        public init(corroboratingGrants: [OnboardingPermission] = []) {
            self.corroboratingGrants = corroboratingGrants
        }

        public var signatureProvenGood: Bool { !corroboratingGrants.isEmpty }
    }

    /// Whether a grant made **while VoicePlus is already running** reaches it without a relaunch.
    ///
    /// Corrected in 1.6.7. The 1.6.5/1.6.6 answer — "yes for all three" — was measured on processes
    /// that already held the grant at launch, and it is wrong for the two services macOS itself warns
    /// about. Accessibility is live; Microphone and Input Monitoring are not. Evidence, per service,
    /// lives on `Permission.grantReachesRunningApp`; both files must move together, so this delegates
    /// rather than repeating the switch.
    var grantReachesRunningApp: Bool { core.grantReachesRunningApp }

    /// The inverse, named for the question the screen is answering: "do I have to quit and reopen it?"
    var relaunchNeededForMidSessionGrant: Bool { !grantReachesRunningApp }

    /// - Parameters:
    ///   - status: what TCC says right now — the source of truth, not a persisted flag.
    ///   - attempts: re-checks that came back still-ungranted, used only to escalate the
    ///     non-promptable copy to the full remove-and-re-add instructions.
    ///   - identity: what the running build's code signature means for TCC. Only claims that follow
    ///     from the signature (translocation, whether the fix has to be repeated after each update)
    ///     are derived from it; the stored entry itself is unreadable.
    ///   - evidence: the corroborating grants, if any. Never used to turn a conditional statement
    ///     into an assertion — only to add the one sentence the app can stand behind.
    public func recoveryCopy(status: OnboardingPermissionStatus, attempts: Int,
                             identity: AppCodeIdentity = PermissionDiagnostics.identity(),
                             evidence: RecoveryEvidence = RecoveryEvidence()) -> RecoveryCopy {
        guard isPromptable else {
            // Input Monitoring / Accessibility: macOS shows no dialog for these, ever, and their
            // panes really do have "+" / "–", so this advice can actually be followed.
            if attempts == 0 {
                // "…this screen notices on its own" is true for Accessibility and a lie for Input
                // Monitoring: `CGPreflightListenEventAccess()` keeps returning the pre-grant answer
                // for the rest of this process's life, so the screen would sit there noticing
                // nothing while the user waited. Promise only what the service actually does.
                let follow = grantReachesRunningApp
                    ? "then come back — this screen notices on its own."
                    : "then come back and press Re-check. macOS holds a new \(title) permission back from an app that was already running, so this may need a Quit & Reopen."
                return RecoveryCopy(
                    headline: "macOS won't ask for this one. Turn VoicePlus on in \(settingsListName), \(follow)",
                    restartNote: liveNote
                )
            }
            if identity.isTranslocated {
                // Gatekeeper is running a throwaway copy from a randomised read-only path. Nothing
                // granted to it can outlive the launch, and "Quit & Reopen" only makes another one.
                return RecoveryCopy(
                    headline: "macOS is running VoicePlus from a temporary copy, so nothing you switch on in \(settingsListName) can reach it.",
                    steps: [
                        "Quit VoicePlus and drag it to your Applications folder.",
                        "Run “\(identity.dequarantineCommand)” in Terminal, once.",
                        "Open VoicePlus from Applications, then turn it on in \(settingsListName).",
                    ],
                    detail: "Until then, any switch you turn on is granted to a copy that disappears when VoicePlus quits.",
                    showsDequarantineCommand: true
                )
            }
            // What the app knows: TCC says not granted. What it cannot know: whether an entry exists
            // and is stale, or whether there is no entry at all. Both are cured by the same three
            // steps, so lead with those and keep the cause conditional.
            let durability = identity.isStable
                ? "This build's signing identity no longer changes between updates, so you only have to do this once."
                : "This build is signed ad-hoc, so its identity changes with every update and you will have to repeat this after each one."
            let corroboration = evidence.signatureProvenGood
                ? " macOS is already honouring \(evidence.corroboratingGrants.map(\.title).sorted().joined(separator: " and ")) for this exact build, so the signature is fine — it's this one entry that macOS isn't matching."
                : ""
            return RecoveryCopy(
                headline: "macOS still isn't letting VoicePlus use \(title) — even if the switch in \(settingsListName) looks on.",
                steps: [
                    "Open \(settingsListName).",
                    "If VoicePlus is already in that list, select it and press “–”. Turning its switch off and on again is not the same thing and will not fix it.",
                    "Press “+”, pick VoicePlus in your Applications folder, and make sure its switch is on.",
                ],
                detail: "macOS records which build an entry was added for, and re-adding the entry is the only thing that rewrites that. " + durability + corroboration,
                showsResetCommand: true,
                showsRowReset: true,
                relaunchTitle: relaunchButtonTitle(identity: identity),
                restartNote: liveNote
            )
        }
        switch status {
        case .denied:
            // A hard "Don't Allow" writes a real row, so the switch in that list exists and works.
            // Asking again cannot reopen the dialog, so we do not offer a button that would lie.
            // It is also the one microphone state a mid-session grant can arrive from — and macOS
            // does not hand that grant to a process that was already running, so once a re-check has
            // come back off, "Quit & Reopen" stops being a superstition and becomes the answer.
            return RecoveryCopy(
                headline: "You chose Don't Allow. VoicePlus is in \(settingsListName) now — switch it back on there.",
                detail: "After a Don't Allow macOS stops showing the dialog and answers from that switch instead.",
                relaunchTitle: attempts > 0 ? relaunchButtonTitle(identity: identity) : nil,
                restartNote: liveNote
            )
        default:
            // notDetermined / awaitingUserAction: nothing is recorded, so there is nothing to switch
            // on and no "+" to add it with. Only the app can create that row, by asking again.
            return RecoveryCopy(
                headline: "macOS hasn't answered for the \(title.lowercased()) yet.",
                detail: "\(settingsListName) has no “+” button, so VoicePlus can only get into that list by asking macOS — opening Settings won't show it there until it has. Press “Ask macOS again”. If no dialog appears at all, copy the reset command below, run it in Terminal, and press it once more.",
                retryTitle: "Ask macOS again",
                showsResetCommand: true,
                restartNote: liveNote
            )
        }
    }

    /// "Quit & Reopen", or nil when a relaunch cannot help: a service macOS re-reads live never
    /// needs one, and a translocated copy can only relaunch into another translocated copy.
    func relaunchButtonTitle(identity: AppCodeIdentity) -> String? {
        guard relaunchNeededForMidSessionGrant, !identity.isTranslocated else { return nil }
        return "Quit & Reopen"
    }

    /// The honest answer to "do I have to quit and reopen it?", per service. Saying nothing was its
    /// own failure mode: the 1.6.5 user quit and relaunched after every grant because the screen
    /// never told them they didn't have to. Saying "you never have to" was the 1.6.6 failure mode:
    /// macOS' own alert says the opposite for two of the three, and the user believed macOS.
    ///
    /// So the note quotes macOS where macOS speaks, and only claims what was measured — that the
    /// *status* this app gates the feature on stays stale until the process restarts. It does not
    /// claim anything about whether capture or event delivery would work underneath, which was never
    /// measured.
    var liveNote: String {
        switch self {
        case .accessibility:
            return "You don't need to quit and reopen VoicePlus. It picks Accessibility up within a second of the switch moving — macOS never asks you to quit for this one."
        case .microphone:
            return "macOS hands a new microphone permission to an app only when that app next starts — that's what its own “VoicePlus will not have access to your microphone until it is quit” alert means. If you chose Later, use Quit & Reopen; until then VoicePlus keeps reading the microphone as off."
        case .inputMonitoring:
            return "macOS hands a new Input Monitoring permission to an app only when that app next starts — that's what its own “VoicePlus will not be able to monitor input from your keyboard until it is quit” alert means. If you chose Later, use Quit & Reopen; until then the hold-to-talk key stays dead, though the menu-bar “Start dictation” item still works."
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

    /// The real models behind the friendly word, and their real size, both read from
    /// `ModelCatalog` — see `ModelTier.modelNames` / `.approximateBytes` in
    /// `LiveOnboardingDependencies.swift`.
    ///
    /// There used to be a hardcoded `sizeMB` here (120 / 450 / 1200) with no link to the catalog,
    /// and every one of the three had drifted: Fast is 110 MB, Balanced 500 MB, and "Best" is two
    /// models totalling 900 MB — not the "~1.2 GB" the 1.6.6 user was shown. A number the code
    /// cannot recompute is a number that goes stale silently.
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
    /// Background download. Must be cancellable via the returned task being cancelled.
    func download(_ tier: ModelTier, progress: @escaping @Sendable (ModelDownloadProgress) -> Void) async throws
    func select(_ tier: ModelTier)
    var selectedTier: ModelTier { get }
    /// What would actually transcribe right now if the user pressed "Dictate now" — the chosen
    /// tier's model, a smaller one already on disk, Apple Speech, or nothing at all. The onboarding
    /// dictation test refuses to run without this, and always names what it is using.
    func readiness(for tier: ModelTier) -> RecognizerReadiness
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
    /// Lands one utterance the way the hotkey does (pipeline → injection → history) and reports
    /// whether the text was *really* typed.
    ///
    /// Nil means onboarding has no landing path — and then the screen says the text was heard, never
    /// that it landed. That distinction is the whole of the 1.6.6 fix: the old button never reached
    /// `UtteranceLander` at all, so "It landed. You're set." could not have been true even with
    /// perfect audio. See `DictationCoordinator.guidedLanding`.
    public var landUtterance: (@Sendable ([TranscriptSpan]) async -> GuidedLanding)?

    public init(permissions: OnboardingPermissionChecking, micLevel: MicLevelPublishing, models: ModelManaging,
                engine: EngineProtocol, database: AppDatabase?, flags: FeatureFlagService,
                contacts: ContactsStoreProtocol, settingsStore: SettingsStore = UserDefaultsSettingsStore(),
                openProvidersSettings: @escaping () -> Void = {},
                landUtterance: (@Sendable ([TranscriptSpan]) async -> GuidedLanding)? = nil) {
        self.landUtterance = landUtterance
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
    /// What `readiness(for:)` reports when the tier is not installed. Nil = nothing can transcribe,
    /// which is how a clean Mac with no Apple Speech behaves.
    public var fallbackName: String? = "Apple Speech (on-device)"
    public private(set) var downloads: [ModelTier] = []
    /// Set by the test to stall a download mid-flight; the task resumes when it is fulfilled.
    public var hold: (@Sendable () async -> Void)?

    public init(installed: Set<ModelTier> = [.fast], selected: ModelTier = .fast) {
        self.installed = installed
        self.selectedTier = selected
    }

    public func isInstalled(_ tier: ModelTier) -> Bool { installed.contains(tier) }

    public func download(_ tier: ModelTier, progress: @escaping @Sendable (ModelDownloadProgress) -> Void) async throws {
        downloads.append(tier)
        if failDownload { throw URLError(.notConnectedToInternet) }
        let total = tier.approximateBytes
        for step in 1...4 {
            let fraction = Double(step) / 4
            progress(ModelDownloadProgress(fraction: fraction,
                                           bytesReceived: Int64(Double(total) * fraction),
                                           bytesExpected: total,
                                           modelName: tier.modelNames.first ?? tier.title))
            if step == 1, let hold { await hold() }
        }
        installed.insert(tier)
    }

    public func select(_ tier: ModelTier) { selectedTier = tier }

    public func readiness(for tier: ModelTier) -> RecognizerReadiness {
        if installed.contains(tier) { return .ready(name: tier.modelNames.first ?? tier.title) }
        guard let fallbackName else {
            return .unavailable(reason: "No speech model is on this Mac yet, and macOS' own speech recogniser isn't available either.")
        }
        return .fallback(name: fallbackName, awaiting: tier.modelNames.first)
    }
}
