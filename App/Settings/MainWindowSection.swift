import Foundation

// R7.1 / R7.2 — the one window's six sections, and the proof that folding the nine-tab `TabView`
// into them left nothing behind (`DESIGN.md` §9, §9.6).
//
// The reachability catalogue at the bottom of this file is the load-bearing part: it names every
// setting the old tabbed window had, where it now lives, and the marker (accessibility identifier,
// or the hosted view's type) that must appear in that section's source. `SettingsReachabilityTests`
// reads the source files and fails if any marker went missing — which is the only way a toolchain
// with no UI testing can assert "you can still get at this".

/// The sidebar, in the order `DESIGN.md` §9 fixes, with `⌘1`–`⌘6` in that same order.
public enum MainWindowSection: String, CaseIterable, Identifiable, Sendable {
    case today, meetings, dictionary, voice, privacy, settings

    public var id: String { rawValue }

    /// Sidebar label. Short on purpose — the detail pane's header carries the full name.
    public var title: String {
        switch self {
        case .today: return "Today"
        case .meetings: return "Meetings"
        case .dictionary: return "Dictionary"
        case .voice: return "Voice"
        case .privacy: return "Privacy"
        case .settings: return "Settings"
        }
    }

    /// The detail pane's title, which is the section's name in `DESIGN.md` §9.
    public var detailTitle: String {
        switch self {
        case .today: return "Today"
        case .meetings: return "Meetings"
        case .dictionary: return "Dictionary / Apps"
        case .voice: return "Voice"
        case .privacy: return "Privacy"
        case .settings: return "Settings"
        }
    }

    /// One line under the title. Optional per §9; every section has one because every section can
    /// be opened cold from the menu.
    public var subtitle: String {
        switch self {
        case .today: return "What's ready, what needs you, and what was said."
        case .meetings: return "Transcripts of calls, kept on this Mac."
        case .dictionary: return "Words this Mac gets wrong, and what each app does."
        case .voice: return "The microphone, your enrolled voice, and the measurements."
        case .privacy: return "What is captured, what is saved, what is transmitted."
        case .settings: return "Everything that is a preference and not a state."
        }
    }

    /// SF Symbols already in the app's vocabulary (`DESIGN.md` §12.3 forbids new glyphs).
    public var systemImage: String {
        switch self {
        case .today: return "clock"
        case .meetings: return "person.2.wave.2"
        case .dictionary: return "character.book.closed"
        case .voice: return "waveform"
        case .privacy: return "hand.raised"
        case .settings: return "gear"
        }
    }

    /// 1…6, matching `⌘1`–`⌘6` (`DESIGN.md` §5.2).
    public var shortcutIndex: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }

    /// The key character for `.keyboardShortcut`.
    public var shortcutKey: Character { Character("\(shortcutIndex)") }

    /// Sections with a search field, so `⌘F` has somewhere to go (`DESIGN.md` §5.2).
    public var hasSearchField: Bool {
        switch self {
        case .today, .meetings, .dictionary: return true
        case .voice, .privacy, .settings: return false
        }
    }

    /// Where a legacy `SettingsTab` deep link now lands. Callers that used to open a tab
    /// (`AppContainer`'s Providers link, the menu) keep working without knowing the window changed.
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

/// The tabs the old `SettingsView` had, frozen. `DESIGN.md` §9.6 names nine
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

    /// Where the tab's *primary* content went. Tabs whose settings split across two sections
    /// (General: keys stay in Settings, the microphone moves to Voice, recordings move to Privacy)
    /// name the section that owns the majority; `SettingsReachability` is per-setting and is what
    /// actually proves nothing was lost.
    public var home: MainWindowSection {
        switch self {
        case .general, .models, .flags, .connectors, .sync: return .settings
        case .voice: return .voice
        case .personas, .dictionary, .snippets: return .dictionary
        case .data: return .privacy
        case .benchmark: return .voice
        }
    }
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

    public var id: String { "\(tab.rawValue).\(marker)" }

    public init(_ tab: LegacySettingsTab, _ name: String, _ marker: String, _ home: MainWindowSection) {
        self.tab = tab
        self.name = name
        self.marker = marker
        self.home = home
    }
}

