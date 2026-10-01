import CoreGraphics
import Foundation

// S7a — the one window's routing (design §8, `DESIGN.md` §9): six sections, Settings' seven
// subpages, the disclosures a deep link can open, and the window's geometry.
//
// The reachability catalogue at the bottom of this file is the load-bearing part: it names every
// setting the old tabbed window had, where it now lives (a `WindowRoute`), and the marker
// (accessibility identifier, or the hosted view's type) that must appear in that section's source.
// `SettingsReachabilityTests` reads the source files and fails if any marker went missing — which is
// the only way a toolchain with no UI testing can assert "you can still get at this" (R7 proof).

/// The sidebar, in the order design §8 fixes (plus V5 N1 Notes after Meetings), with `⌘1`–`⌘7` in that same order.
public enum MainWindowSection: String, CaseIterable, Identifiable, Sendable {
    /// V5 N1: `notes` sits after Meetings — words kept for later, beside the meetings they often
    /// come from. It is not a prototype screen (`design_v1.html` predates Notes).
    case today, meetings, notes, dictionary, voice, privacy, settings

    public var id: String { rawValue }

    /// Sidebar label — the prototype's `.app-nav` buttons.
    public var title: String {
        switch self {
        case .today: return "Today"
        case .meetings: return "Meetings"
        case .notes: return NotesCopy.title
        case .dictionary: return "Dictionary & Apps"
        case .voice: return "Voice"
        case .privacy: return "Privacy"
        case .settings: return "Settings"
        }
    }

    /// The design screen the section opens on (`design_copy.json` keys). Settings shows the screen
    /// of its selected subpage (`SettingsSubpage.screen`); this is its General page.
    public var screen: DesignScreen {
        switch self {
        case .today: return .today
        case .meetings: return .meetings
        case .notes: return .today   // no design screen of its own; its copy is `NotesCopy`
        case .dictionary: return .dictionary
        case .voice: return .voice
        case .privacy: return .privacy
        case .settings: return .settings
        }
    }

    /// Sections added after the prototype, whose page copy is their own rather than a fixture screen's.
    public var isPostPrototype: Bool { self == .notes }

    /// The page title (`design_copy.json` › `screens.<screen>.title`, verbatim).
    public var detailTitle: String { self == .notes ? NotesCopy.title : (screen.page?.title ?? title) }

    /// The page subtitle (`design_copy.json` › `screens.<screen>.subtitle`, verbatim).
    public var subtitle: String { self == .notes ? NotesCopy.subtitle : (screen.page?.subtitle ?? "") }

    /// SF Symbols already in the app's vocabulary (`DESIGN.md` §12.3: one mark, everything else is
    /// SF Symbols already in use).
    public var systemImage: String {
        switch self {
        case .today: return "clock"
        case .meetings: return "person.2.wave.2"
        case .notes: return "note.text"
        case .dictionary: return "character.book.closed"
        case .voice: return "waveform"
        case .privacy: return "hand.raised"
        case .settings: return "gear"
        }
    }

    /// 1…7, matching `⌘1`–`⌘7` (`DESIGN.md` §5.2; Notes added by V5 N1).
    public var shortcutIndex: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }

    /// The key character for `.keyboardShortcut`.
    public var shortcutKey: Character { Character("\(shortcutIndex)") }

    /// Sections with a local search, so `⌘F` has somewhere to go (`DESIGN.md` §5.2). The shell draws
    /// the one search field in the toolbar for these sections only ("the toolbar holds only relevant
    /// actions") and hands its query to the section through `SectionNavigation.searchQuery`.
    public var hasSearchField: Bool {
        switch self {
        case .today, .meetings, .notes, .dictionary: return true
        case .voice, .privacy, .settings: return false
        }
    }

    /// Where a legacy `SettingsTab` deep link now lands (its section; `LegacySettingsTab.route` has
    /// the subpage / pane / disclosure too). Callers that used to open a tab keep working.
    public static func section(for legacy: LegacySettingsTab) -> MainWindowSection { legacy.home }

    /// The window's remembered section (`DESIGN.md` §5.1). Stored as the raw value; an unknown or
    /// missing value opens Today rather than failing.
    public static let selectionKey = "window.section"

    public static func remembered(_ store: SettingsStore?) -> MainWindowSection {
        guard let raw = store?.string(selectionKey), let section = MainWindowSection(rawValue: raw) else { return .today }
        return section
    }

    public static func remember(_ section: MainWindowSection, store: SettingsStore?) {
        store?.set(section.rawValue, for: selectionKey)
    }
}

