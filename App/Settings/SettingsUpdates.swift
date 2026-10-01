import Foundation
import Shared

// S7g — Settings › Updates (design §8.6): installed version, checking, available, downloading,
// install-ready and failure; installing protects active capture and unsaved drafts before the
// restart. The updater is whatever the composition root wired (`MainWindowController.updater`); an
// updater that reports its progress adopts `UpdateStatusReporting`, and one that cannot update at all
// (`NoopUpdater`, this build) is said to be exactly that.

/// What the updater is doing.
public enum UpdatePhase: Equatable, Sendable {
    /// Nothing running. `lastChecked` when known.
    case idle(lastChecked: Date?)
    case checking
    case upToDate
    case available(version: String)
    /// `fraction` only when the updater has a true denominator (design §9).
    case downloading(version: String, fraction: Double?)
    case readyToInstall(version: String)
    /// X07 "The update didn’t finish" — keep using the installed version.
    case failed
}

/// An updater that can report and drive the phases above. Optional: `UpdaterProtocol` is enough to
/// check; this adds the states the page shows.
public protocol UpdateStatusReporting: AnyObject {
    var updatePhase: UpdatePhase { get }
    /// Called on the main thread whenever `updatePhase` changes.
    var onUpdatePhaseChange: ((UpdatePhase) -> Void)? { get set }
    func downloadUpdate()
    func installAndRelaunch()
}

/// Design §8.6 "protect active capture and unsaved drafts before restart".
public enum UpdateRestartGuard {
    public enum Decision: Equatable, Sendable {
        case proceed
        /// A dictation or meeting holds the microphone: installing would cut it off.
        case waitForCapture
        /// Held drafts exist. `kept`: they survive a restart (saved to disk).
        case confirmDrafts(count: Int, kept: Bool)
    }

    public static func decide(captureActive: Bool, heldDrafts: Int, draftsPersisted: Bool) -> Decision {
        if captureActive { return .waitForCapture }
        if heldDrafts > 0 { return .confirmDrafts(count: heldDrafts, kept: draftsPersisted) }
        return .proceed
    }

    public static func message(_ decision: Decision) -> String? {
        switch decision {
        case .proceed: return nil
        case .waitForCapture: return UpdatesCopy.waitForCapture
        case .confirmDrafts(let count, let kept):
            let noun = count == 1 ? "1 held dictation" : "\(count) held dictations"
            return kept ? "\(noun) will still be here after the restart."
                        : "\(noun) are kept for this session only. Copy \(count == 1 ? "it" : "them") before restarting."
        }
    }
}

public enum UpdatesCopy {
    public static func installed(_ version: String) -> String { "VoicePlus \(version)" }
    public static let installedTitle = "Installed version"
    public static let checkNow = "Check for updates"
    public static let checking = "Checking for updates…"
    public static let upToDate = "VoicePlus is up to date."
    public static func available(_ version: String) -> String { "VoicePlus \(version) is available." }
    public static let download = "Download update"
    public static func downloading(_ version: String) -> String { "Downloading VoicePlus \(version)…" }
    public static func ready(_ version: String) -> String { "VoicePlus \(version) is ready to install." }
    public static let installAndRestart = "Install and restart"
    public static let installAnyway = "Restart anyway"
    public static let waitForCapture = "Finish your dictation or meeting first — installing restarts VoicePlus."
    public static let noUpdater = "This build has no updater wired, so it will never update itself."
    public static let automaticTitle = "Check automatically"
    public static let automaticDetail = "Updates are downloaded only when you choose to."
    public static let channelTitle = "Channel"
    public static let channelDetail = "Beta also offers nightly builds."
    public static func lastChecked(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return "Last checked \(f.string(from: date))."
    }
}

@MainActor
public final class UpdatesPageModel: ObservableObject {
    @Published public private(set) var phase: UpdatePhase
    /// The restart guard's answer while it asks the user to confirm; nil otherwise.
    @Published public private(set) var pendingRestart: UpdateRestartGuard.Decision?
    @Published public var automaticChecks: Bool {
        didSet { updater?.automaticallyChecksForUpdates = automaticChecks }
    }
    /// V5 J5 — the release channel, for an updater that has one (`UpdateChannelSelecting`).
    @Published public var channel: UpdateChannel {
        didSet {
            guard let selecting = updater as? UpdateChannelSelecting, selecting.channel != channel else { return }
            selecting.channel = channel
        }
    }