/// Every setting the nine-plus-two tabs had, and its new address.
public enum SettingsReachability {
    public static let items: [LegacySettingsItem] = [
        // MARK: General → Settings › Keys / Behaviour / Presence, microphone → Voice, recordings → Privacy
        .init(.general, "Dictation key", "settings.hotkey", .settings),
        .init(.general, "Dictation key permission note", "settings.hotkeyPermissionNote", .settings),
        .init(.general, "Actions key", "settings.actKey", .settings),
        .init(.general, "Actions key note", "settings.actKeyNote", .settings),
        .init(.general, "Legacy event-tap listener", "settings.forceEventTap", .settings),
        .init(.general, "Show indicator under the notch", "settings.presenceIndicator", .settings),
        .init(.general, "Hide it in full screen", "settings.presenceHideInFullScreen", .settings),
        .init(.general, "Run onboarding again", "settings.runOnboardingAgain", .settings),
        .init(.general, "Silent corrections", "CorrectionSettingsSection(", .settings),
        .init(.general, "Launch at login", "settings.launchAtLogin", .settings),
        .init(.general, "Microphone picker", "settings.microphone", .voice),
        .init(.general, "Microphone note", "settings.microphoneNote", .voice),
        .init(.general, "Save recordings", "settings.saveRecordings", .privacy),
        .init(.general, "Save recordings note", "settings.saveRecordingsNote", .privacy),
        .init(.general, "Recordings on disk / reveal / delete", "settings.recordings", .privacy),

        // MARK: Models → Settings › Models
        .init(.models, "Per-stage routing", "settings.routing.", .settings),
        .init(.models, "Reset all to Auto", "settings.resetRoutingToAuto", .settings),
        .init(.models, "Speech model summary", "settings.speechModel", .settings),
        .init(.models, "Connected providers", "settings.connectedProviders", .settings),
        .init(.models, "Connect what you pay for", "settings.connectProviders", .settings),

        // MARK: Voice (second pass) → Voice › Second pass
        .init(.voice, "Refinement mode and its honest availability note", "VoiceSettingsTab(", .voice),

        // MARK: Personas → Dictionary / Apps › Apps
        .init(.personas, "Persona list", "apps.personas.list", .dictionary),
        .init(.personas, "Persona app bundle ID", "apps.personas.bundleID", .dictionary),
        .init(.personas, "Persona instructions", "apps.personas.instructions", .dictionary),
        .init(.personas, "Auto-draft from my style", "apps.personas.autoDraft", .dictionary),
        .init(.personas, "Save persona", "apps.personas.save", .dictionary),

        // MARK: Dictionary → Dictionary / Apps › Dictionary
        .init(.dictionary, "Filter", "dictionary.filter", .dictionary),
        .init(.dictionary, "Add term", "dictionary.add", .dictionary),
        .init(.dictionary, "Train by voice", "dictionary.trainByVoice", .dictionary),
        .init(.dictionary, "Import names from Contacts", "dictionary.importContacts", .dictionary),
        .init(.dictionary, "Learned automatically / Forget", "dictionary.learned", .dictionary),

        // MARK: Snippets → Dictionary / Apps › Apps
        .init(.snippets, "Spoken snippets", "SnippetsSettingsTab(", .dictionary),

        // MARK: Flags → Settings › Feature flags
        .init(.flags, "Flag toggles", "settings.flag.", .settings),
        .init(.flags, "Reset to defaults", "settings.flagsReset", .settings),

        // MARK: Services → Settings › Providers / Services
        .init(.connectors, "Connected services", "ConnectorsSettingsTab(", .settings),

        // MARK: Sync → Settings › Sync
        .init(.sync, "Pairing, folder transport, export/import", "SyncSettingsTab(", .settings),

        // MARK: Data → Privacy › Transmitted
        .init(.data, "Egress log", "privacy.egressTable", .privacy),
        .init(.data, "Bytes out today", "privacy.bytesOutToday", .privacy),
        .init(.data, "Refresh", "privacy.egressRefresh", .privacy),
        .init(.data, "Block all network egress", "privacy.killSwitch", .privacy),

        // MARK: Benchmark → Voice › Benchmark
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
    ]

    /// Source files that make up each section's detail pane. The reachability test greps these.
    public static func sourceFiles(for section: MainWindowSection) -> [String] {
        switch section {
        case .today: return ["App/Settings/TodaySectionView.swift"]
        case .meetings: return ["App/Settings/MeetingsSectionView.swift"]
        case .dictionary: return ["App/Settings/DictionaryAppsSectionView.swift"]
        case .voice: return ["App/Settings/VoiceSectionView.swift"]
        case .privacy: return ["App/Settings/PrivacySectionView.swift"]
        case .settings: return ["App/Settings/SettingsView.swift"]
        }
    }

    /// Everything that must be provable, old and new.
    public static var allItems: [LegacySettingsItem] { items + newlySurfaced }
}