// MARK: - Settings subpages (design §8.6)

/// Settings' subnavigation — exactly the design's seven, in the design's order. There is no other
/// subpage: the old `benchmark`, `flags`, `data`, `snippets` and `personas` tabs are re-homed into
/// other sections (`LegacySettingsTab.route`), never given a page of their own.
public enum SettingsSubpage: String, CaseIterable, Identifiable, Sendable {
    case general, shortcuts, appearance, models, providers, sync, updates

    public var id: String { rawValue }

    /// The subnav label (design §8.6 "Subnavigation: General, Shortcuts, Appearance, Models,
    /// Providers, Sync, Updates").
    public var title: String {
        switch self {
        case .general: return "General"
        case .shortcuts: return "Shortcuts"
        case .appearance: return "Appearance"
        case .models: return "Models"
        case .providers: return "Providers"
        case .sync: return "Sync"
        case .updates: return "Updates"
        }
    }

    /// The prototype screen whose copy the subpage uses. General is the prototype's `settings` screen;
    /// Providers and Sync share its `services` screen ("Providers & Sync"). Appearance and Updates
    /// have no screen of their own in the prototype (they are "More settings" buttons on the Settings
    /// screen), so they use the Settings screen's copy.
    public var screen: DesignScreen {
        switch self {
        case .general, .appearance, .updates: return .settings
        case .shortcuts: return .shortcuts
        case .models: return .models
        case .providers, .sync: return .services
        }
    }

    /// The page title: the screen's title, except Appearance and Updates, which borrow the Settings
    /// screen's subtitle but must not repeat its title over different rows.
    public var pageTitle: String {
        switch self {
        case .appearance, .updates: return title
        default: return screen.page?.title ?? title
        }
    }

    public var pageSubtitle: String { screen.page?.subtitle ?? "" }

    /// Remembered like the section, so `⌘,` reopens the subpage the user left.
    public static let selectionKey = "window.settings.subpage"

    public static func remembered(_ store: SettingsStore?) -> SettingsSubpage {
        guard let raw = store?.string(selectionKey), let page = SettingsSubpage(rawValue: raw) else { return .general }
        return page
    }

    public static func remember(_ page: SettingsSubpage, store: SettingsStore?) {
        store?.set(page.rawValue, for: selectionKey)
    }
}

/// Dictionary & Apps' two segmented subviews (design §8.3).
public enum DictionaryAppsPane: String, CaseIterable, Identifiable, Sendable {
    case dictionary, apps

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dictionary: return "Dictionary"
        case .apps: return "Apps"
        }
    }
}

/// A disclosure inside a section that a deep link can open. Both hold advanced material the design
/// keeps out of the main flow (`DESIGN.md` §12.6: diagnostics live in Voice › benchmarks and
/// Privacy › Diagnostics).
public enum SectionDisclosure: String, CaseIterable, Identifiable, Sendable {
    /// Voice › benchmarks (design §8.4): stage, result and diagnostics. Hosts the old Benchmark tab.
    case benchmarks
    /// Privacy › Diagnostics (design §8.5): feature flags and the data panel.
    case diagnostics

    public var id: String { rawValue }

    public var section: MainWindowSection {
        switch self {
        case .benchmarks: return .voice
        case .diagnostics: return .privacy
        }
    }

    public var title: String {
        switch self {
        case .benchmarks: return "Benchmarks"
        case .diagnostics: return "Diagnostics"
        }
    }
}

/// One address in the window: a section, plus Settings' subpage, Dictionary & Apps' pane, or a
/// disclosure to open. Every entry point (menu, deep link, onboarding, another section) opens a route.
public struct WindowRoute: Hashable, Sendable, CustomStringConvertible {
    public var section: MainWindowSection
    public var subpage: SettingsSubpage?
    public var pane: DictionaryAppsPane?
    public var disclosure: SectionDisclosure?

    public init(_ section: MainWindowSection, subpage: SettingsSubpage? = nil,
                pane: DictionaryAppsPane? = nil, disclosure: SectionDisclosure? = nil) {
        self.section = section
        self.subpage = subpage
        self.pane = pane
        self.disclosure = disclosure
    }

