import Engine
import Foundation
import Lab
import Pipeline
import Shared

// R7.1 / S7a — the one window's own state: which section is showing, Settings' subpage, each
// section's preserved navigation (search, selection, scroll, open disclosures), the sidebar footer,
// and the six section view models. Nothing here touches AppKit, so the whole window is
// constructible in a test.

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

/// One section's navigation, kept for as long as the window lives so returning to a section finds it
/// as it was left (design §8: "Preserve scroll and selection when returning to a section"). The shell
/// also keeps each visited section's view alive, so scroll offsets survive without being modelled;
/// `scrollAnchor` is for sections that restore a position explicitly (a row id).
@MainActor
public final class SectionNavigation: ObservableObject {
    public let section: MainWindowSection
    /// The toolbar search field's text for this section (only sections with `hasSearchField`).
    @Published public var searchQuery = ""
    /// The selected row, by the section's own id.
    @Published public var selectionID: String?
    /// The row to scroll back to, by the section's own id.
    @Published public var scrollAnchor: String?
    /// Disclosures that are open (Voice › benchmarks, Privacy › Diagnostics).
    @Published public var expanded: Set<SectionDisclosure> = []

    public init(section: MainWindowSection) { self.section = section }

    public func isExpanded(_ disclosure: SectionDisclosure) -> Bool { expanded.contains(disclosure) }

    public func setExpanded(_ disclosure: SectionDisclosure, _ open: Bool) {
        if open { expanded.insert(disclosure) } else { expanded.remove(disclosure) }
    }
}

/// The sidebar footer (prototype `.app-nav footer`): the green `ready` dot plus "Ready · On this Mac"
/// over "Hold <key> to speak". The status word is the truth, read from Today's readiness strip —
/// the footer never says Ready while the microphone is muted or a blocker stands.
public struct WindowFooter: Equatable, Sendable {
    public enum Status: String, Equatable, Sendable {
        case ready, muted, notReady

        public var word: String {
            switch self {
            case .ready: return "Ready"
            case .muted: return "Muted"
            case .notReady: return "Not ready"
            }
        }

        /// A glyph beside the dot, so the status is never colour alone (`DESIGN.md` §12.9).
        public var systemImage: String {
            switch self {
            case .ready: return "circle.fill"
            case .muted: return "mic.slash"
            case .notReady: return "exclamationmark.triangle"
            }
        }
    }

    public var status: Status
    public var hotkey: String

    public var statusLine: String { "\(status.word) · \(SectionCopy.onThisMac)" }
    public var hintLine: String { SectionCopy.holdToSpeak(key: hotkey) }

    public init(status: Status, hotkey: String) {
        self.status = status
        self.hotkey = hotkey
    }

    /// Muted wins (it is the user's own switch); any other blocker is "Not ready".
    public static func from(readiness: [TodaySectionViewModel.ReadinessRow], hotkey: String) -> WindowFooter {
        if readiness.contains(where: { $0.id == "mute" && !$0.isReady }) {
            return WindowFooter(status: .muted, hotkey: hotkey)
        }
        return WindowFooter(status: readiness.allSatisfy(\.isReady) ? .ready : .notReady, hotkey: hotkey)
    }
}

/// The window. Owns the selection (remembered across launches, `DESIGN.md` §5.1), Settings'
/// subpage, each section's navigation, and every section's view model.
@MainActor
public final class MainWindowViewModel: ObservableObject {
    @Published public var selection: MainWindowSection {
        didSet {
            guard selection != oldValue else { return }
            MainWindowSection.remember(selection, store: deps.settingsStore)
            markVisited(selection)
        }
    }

    /// Settings' subnav selection (design §8.6), remembered like the section.
    @Published public var settingsSubpage: SettingsSubpage {
        didSet {
            guard settingsSubpage != oldValue else { return }
            SettingsSubpage.remember(settingsSubpage, store: deps.settingsStore)
        }
    }

    /// Dictionary & Apps' segmented subview (design §8.3).
    @Published public var dictionaryPane: DictionaryAppsPane = .dictionary

    /// Sections opened at least once this window session, in first-visit order. The shell keeps their
    /// views alive (hidden when not selected) so scroll and in-view state survive a round trip.
    @Published public private(set) var visited: [MainWindowSection] = []

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

    private let navigations: [MainWindowSection: SectionNavigation]

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
        self.navigations = Dictionary(uniqueKeysWithValues: MainWindowSection.allCases.map { ($0, SectionNavigation(section: $0)) })
        let initial = section ?? MainWindowSection.remembered(deps.settingsStore)
        self.selection = initial
        self.settingsSubpage = SettingsSubpage.remembered(deps.settingsStore)
        self.visited = [initial]
    }

    // MARK: Routing

    /// Opening a section loads what that section needs, and nothing else.
    public func open(_ section: MainWindowSection) {
        open(WindowRoute(section))
    }

    /// Opens a full address: the section, then its subpage, pane or disclosure. An invalid route (a
    /// subpage outside Settings, a disclosure in the wrong section) opens its section only.
    public func open(_ route: WindowRoute) {
        apply(route)
        let section = route.section
        Task { await load(section) }
    }

    /// The routing half of `open`, without the load — what a test asserts.
    public func apply(_ route: WindowRoute) {
        selection = route.section
        guard route.isValid else { return }
        if let subpage = route.subpage { settingsSubpage = subpage }
        if let pane = route.pane { dictionaryPane = pane }
        if let disclosure = route.disclosure { navigation(disclosure.section).setExpanded(disclosure, true) }
    }

    /// `⌘,` — Settings, at the subpage the user left.
    public func openSettings() { open(.settings) }

    /// The route the window is showing now.
    public var currentRoute: WindowRoute {
        switch selection {
        case .settings: return .settings(settingsSubpage)
        case .dictionary: return WindowRoute(.dictionary, pane: dictionaryPane)
        default: return WindowRoute(selection)
        }
    }

    /// The design screen on display: Settings shows its subpage's screen.
    public var currentScreen: DesignScreen { screen(for: selection) }

    public func screen(for section: MainWindowSection) -> DesignScreen {
        section == .settings ? settingsSubpage.screen : section.screen
    }

    /// A section's preserved navigation. Every section has one from the start.
    public func navigation(_ section: MainWindowSection) -> SectionNavigation {
        navigations[section]!
    }

    private func markVisited(_ section: MainWindowSection) {
        if !visited.contains(section) { visited.append(section) }
    }

    // MARK: Loading

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

    // MARK: Chrome

    /// The dictation key as every hint names it ("fn / 🌐"), resolved the way `HotkeyService` does:
    /// the stored binding, else the default. Every "Right Control" in design copy renders as this.
    public var hotkeyLabel: String {
        let stored = deps.settingsStore.string(HotkeyService.bindingDefaultsKey).flatMap(HotkeyBinding.Kind.init(rawValue:))
        return (stored ?? HotkeyService.defaultBinding.kind).label
    }

    /// The sidebar footer, from Today's readiness strip.
    public var footer: WindowFooter { WindowFooter.from(readiness: today.readiness, hotkey: hotkeyLabel) }

    /// The window's title bar says the app's name only: the page carries the one page title
    /// (design §8 "Use one clear page title").
    public var title: String { "VoicePlus" }
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
