import Engine
import Foundation
import Lab
import Pipeline
import Shared

// R7.1 — the one window's own state: which section is showing, and the six section view models.
// Nothing here touches AppKit, so the whole window is constructible in a test.

/// Settings (§9.6) is preferences, not state: it renders immediately and has no loading state at
/// all. What it *does* have is a per-row "Not saved — Try again" and one genuine empty (no providers
/// connected), both of which live here so the pane's `body` decides nothing.
@MainActor
public final class SettingsSectionViewModel: ObservableObject {
    @Published public private(set) var rowErrors: [String: String] = [:]

    private let connectedProviders: () -> [String]

    public init(connectedProviders: @escaping () -> [String] = { [] }) {
        self.connectedProviders = connectedProviders
    }

    /// Settings are local: there is no loading rendering. A control waiting on a system answer shows
    /// itself disabled with a reason instead (`DESIGN.md` §9.6).
    public let state: SectionState = .content

    public var providers: SectionState {
        connectedProviders().isEmpty
            ? .empty(SectionCopy.nothingConnected, detail: SectionCopy.nothingConnectedDetail)
            : .content
    }

    /// Flags never show an empty pane — the list is the content, marked or not (`DESIGN.md` §9.6).
    public let flags: SectionState = .content

    public func reportNotSaved(_ setting: String, detail: String? = nil) {
        rowErrors[setting] = detail ?? "\(SectionCopy.settingNotSaved) — \(SectionCopy.tryAgain)"
    }

    public func clearNotSaved(_ setting: String) { rowErrors[setting] = nil }

    public func rowError(_ setting: String) -> String? { rowErrors[setting] }
}

/// The window. Owns the selection (remembered across launches, `DESIGN.md` §5.1) and every section.
@MainActor
public final class MainWindowViewModel: ObservableObject {
    @Published public var selection: MainWindowSection {
        didSet {
            guard selection != oldValue else { return }
            MainWindowSection.remember(selection, store: deps.settingsStore)
        }
    }

    public let today: TodaySectionViewModel
    public let meetings: MeetingsSectionViewModel
    public let dictionaryApps: DictionaryAppsSectionViewModel
    public let voice: VoiceSectionViewModel
    public let privacy: PrivacySectionViewModel
    public let settingsSection: SettingsSectionViewModel

    // The tabs' own view models, unchanged: R7.2 moves where they are shown, not what they do.
    public let general: GeneralSettingsViewModel
    public let models: ModelsSettingsViewModel
    public let flags: FlagsViewModel
    public let connectors: ConnectorsSettingsViewModel
    public let sync: SyncSettingsViewModel
    public let corrections: CorrectionSettingsViewModel

    public let deps: OnboardingDependencies

    public init(deps: OnboardingDependencies,
                today: TodaySectionViewModel,
                meetings: MeetingsSectionViewModel,
                dictionaryApps: DictionaryAppsSectionViewModel,
                voice: VoiceSectionViewModel,
                privacy: PrivacySectionViewModel,
                general: GeneralSettingsViewModel,
                models: ModelsSettingsViewModel,
                flags: FlagsViewModel,
                connectors: ConnectorsSettingsViewModel,
                sync: SyncSettingsViewModel,
                corrections: CorrectionSettingsViewModel,
                settingsSection: SettingsSectionViewModel? = nil,
                section: MainWindowSection? = nil) {
        self.deps = deps
        self.today = today
        self.meetings = meetings
        self.dictionaryApps = dictionaryApps
        self.voice = voice
        self.privacy = privacy
        self.general = general
        self.models = models
        self.flags = flags
        self.connectors = connectors
        self.sync = sync
        self.corrections = corrections
        self.settingsSection = settingsSection ?? SettingsSectionViewModel()
        self.selection = section ?? MainWindowSection.remembered(deps.settingsStore)
    }

    /// Opening a section loads what that section needs, and nothing else.
    public func open(_ section: MainWindowSection) {
        selection = section
        Task { await load(section) }
    }

    public func load(_ section: MainWindowSection) async {
        switch section {
        case .today:
            today.refreshReadiness()
            today.refreshHeld()
            await today.reloadTimeline()
        case .meetings:
            await meetings.reload()
        case .dictionary:
            dictionaryApps.reload()
        case .voice:
            voice.refresh()
        case .privacy:
            await privacy.reload()
        case .settings:
            connectors.reload()
            flags.reload()
        }
    }

    /// The window's title bar reads as the section, so the one window never looks like six.
    public var title: String { "VoicePlus — \(selection.detailTitle)" }
}

/// Everything the one window needs that is *not* in `OnboardingDependencies`. Set once by the
/// composition root (or by the legacy `show(...)` entry points, which forward what they were given),
/// so no view reaches for a global.
@MainActor
public struct MainWindowEnvironment {
    public var connectedProviders: [String] = []
    public var labRegistry: LabRegistry = .mocks
    public var egressGate: EgressGate = .shared
    public var personalWER: PersonalWERTracker?
    public var heldItems: () -> [HeldItem] = { [] }
    public var heldAction: (HeldItem, HeldAction) -> HeldActionResult = { _, _ in .unavailable }
    public var makeEnrollment: (() -> SpeakerEnrollmentViewModel?)?
    public var timeline: (any AmbientTimelineReading)?
    public var setMeetingCapture: ((Bool) -> Void)?

    public init() {}
}