    public static func settings(_ subpage: SettingsSubpage) -> WindowRoute { WindowRoute(.settings, subpage: subpage) }

    /// A subpage only in Settings, a pane only in Dictionary & Apps, a disclosure only in its section.
    public var isValid: Bool {
        if subpage != nil && section != .settings { return false }
        if pane != nil && section != .dictionary { return false }
        if let disclosure, disclosure.section != section { return false }
        return true
    }

    /// "Settings › Models", "Privacy › Diagnostics" — for reports and accessibility, never a headline.
    public var description: String {
        var parts = [section.title]
        if let subpage { parts.append(subpage.title) }
        if let pane { parts.append(pane.title) }
        if let disclosure { parts.append(disclosure.title) }
        return parts.joined(separator: " › ")
    }
}

// MARK: - Geometry (design §8, `DESIGN.md` §9)

public enum MainWindowLayout {
    /// Preferred content size on first open (the frame is remembered afterwards).
    public static let preferredSize = CGSize(width: 1080, height: 720)
    /// Minimum window size.
    public static let minimumSize = CGSize(width: 820, height: 560)
    /// Sidebar width range and its first-open width.
    public static let sidebarWidth: ClosedRange<CGFloat> = 208...240
    public static let sidebarIdealWidth: CGFloat = 220
    /// The detail pane's minimum: whatever the minimum window leaves beside the widest sidebar.
    public static var detailMinimumWidth: CGFloat { minimumSize.width - sidebarWidth.upperBound }
    /// 24 pt outer padding and 24 pt section gaps (the design's 20–24 range, on the token scale).
    public static let outerPadding: CGFloat = Tokens.Spacing.xl
    public static let sectionGap: CGFloat = Tokens.Spacing.xl
}

// MARK: - Legacy tabs and the reachability proof (R7, re-run for S7a)

/// The tabs the old `SettingsView` had, frozen. `DESIGN.md` §9.6 originally named nine
/// (`general/models/personas/dictionary/snippets/flags/connectors/sync/data`); the shipped enum had
/// eleven, because R5.3 added `voice` and R4.3 added `benchmark` after that paragraph was written.
/// All eleven are enumerated here — a tab left out of this list is a tab nobody proves is reachable.
public enum LegacySettingsTab: String, CaseIterable, Identifiable, Sendable {
    case general, models, voice, personas, dictionary, snippets, flags, connectors, sync, data, benchmark

    public var id: String { rawValue }

    /// Its old tab-bar label, so a report can name what moved in the words the user saw.
    public var title: String {
        switch self {
        case .general: return "General"
        case .models: return "Models"
        case .voice: return "Voice"
        case .personas: return "Personas"
        case .dictionary: return "Dictionary"
        case .snippets: return "Snippets"
        case .flags: return "Flags"
        case .connectors: return "Services"
        case .sync: return "Sync"
        case .data: return "Data"
        case .benchmark: return "Benchmark"
        }
    }

    /// Where a deep link to the tab opens (design §8.6, build doc S7a): re-homed, never given a new
    /// Settings subpage — `benchmark` → Voice › benchmarks, `flags` and `data` → Privacy ›
    /// Diagnostics, `snippets` and `personas` → Dictionary & Apps.
    public var route: WindowRoute {
        switch self {
        case .general: return .settings(.general)
        case .models: return .settings(.models)
        case .connectors: return .settings(.providers)
        case .sync: return .settings(.sync)
        case .voice: return WindowRoute(.voice)
        case .benchmark: return WindowRoute(.voice, disclosure: .benchmarks)
        case .flags, .data: return WindowRoute(.privacy, disclosure: .diagnostics)
        case .dictionary, .snippets: return WindowRoute(.dictionary, pane: .dictionary)
        case .personas: return WindowRoute(.dictionary, pane: .apps)
        }
    }

    /// Where the tab's *primary* content went. Tabs whose settings split across two sections
    /// (General: keys stay in Settings, the microphone moves to Voice, recordings move to Privacy)
    /// name the section that owns the majority; `SettingsReachability` is per-setting and is what
    /// actually proves nothing was lost.
    public var home: MainWindowSection { route.section }
}