    public let version: String
    private let updater: UpdaterProtocol?
    private let captureActive: () -> Bool
    private let heldDrafts: () -> Int
    private let draftsPersisted: () -> Bool

    public init(updater: UpdaterProtocol?, version: String,
                captureActive: @escaping () -> Bool, heldDrafts: @escaping () -> Int,
                draftsPersisted: @escaping () -> Bool) {
        self.updater = updater
        self.version = version
        self.captureActive = captureActive
        self.heldDrafts = heldDrafts
        self.draftsPersisted = draftsPersisted
        self.automaticChecks = updater?.automaticallyChecksForUpdates ?? false
        self.channel = (updater as? UpdateChannelSelecting)?.channel ?? .release
        self.phase = (updater as? UpdateStatusReporting)?.updatePhase ?? .idle(lastChecked: nil)
        (updater as? UpdateStatusReporting)?.onUpdatePhaseChange = { [weak self] phase in
            MainActor.assumeIsolated { self?.phase = phase }
        }
    }

    /// The window's model: this build's updater, the engine's capture state and the held drafts.
    public static func live(deps: OnboardingDependencies) -> UpdatesPageModel {
        let engine = deps.engine
        let store = deps.settingsStore
        return UpdatesPageModel(updater: MainWindowController.updater, version: MainWindowController.appVersion,
                                captureActive: { engine.state.isActive },
                                heldDrafts: { MainWindowController.environment.heldItems().count },
                                draftsPersisted: { TurnSettings.persistsRecovery(store) })
    }

    /// False for an updater that cannot update this build (`NoopUpdater`): the page says so and
    /// offers no check that would do nothing.
    public var canUpdate: Bool { updater?.canCheckForUpdates ?? false }

    /// Settings › Updates shows the channel row only for an updater that has channels.
    public var hasChannels: Bool { canUpdate && updater is UpdateChannelSelecting }

    public var statusLine: String {
        guard canUpdate else { return UpdatesCopy.noUpdater }
        switch phase {
        case .idle(let date): return date.map(UpdatesCopy.lastChecked) ?? UpdatesCopy.installed(version)
        case .checking: return UpdatesCopy.checking
        case .upToDate: return UpdatesCopy.upToDate
        case .available(let v): return UpdatesCopy.available(v)
        case .downloading(let v, _): return UpdatesCopy.downloading(v)
        case .readyToInstall(let v): return UpdatesCopy.ready(v)
        case .failed: return RecoveryCatalog.entry(.X07).headline
        }
    }

    /// X07 as a scoped banner: the installed version keeps working.
    public var banner: SectionBanner? {
        guard case .failed = phase else { return nil }
        return .recovery(RecoveryCatalog.entry(.X07))
    }

    public func check() {
        guard canUpdate, phase != .checking else { return }
        // An updater that reports nothing (a Sparkle-shaped one shows its own window) gets a dated
        // check here rather than a "Checking…" that would never end.
        if !(updater is UpdateStatusReporting) { phase = .idle(lastChecked: Date()) }
        updater?.checkForUpdates()
    }

    public func download() { (updater as? UpdateStatusReporting)?.downloadUpdate() }

    /// Install: the guard first. A running capture blocks; held drafts ask for confirmation.
    public func install() {
        let decision = UpdateRestartGuard.decide(captureActive: captureActive(), heldDrafts: heldDrafts(),
                                                 draftsPersisted: draftsPersisted())
        guard decision == .proceed else { pendingRestart = decision; return }
        pendingRestart = nil
        (updater as? UpdateStatusReporting)?.installAndRelaunch()
    }

    /// "Restart anyway" after the drafts notice. Never overrides a running capture.
    public func confirmRestart() {
        guard case .confirmDrafts = pendingRestart, !captureActive() else { return }
        pendingRestart = nil
        (updater as? UpdateStatusReporting)?.installAndRelaunch()
    }

    public func dismissRestart() { pendingRestart = nil }

    /// X07's action.
    public func retry() {
        switch phase {
        case .failed: check()
        default: break
        }
    }
}