/// One old setting, and the marker that proves it is still on screen somewhere.
public struct LegacySettingsItem: Sendable, Equatable, Identifiable {
    /// The tab it used to live on.
    public let tab: LegacySettingsTab
    /// What it is, in words, for the report.
    public let name: String
    /// An accessibility identifier, or `SomeView(` for a whole hosted sub-view. Must appear
    /// literally in one of `home`'s source files.
    public let marker: String
    /// Its section in the one window.
    public let home: MainWindowSection
    /// Its Settings subpage (design §8.6), for items whose home is Settings. S7g splits the Settings
    /// pane by this; the reachability test holds every Settings item to one.
    public let subpage: SettingsSubpage?

    public var id: String { "\(tab.rawValue).\(marker)" }

    /// The full address a user follows to reach it.
    public var route: WindowRoute {
        let tabRoute = tab.route
        if home == .settings { return .settings(subpage ?? tabRoute.subpage ?? .general) }
        if tabRoute.section == home { return tabRoute }
        return WindowRoute(home)
    }

    public init(_ tab: LegacySettingsTab, _ name: String, _ marker: String, _ home: MainWindowSection,
                _ subpage: SettingsSubpage? = nil) {
        self.tab = tab
        self.name = name
        self.marker = marker
        self.home = home
        self.subpage = subpage
    }
}

/// Every setting the nine-plus-two tabs had, and its new address.
public enum SettingsReachability {
    public static let items: [LegacySettingsItem] = [
        // MARK: General → Settings › Shortcuts / General / Appearance, microphone → Voice, recordings → Privacy
        .init(.general, "Dictation key", "settings.hotkey", .settings, .shortcuts),
        .init(.general, "Dictation key permission note", "settings.hotkeyPermissionNote", .settings, .shortcuts),
        .init(.general, "Actions key", "settings.actKey", .settings, .shortcuts),
        .init(.general, "Actions key note", "settings.actKeyNote", .settings, .shortcuts),
        .init(.general, "Legacy event-tap listener", "settings.forceEventTap", .settings, .shortcuts),
        .init(.general, "Show indicator under the notch", "settings.presenceIndicator", .settings, .appearance),
        .init(.general, "Hide it in full screen", "settings.presenceHideInFullScreen", .settings, .appearance),
        .init(.general, "Run onboarding again", "settings.runOnboardingAgain", .settings, .general),
        .init(.general, "Silent corrections", "CorrectionSettingsSection(", .settings, .general),
        .init(.general, "Launch at login", "settings.launchAtLogin", .settings, .general),
        .init(.general, "Microphone picker", "settings.microphone", .voice),
        .init(.general, "Microphone note", "settings.microphoneNote", .voice),
        .init(.general, "Save recordings", "settings.saveRecordings", .privacy),
        .init(.general, "Save recordings note", "settings.saveRecordingsNote", .privacy),
        .init(.general, "Recordings on disk / reveal / delete", "settings.recordings", .privacy),

        // MARK: Models → Settings › Models (the provider list → Settings › Providers)
        .init(.models, "Per-stage routing", "settings.routing.", .settings, .models),
        .init(.models, "Reset all to Auto", "settings.resetRoutingToAuto", .settings, .models),
        .init(.models, "Speech model summary", "settings.speechModel", .settings, .models),
        .init(.models, "Connected providers", "settings.connectedProviders", .settings, .providers),
        .init(.models, "Connect what you pay for", "settings.connectProviders", .settings, .providers),

        // MARK: Voice (second pass) → Voice › Second pass
        .init(.voice, "Refinement mode and its honest availability note", "VoiceSettingsTab(", .voice),

        // MARK: Personas → Dictionary & Apps › Apps
        .init(.personas, "Persona list", "apps.personas.list", .dictionary),
        .init(.personas, "Persona app bundle ID", "apps.personas.bundleID", .dictionary),
        .init(.personas, "Persona instructions", "apps.personas.instructions", .dictionary),
        .init(.personas, "Auto-draft from my style", "apps.personas.autoDraft", .dictionary),
        .init(.personas, "Save persona", "apps.personas.save", .dictionary),

        // MARK: Dictionary → Dictionary & Apps › Dictionary
        .init(.dictionary, "Filter", "dictionary.filter", .dictionary),
        .init(.dictionary, "Add term", "dictionary.add", .dictionary),
        .init(.dictionary, "Train by voice", "dictionary.trainByVoice", .dictionary),
        .init(.dictionary, "Import names from Contacts", "dictionary.importContacts", .dictionary),
        .init(.dictionary, "Learned automatically / Forget", "dictionary.learned", .dictionary),

        // MARK: Snippets → Dictionary & Apps › Dictionary
        .init(.snippets, "Spoken snippets", "SnippetsSettingsTab(", .dictionary),

        // MARK: Flags → Privacy › Diagnostics (design §8.5)
        .init(.flags, "Flag toggles", "privacy.diagnostics.flag.", .privacy),
        .init(.flags, "Reset to defaults", "privacy.diagnostics.flagsReset", .privacy),

        // MARK: Services → Settings › Providers
        .init(.connectors, "Connected services", "ConnectorsSettingsTab(", .settings, .providers),

        // MARK: Sync → Settings › Sync
        .init(.sync, "Pairing, folder transport, export/import", "SyncSettingsTab(", .settings, .sync),

        // MARK: Data → Privacy (network activity, kill switch) › Diagnostics
        .init(.data, "Egress log", "privacy.egressTable", .privacy),
        .init(.data, "Bytes out today", "privacy.bytesOutToday", .privacy),
        .init(.data, "Refresh", "privacy.egressRefresh", .privacy),
        .init(.data, "Block all network egress", "privacy.killSwitch", .privacy),

        // MARK: Benchmark → Voice › benchmarks disclosure
        .init(.benchmark, "Ranked-context-list counters", "benchmark.row", .voice),
        .init(.benchmark, "No measurements yet", "benchmark.empty", .voice),
        .init(.benchmark, "Recall gain", "benchmark.recallGain", .voice),
        .init(.benchmark, "Within / over budget", "benchmark.passLabel", .voice),
    ]

    /// Settings that had no UI at all before R7.2 and now do. Listed so the reachability test
    /// covers them too, and so "we added a switch" is a claim with a file behind it.
    public static let newlySurfaced: [LegacySettingsItem] = [
        .init(.general, "Never inject into this app (R2.3)", "apps.neverInject", .dictionary),
        .init(.data, "Ambient capture", "privacy.ambientCapture", .privacy),
        .init(.data, "Keep other voices too (R8.1)", "privacy.ambientEverySpeaker", .privacy),
        .init(.data, "Transcript retention", "privacy.retentionDays", .privacy),
        .init(.data, "Delete everything saved", "privacy.deleteAll", .privacy),
        .init(.benchmark, "Run the Lab on this Mac", "voice.benchmark.run", .voice),
        .init(.benchmark, "The Lab's own panel (was a standalone window)", "LabPanelView(", .voice),
        .init(.benchmark, "Personal WER trend (was the Lab window's second tab)", "PersonalWERView(", .voice),
        .init(.general, "Voice enrollment (was its own window)", "voice.enrollment", .voice),
        .init(.general, "Meeting capture", "meetings.captureEnabled", .meetings),
        .init(.general, "Expose text in Chromium browsers (V5 Q2)", "settings.insertion.exposeChromiumText", .settings, .general),
        .init(.general, "Confirm in apps that hide their text — Screen Recording, off (V5 Q14)",
              "settings.insertion.confirmHiddenText", .settings, .general),
    ]

    /// Source files that make up each section's detail pane: the section's `SectionScreen` entry
    /// point (S7a) and the pane it hosts. The reachability test greps these.
    public static func sourceFiles(for section: MainWindowSection) -> [String] {
        switch section {
        case .today: return ["App/Settings/TodayScreen.swift", "App/Settings/TodaySectionView.swift"]
        case .meetings: return ["App/Settings/MeetingsScreen.swift", "App/Settings/MeetingsSectionView.swift"]
        case .notes: return ["App/Settings/NotesScreen.swift"]
        case .dictionary: return ["App/Settings/DictionaryAppsScreen.swift", "App/Settings/DictionaryAppsSectionView.swift"]
        case .voice: return ["App/Settings/VoiceScreen.swift", "App/Settings/VoiceSectionView.swift"]
        case .privacy: return ["App/Settings/PrivacyScreen.swift", "App/Settings/PrivacySectionView.swift"]
        case .settings: return ["App/Settings/SettingsScreen.swift", "App/Settings/SettingsView.swift"]
        }
    }

    /// Everything that must be provable, old and new.
    public static var allItems: [LegacySettingsItem] { items + newlySurfaced }
}
