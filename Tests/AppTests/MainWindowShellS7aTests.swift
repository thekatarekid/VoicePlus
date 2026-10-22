import AppKit
import Engine
import Foundation
import Lab
import Pipeline
import Shared
import SwiftUI
import Testing
@testable import VoicePlusApp

/// S7a — the window shell (design §8, §9; `DESIGN.md` §9): sections, shortcuts, Settings' subpage
/// routing and the re-homed tabs, per-section state preservation, and a snapshot of every
/// `SectionRendering` the page component draws.
///
/// Copy is held to its sources, never retyped: `Fixtures/design/design_copy.json` (`screens`,
/// `emptyCopy`, `screenError`) and the verified prototype `docs/design-history/design/design_v1.html` (sidebar labels,
/// screen names, the loading / error / partial wording, the sidebar footer). No SwiftUI `body` can be
/// driven on this toolchain, so the page is asserted through `SectionPageAnatomy` — the blocks the
/// view renders one for one — plus an `ImageRenderer` pixel smoke test of the page itself.
@Suite("MainWindowShellTests · S7a window shell")
@MainActor
struct MainWindowShellS7aTests {

    // MARK: - Sources

    static let packageRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url
    }()

    static func read(_ path: String) throws -> String {
        try String(contentsOf: packageRoot.appendingPathComponent(path), encoding: .utf8)
    }

    static func copyFixture() throws -> [String: Any] {
        let data = try Data(contentsOf: packageRoot.appendingPathComponent("Fixtures/design/design_copy.json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func prototype() throws -> String { try read("docs/design-history/design/design_v1.html") }

    /// `const screens=[ ['today','Today','…'], … ]` → key → name.
    static func prototypeScreenNames() throws -> [String: String] {
        let html = try prototype()
        let start = try #require(html.range(of: "const screens=["))
        let end = try #require(html.range(of: "];", range: start.upperBound..<html.endIndex))
        let block = String(html[start.upperBound..<end.lowerBound])
        let regex = try NSRegularExpression(pattern: #"\['([a-z-]+)','([^']+)','"#)
        var names: [String: String] = [:]
        for match in regex.matches(in: block, range: NSRange(block.startIndex..., in: block)) {
            let key = String(block[Range(match.range(at: 1), in: block)!])
            names[key] = String(block[Range(match.range(at: 2), in: block)!])
        }
        return names
    }

    /// `<button data-screen="today">◷ &nbsp; Today</button>` → in order.
    static func prototypeSidebar() throws -> [(key: String, label: String)] {
        let html = try prototype()
        let regex = try NSRegularExpression(pattern: #"data-screen="([a-z]+)">[^<]*?&nbsp; ([^<]+)</button>"#)
        return regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).map { match in
            (String(html[Range(match.range(at: 1), in: html)!]), String(html[Range(match.range(at: 2), in: html)!]))
        }
    }

    static let defaultKey = HotkeyService.defaultBinding.label

    // MARK: - A window model with in-memory everything

    static func window(store: InMemorySettingsStore = InMemorySettingsStore(),
                       section: MainWindowSection? = nil,
                       mute: InMemoryMuteStore = InMemoryMuteStore()) -> MainWindowViewModel {
        var deps = OnboardingDependencies.mock()
        deps.settingsStore = store
        let defaults = UserDefaults(suiteName: "vp.s7a.\(UUID().uuidString)")!
        let audio = AudioInputSettingsViewModel(defaults: defaults)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("vp-s7a-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let checker = OnboardingMockPermissionChecker(results: [:])
        let today = TodaySectionViewModel(deps: deps, audio: audio, mute: mute, reader: nil, ambientCaptureOn: { false })
        let meetings = MeetingsSectionViewModel(store: MeetingStore(root: temp), settings: store,
                                                calendarAuthorized: { true },
                                                list: { _ in (records: [], unreadable: []) })
        let dictionaryApps = DictionaryAppsSectionViewModel(dictionary: DictionaryViewModel(database: nil),
                                                           learned: LearnedDictionaryViewModel(loop: nil, store: nil),
                                                           personas: PersonasViewModel(database: nil),
                                                           snippets: SnippetsViewModel(store: InMemorySnippetStore()),
                                                           defaults: defaults)
        let voice = VoiceSectionViewModel(audio: audio, permissions: checker,
                                          lab: LabPanelViewModel(choices: [], runner: LabRunner(clock: { 0 }, hardware: "test", thermal: { .nominal })),
                                          counters: BenchmarkViewModel(report: nil),
                                          profiles: SpeakerProfileStore(url: temp.appendingPathComponent("profile.json")),
                                          makeEnrollment: nil)
        let privacy = PrivacySectionViewModel(settings: store, flags: .inMemory(), gate: EgressGate(defaults: defaults),
                                              audio: audio, database: nil, load: { _ in [] },
                                              bytesToday: { _ in 0 }, deleteEverything: { 0 })
        return MainWindowViewModel(deps: deps, today: today, meetings: meetings, dictionaryApps: dictionaryApps,
                                   voice: voice, privacy: privacy,
                                   general: GeneralSettingsViewModel(store: store),
                                   models: ModelsSettingsViewModel(store: store, models: deps.models, flags: deps.flags),
                                   flags: FlagsViewModel(service: deps.flags),
                                   connectors: ConnectorsSettingsViewModel(hub: nil),
                                   sync: SyncSettingsViewModel(service: nil),
                                   corrections: CorrectionSettingsViewModel(store: store),
                                   section: section)
    }

    // MARK: - Sections

    @Test("six sections in the design's order, labelled as the prototype's sidebar labels them")
    func sectionsMatchThePrototypeSidebar() throws {
        let sidebar = try Self.prototypeSidebar()
        // V5 N1's Notes postdates the prototype; every prototype section is still there, in order.
        let prototypeSections = MainWindowSection.allCases.filter { !$0.isPostPrototype }
        #expect(sidebar.map(\.key) == prototypeSections.map(\.rawValue))
        #expect(sidebar.map(\.label) == prototypeSections.map(\.title))
        #expect(MainWindowSection.dictionary.title == "Dictionary & Apps")
    }

    @Test("page titles and subtitles are the fixture's `screens`, verbatim")
    func pageTitlesAreTheFixture() throws {
        let screens = try #require(try Self.copyFixture()["screens"] as? [String: [String: String]])
        for section in MainWindowSection.allCases where !section.isPostPrototype {
            let fixture = try #require(screens[section.screen.rawValue], "no fixture screen for \(section)")
            #expect(section.detailTitle == fixture["title"])
            #expect(section.subtitle == fixture["subtitle"])
        }
        #expect(MainWindowSection.today.subtitle == "Your words, right where you left them.")
        #expect(MainWindowSection.voice.subtitle == "Make sure we hear you clearly.")
        #expect(SettingsSubpage.models.pageSubtitle == "Ready means verified and loaded.")
        #expect(SettingsSubpage.providers.pageSubtitle == "Local first. Connections when you choose.")
    }

    @Test("window geometry: 1080 × 720 preferred, 820 × 560 minimum, sidebar 208–240, 24 pt padding and gaps")
    func geometry() throws {
        #expect(MainWindowLayout.preferredSize == CGSize(width: 1080, height: 720))
        #expect(MainWindowLayout.minimumSize == CGSize(width: 820, height: 560))
        #expect(MainWindowLayout.sidebarWidth == 208...240)
        #expect(MainWindowLayout.sidebarWidth.contains(MainWindowLayout.sidebarIdealWidth))
        #expect(MainWindowLayout.outerPadding == 24 && MainWindowLayout.sectionGap == 24)
        #expect(Tokens.Spacing.scale.contains(MainWindowLayout.outerPadding))
        #expect(MainWindowLayout.detailMinimumWidth == 580)
        // The controller and the view take their numbers from the layout, not literals of their own.
        let controller = try Self.read("App/Settings/MainWindowController.swift")
        #expect(controller.contains("setContentSize(MainWindowLayout.preferredSize)"))
        #expect(controller.contains("contentMinSize = MainWindowLayout.minimumSize"))
        #expect(!controller.contains("NSSize(width: 900"))
        let view = try Self.read("App/Settings/MainWindowView.swift")
        #expect(view.contains("MainWindowLayout.sidebarWidth.lowerBound") && view.contains("MainWindowLayout.sidebarWidth.upperBound"))
    }

    // MARK: - Shortcuts

    @Test("⌘1–⌘6 select the six sections; ⌘, opens Settings; ⌘F exists only where there is a search")
    func shortcuts() throws {
        #expect(MainWindowSection.allCases.map(\.shortcutKey) == ["1", "2", "3", "4", "5", "6", "7"])
        let view = try Self.read("App/Settings/MainWindowView.swift")
        #expect(view.contains(".keyboardShortcut(KeyEquivalent(section.shortcutKey), modifiers: .command)"))
        #expect(view.contains(#".keyboardShortcut(",", modifiers: .command)"#))
        #expect(view.contains(#".keyboardShortcut("f", modifiers: .command)"#))
        #expect(view.contains("if model.selection.hasSearchField { searchFocused = true }"))
        // The toolbar search appears only for Today, Meetings and Dictionary & Apps.
        #expect(MainWindowSection.allCases.filter(\.hasSearchField) == [.today, .meetings, .notes, .dictionary])

        let store = InMemorySettingsStore()
        let window = Self.window(store: store, section: .today)
        for section in MainWindowSection.allCases {
            window.apply(WindowRoute(section))
            #expect(window.selection == section)
            #expect(MainWindowSection.remembered(store) == section)
        }
        // ⌘, reopens Settings at the subpage the user left.
        window.apply(.settings(.appearance))
        window.apply(WindowRoute(.today))
        window.openSettings()
        #expect(window.selection == .settings)
        #expect(window.settingsSubpage == .appearance)
    }

    // MARK: - Settings subpages and re-homed tabs

    @Test("Settings has exactly the design's seven subpages, in order, and no other")
    func sevenSubpages() {
        // V5 CU1 adds Computer use after Providers; V5 LANG1 adds Languages after Appearance.
        #expect(SettingsSubpage.allCases.map(\.title) == ["General", "Shortcuts", "Appearance", "Languages", "Edit commands", "Models", "Providers", "Computer use", "Sync", "Updates"])
        // The retired tabs never become a subpage.
        for retired in ["benchmark", "flags", "data", "snippets", "personas", "voice", "dictionary", "connectors", "advanced"] {
            #expect(SettingsSubpage(rawValue: retired) == nil)
        }
        #expect(SettingsSubpage.general.screen == .settings)
        #expect(SettingsSubpage.shortcuts.screen == .shortcuts)
        #expect(SettingsSubpage.models.screen == .models)
        #expect(SettingsSubpage.providers.screen == .services && SettingsSubpage.sync.screen == .services)
        #expect(SettingsSubpage.appearance.pageTitle == "Appearance" && SettingsSubpage.updates.pageTitle == "Updates")
        #expect(SettingsSubpage.general.pageTitle == "Settings")
        #expect(SettingsSubpage.providers.pageTitle == "Providers & Sync")
    }

    @Test("every old tab opens its re-homed address: benchmark → Voice, flags and data → Privacy › Diagnostics")
    func legacyTabsAreReHomed() {
        let expected: [LegacySettingsTab: WindowRoute] = [
            .general: .settings(.general),
            .models: .settings(.models),
            .connectors: .settings(.providers),
            .sync: .settings(.sync),
            .voice: WindowRoute(.voice),
            .benchmark: WindowRoute(.voice, disclosure: .benchmarks),
            .flags: WindowRoute(.privacy, disclosure: .diagnostics),
            .data: WindowRoute(.privacy, disclosure: .diagnostics),
            .dictionary: WindowRoute(.dictionary, pane: .dictionary),
            .snippets: WindowRoute(.dictionary, pane: .dictionary),
            .personas: WindowRoute(.dictionary, pane: .apps),
        ]
        #expect(Set(expected.keys) == Set(LegacySettingsTab.allCases))
        for tab in LegacySettingsTab.allCases {
            #expect(tab.route == expected[tab], "\(tab) opens \(tab.route), expected \(String(describing: expected[tab]))")
            #expect(tab.route.isValid)
            #expect(tab.home == tab.route.section)
        }
        // The disclosures belong to the sections the design puts them in.
        #expect(SectionDisclosure.benchmarks.section == .voice)
        #expect(SectionDisclosure.diagnostics.section == .privacy)
    }

    @Test("opening a route selects the section, then its subpage, pane or disclosure; a bad route opens only the section")
    func routing() {
        let store = InMemorySettingsStore()
        let window = Self.window(store: store, section: .today)

        window.apply(LegacySettingsTab.models.route)
        #expect(window.selection == .settings && window.settingsSubpage == .models)
        #expect(window.currentRoute == .settings(.models))
        #expect(window.currentScreen == .models)
        #expect(SettingsSubpage.remembered(store) == .models)

        window.apply(LegacySettingsTab.flags.route)
        #expect(window.selection == .privacy)
        #expect(window.navigation(.privacy).isExpanded(.diagnostics))
        #expect(!window.navigation(.voice).isExpanded(.benchmarks))

        window.apply(LegacySettingsTab.benchmark.route)
        #expect(window.selection == .voice && window.navigation(.voice).isExpanded(.benchmarks))

        window.apply(LegacySettingsTab.personas.route)
        #expect(window.selection == .dictionary && window.dictionaryPane == .apps)
        #expect(window.currentRoute == WindowRoute(.dictionary, pane: .apps))

        // A subpage outside Settings is not a place: the section opens, nothing else moves.
        let bad = WindowRoute(.today, subpage: .updates, disclosure: .diagnostics)
        #expect(!bad.isValid)
        window.apply(bad)
        #expect(window.selection == .today)
        #expect(window.settingsSubpage == .models)
        #expect(WindowRoute(.voice, disclosure: .diagnostics).isValid == false)
        #expect(WindowRoute(.privacy, disclosure: .diagnostics).description == "Privacy › Diagnostics")
        #expect(WindowRoute.settings(.models).description == "Settings › Models")
    }

    @Test("the Settings subpage is remembered, and an unknown value opens General")
    func rememberedSubpage() {
        let store = InMemorySettingsStore()
        #expect(SettingsSubpage.remembered(store) == .general)
        SettingsSubpage.remember(.sync, store: store)
        #expect(store.string(SettingsSubpage.selectionKey) == "sync")
        #expect(Self.window(store: store).settingsSubpage == .sync)
        store.set("advanced", for: SettingsSubpage.selectionKey)
        #expect(SettingsSubpage.remembered(store) == .general)
        #expect(SettingsSubpage.remembered(nil) == .general)
    }

    @Test("every Settings item has a subpage, and every item's address is a valid route in its home section")
    func reachabilityAddresses() {
        for item in SettingsReachability.allItems {
            #expect(item.route.isValid, "\(item.name) → \(item.route)")
            #expect(item.route.section == item.home)
            if item.home == .settings {
                #expect(item.subpage != nil, "\(item.name) has no Settings subpage for S7g to put it on")
            }
        }
        // Every subpage except Updates (whose rows are new in S7g) receives at least one old setting.
        let used = Set(SettingsReachability.allItems.compactMap(\.subpage))
        #expect(used == Set(SettingsSubpage.allCases).subtracting([.updates]))
    }

    // MARK: - The SectionScreen entry points

    @Test("each section has one SectionScreen entry point in its own file, and the shell builds only those")
    func entryPoints() throws {
        let screens: [(MainWindowSection, String, String)] = [
            (.today, "TodayScreen", "App/Settings/TodayScreen.swift"),
            (.meetings, "MeetingsScreen", "App/Settings/MeetingsScreen.swift"),
            (.dictionary, "DictionaryAppsScreen", "App/Settings/DictionaryAppsScreen.swift"),
            (.voice, "VoiceScreen", "App/Settings/VoiceScreen.swift"),
            (.privacy, "PrivacyScreen", "App/Settings/PrivacyScreen.swift"),
            (.settings, "SettingsScreen", "App/Settings/SettingsScreen.swift"),
        ]
        #expect(TodayScreen.section == .today)
        #expect(MeetingsScreen.section == .meetings)
        #expect(DictionaryAppsScreen.section == .dictionary)
        #expect(VoiceScreen.section == .voice)
        #expect(PrivacyScreen.section == .privacy)
        #expect(SettingsScreen.section == .settings)
        let shell = try Self.read("App/Settings/MainWindowView.swift")
        for (section, type, file) in screens {
            let source = try Self.read(file)
            #expect(source.contains("struct \(type): SectionScreen"), "\(file) does not declare \(type)")
            #expect(SettingsReachability.sourceFiles(for: section).first == file)
            #expect(shell.contains("\(type)(context: context)"))
        }
        // The shell names no section pane directly: S7b–S7g replace their screens without touching it.
        for pane in ["TodaySectionView(", "MeetingsSectionView(", "DictionaryAppsSectionView(", "VoiceSectionView(",
                     "PrivacySectionView(", "SettingsView("] {
            #expect(!shell.contains(pane), "the shell builds \(pane) directly")
        }
    }

    @Test("the section context carries the key label, the page copy and the route")
    func sectionContext() {
        let store = InMemorySettingsStore()
        let window = Self.window(store: store, section: .settings)
        let settings = SectionContext(window: window, section: .settings)
        window.apply(.settings(.shortcuts))
        #expect(settings.page.title == "Shortcuts")
        #expect(settings.page.subtitle == "One key. A clear beginning and end.")
        #expect(settings.hotkey == Self.defaultKey)
        #expect(settings.hotkey == "Option", "owner decision (round 4): Option is the default key")
        store.set(HotkeyBinding.Kind.rightControl.rawValue, for: HotkeyService.bindingDefaultsKey)
        #expect(settings.hotkey == "Right Control")
        let today = SectionContext(window: window, section: .today)
        today.open(WindowRoute(.privacy, disclosure: .diagnostics))
        #expect(window.selection == .privacy)
        #expect(today.navigation === window.navigation(.today))
    }

    // MARK: - State preservation

    @Test("returning to a section finds its search, selection, scroll and disclosures as they were left")
    func statePreservation() {
        let window = Self.window(section: .today)
        #expect(window.visited == [.today])
        let today = window.navigation(.today)
        today.searchQuery = "friday"
        today.selectionID = "turn-42"
        today.scrollAnchor = "row-17"
        window.apply(WindowRoute(.meetings))
        window.navigation(.meetings).searchQuery = "standup"
        window.apply(.settings(.sync))
        window.apply(WindowRoute(.voice, disclosure: .benchmarks))
        window.apply(WindowRoute(.dictionary, pane: .apps))
        window.apply(WindowRoute(.today))
        #expect(today.searchQuery == "friday")
        #expect(today.selectionID == "turn-42")
        #expect(today.scrollAnchor == "row-17")
        #expect(window.navigation(.meetings).searchQuery == "standup", "each section keeps its own query")
        #expect(window.navigation(.dictionary).searchQuery.isEmpty)
        #expect(window.navigation(.voice).isExpanded(.benchmarks))
        // Settings and Dictionary & Apps keep their subpage and pane while elsewhere.
        #expect(window.settingsSubpage == .sync)
        #expect(window.dictionaryPane == .apps)
        window.apply(WindowRoute(.settings))
        #expect(window.currentRoute == .settings(.sync))
        // Visited sections stay alive, in first-visit order, once each.
        #expect(window.visited == [.today, .meetings, .settings, .voice, .dictionary])
        // The same navigation object for the window's lifetime.
        #expect(window.navigation(.today) === today)
    }

    // MARK: - Screen copy (fixture + prototype)

    @Test("every design screen's name, page, empty copy and error are the fixture's and the prototype's")
    func screenCopyParity() throws {
        let copy = try Self.copyFixture()
        let screens = try #require(copy["screens"] as? [String: [String: String]])
        let empty = try #require(copy["emptyCopy"] as? [String: [String]])
        let errors = try #require(copy["screenError"] as? [String: String])
        let names = try Self.prototypeScreenNames()
        #expect(Set(DesignScreen.allCases.map(\.rawValue)) == Set(names.keys))
        #expect(Set(DesignScreen.allCases.map(\.rawValue)) == Set(empty.keys))
        #expect(Set(DesignScreen.allCases.map(\.rawValue)) == Set(errors.keys))
        for screen in DesignScreen.allCases {
            let key = screen.rawValue
            #expect(screen.name == names[key], "\(key) name")
            if let page = screens[key] {
                #expect(screen.page == ScreenCopy(title: page["title"]!, subtitle: page["subtitle"]!), "\(key) page")
            } else {
                #expect(screen.page == nil, "\(key) has a page the fixture does not")
            }
            let e = try #require(empty[key])
            #expect(screen.empty == EmptyCopy(headline: e[0], body: e[1], action: e[2]), "\(key) empty")
            #expect(screen.errorID.rawValue == errors[key], "\(key) error")
        }
    }

    @Test("the shell's own sentences are the prototype's, word for word")
    func shellCopyIsThePrototypes() throws {
        let html = try Self.prototype()
        for sentence in [SectionCopy.loadingNote, SectionCopy.verifyingModel, SectionCopy.errorSubtitle,
                         SectionCopy.errorFootnote, SectionCopy.partialSuffix.trimmingCharacters(in: .whitespaces),
                         SectionCopy.spoolReadyNote, SectionCopy.spoolHeldNote, #""eyebrow">\#(SectionCopy.dataKept)"#] {
            #expect(html.contains(sentence), "the prototype does not say “\(sentence)”")
        }
        // "Loading "+name.toLowerCase()+"…", except Models.
        #expect(html.contains(#"screen==='models'?'Verifying the speech model…':'Loading '+def[1].toLowerCase()+'…'"#))
        #expect(DesignScreen.today.loadingHeadline == "Loading today…")
        #expect(DesignScreen.services.loadingHeadline == "Loading providers & sync…")
        #expect(DesignScreen.models.loadingHeadline == "Verifying the speech model…")
        // The sidebar footer, with the configured key where the prototype says Right Control.
        let footer = WindowFooter(status: .ready, hotkey: "Right Control")
        #expect(html.contains(#"<footer><span class="dot"></span>\#(footer.statusLine)<br>\#(footer.hintLine)</footer>"#))
        #expect(WindowFooter(status: .ready, hotkey: Self.defaultKey).hintLine == "Hold Option to speak")
    }

    @Test("empty copy renders the configured key and changes nothing else")
    func emptyCopyUsesTheKey() {
        let today = SectionState.empty(.today, hotkey: "fn / 🌐")
        #expect(today.headline == "Nothing dictated yet")
        #expect(today.detail == "Hold fn / 🌐 and say something. Your recent words will appear here.")
        #expect(today.actionTitle == "Try dictation")
        let shortcuts = SectionState.empty(.shortcuts, hotkey: "fn / 🌐")
        #expect(shortcuts.detail == "fn / 🌐 is your default hold-to-talk key.")
        for screen in DesignScreen.allCases {
            let state = SectionState.empty(screen, hotkey: "Right Control")
            #expect(state.headline == screen.empty.headline && state.detail == screen.empty.body)
            #expect(!SectionState.empty(screen, hotkey: "fn / 🌐").detail!.contains("Right Control"))
        }
    }

    @Test("a section may name its own wait (design §9 rows) and keeps the no-empty-claim note")
    func loadingHeadlineOverride() {
        let today = SectionState.loading(.today, headline: "Loading recent dictations…")
        #expect(today.headline == "Loading recent dictations…")
        #expect(today.detail == SectionCopy.loadingNote)
        #expect(today.isWellFormed && today.actionTitle == nil)
        #expect(SectionState.loading(.today) == SectionState.loading(.today, headline: nil))
        let blocks = SectionPageAnatomy.blocks(copy: PageCopy(.today), state: today, hotkey: Self.defaultKey)
        #expect(SectionPageAnatomy.snapshot(blocks) == """
            header Today
            empty-state[ready] Loading recent dictations… / No empty-state claim while the data is still loading.
            """)
    }

    // MARK: - The four renderings plus partial

    @Test("every screen's content, empty, loading, error and partial states are well formed and distinct")
    func renderingsPerScreen() {
        for screen in DesignScreen.allCases {
            let empty = SectionState.empty(screen, hotkey: Self.defaultKey)
            let loading = SectionState.loading(screen)
            let error = SectionState.error(screen, hotkey: Self.defaultKey)
            for state in [SectionState.content, empty, loading, error] {
                #expect(state.isWellFormed, "\(screen) \(state.rendering) “\(state.headline)” is malformed")
            }
            // Loading never masquerades as empty.
            #expect(loading.headline != empty.headline)
            #expect(loading.actionTitle == nil)
            #expect(loading.detail == SectionCopy.loadingNote)
            // The error is the catalogue entry, with its one action.
            let entry = RecoveryCatalog.entry(screen.errorID).rendered(hotkey: Self.defaultKey)
            #expect(error.recoveryID == screen.errorID)
            #expect(error.headline == entry.headline && error.detail == entry.consequence && error.actionTitle == entry.action)
            let partial = SectionBanner.partial(screen, hotkey: Self.defaultKey)
            #expect(partial.headline == entry.headline)
            #expect(partial.body == entry.consequence + " Available content stays readable.")
            #expect(partial.actionTitle == entry.action)
        }
    }

    /// The page for one screen in every rendering, as blocks.
    static func pages(_ screen: DesignScreen, headerAction: String? = nil) -> [String: [PageBlock]] {
        let copy = PageCopy(screen)
        let key = defaultKey
        return [
            "content": SectionPageAnatomy.blocks(copy: copy, state: .content, headerAction: headerAction,
                                                 spoolNote: screen.contentSpoolNote, hotkey: key),
            "empty": SectionPageAnatomy.blocks(copy: copy, state: .empty(screen, hotkey: key), hotkey: key),
            "loading": SectionPageAnatomy.blocks(copy: copy, state: .loading(screen), hotkey: key),
            "error": SectionPageAnatomy.blocks(copy: copy, state: .error(screen, hotkey: key), hotkey: key),
            "partial": SectionPageAnatomy.blocks(copy: copy, state: .content, banner: .partial(screen, hotkey: key),
                                                 headerAction: headerAction, spoolNote: screen.contentSpoolNote, hotkey: key),
        ]
    }

    @Test("component snapshot: Today in each rendering, block for block as the prototype draws it")
    func todaySnapshot() {
        let pages = Self.pages(.today, headerAction: "Try dictation")
        #expect(SectionPageAnatomy.snapshot(pages["content"]!) == """
            spool-note[ready] Spool · Ready when you are. Microphone closed.
            header Today / Your words, right where you left them. [Try dictation]
            content
            """)
        #expect(SectionPageAnatomy.snapshot(pages["empty"]!) == """
            empty-state[ready] Nothing dictated yet / Hold Option and say something. Your recent words will appear here. [Try dictation]
            """)
        #expect(SectionPageAnatomy.snapshot(pages["loading"]!) == """
            header Today
            empty-state[ready] Loading today… / No empty-state claim while the data is still loading.
            """)
        #expect(SectionPageAnatomy.snapshot(pages["error"]!) == """
            header Today / Your existing data has not been cleared.
            recovery ⚠ History can’t be read — Other working sections remain available. [Try again] · Data kept: Do not clear store or claim it is empty · Technical details live behind diagnostics. A failure in this section does not disable unrelated sections.
            """)
        #expect(SectionPageAnatomy.snapshot(pages["partial"]!) == """
            spool-note[ready] Spool · Ready when you are. Microphone closed.
            banner ⚠ History can’t be read — Other working sections remain available. Available content stays readable. [Try again]
            header Today / Your words, right where you left them. [Try dictation]
            content
            """)
    }

    @Test("component snapshot: Models and Providers & Sync — verifying, not loading; the service error keeps local work")
    func settingsSnapshots() {
        let models = Self.pages(.models)
        #expect(SectionPageAnatomy.snapshot(models["loading"]!) == """
            header Models
            empty-state[ready] Verifying the speech model… / No empty-state claim while the data is still loading.
            """)
        #expect(SectionPageAnatomy.snapshot(models["empty"]!) == """
            empty-state[ready] Install a speech model / Dictation becomes available when a compatible model has been verified and loaded. [Choose a model]
            """)
        let services = Self.pages(.services)
        #expect(SectionPageAnatomy.snapshot(services["error"]!) == """
            header Providers & Sync / Your existing data has not been cleared.
            recovery ⚠ Reconnect this service — The current request was not completed. [Reconnect] · Data kept: Keep local drafts; never show API key in error · Technical details live behind diagnostics. A failure in this section does not disable unrelated sections.
            """)
        // Appearance and Updates are named for themselves in every rendering.
        let appearance = PageCopy.settings(.appearance)
        let loading = SectionPageAnatomy.blocks(copy: appearance, state: .loading(appearance.screen), hotkey: Self.defaultKey)
        #expect(loading.first == .header(title: "Appearance", subtitle: "", action: nil))
    }

    @Test("component snapshot rules hold for every screen × rendering")
    func everyRenderingSnapshot() {
        for screen in DesignScreen.allCases {
            let pages = Self.pages(screen, headerAction: "Primary")
            let copy = PageCopy(screen)
            // content: [note] · header · content; the header action only here.
            let content = pages["content"]!
            #expect(content.last == .content)
            #expect(content.contains(.header(title: copy.title, subtitle: copy.subtitle, action: "Primary")))
            #expect(content.contains { if case .spoolNote = $0 { return true } else { return false } } == (screen.contentSpoolNote != nil))
            // empty: the empty state alone, with the ready cameo and one action.
            let empty = pages["empty"]!
            let words = screen.empty.rendered(hotkey: Self.defaultKey)
            #expect(empty == [.emptyState(.ready, headline: words.headline, message: words.body, action: words.action)])
            // loading: titled with the screen's name, the ready cameo, no action, never the empty words.
            let loading = pages["loading"]!
            #expect(loading.first == .header(title: screen.name, subtitle: "", action: nil))
            #expect(loading.last == .emptyState(.ready, headline: screen.loadingHeadline, message: SectionCopy.loadingNote, action: nil))
            #expect(!SectionPageAnatomy.snapshot(loading).contains(screen.empty.headline))
            // error: the catalogue entry, its data policy, the footnote; no content, no cameo.
            let error = pages["error"]!
            let entry = RecoveryCatalog.entry(screen.errorID).rendered(hotkey: Self.defaultKey)
            #expect(error.first == .header(title: screen.name, subtitle: SectionCopy.errorSubtitle, action: nil))
            #expect(error.last == .recovery(.recovery(entry), dataKept: entry.dataPolicy, footnote: SectionCopy.errorFootnote))
            #expect(!error.contains(.content))
            // partial: the banner sits over content that stays.
            let partial = pages["partial"]!
            #expect(partial.contains(.banner(.partial(entry))))
            #expect(partial.last == .content)
            // Exactly one base rendering each: five distinct pages.
            #expect(Set(pages.values.map(SectionPageAnatomy.snapshot)).count == 5, "\(screen): two renderings draw the same page")
        }
    }

    @Test("a partial banner never shows without content to keep")
    func bannerOnlyOverContent() {
        let banner = SectionBanner.partial(.today, hotkey: Self.defaultKey)
        for state in [SectionState.empty(.today, hotkey: Self.defaultKey), .loading(.today), .error(.today, hotkey: Self.defaultKey)] {
            let blocks = SectionPageAnatomy.blocks(copy: PageCopy(.today), state: state, banner: banner, hotkey: Self.defaultKey)
            #expect(!blocks.contains(.banner(banner)))
        }
    }

    @Test("pixel smoke: empty and loading draw the still Spool cameo; content and error do not")
    func renderedPages() throws {
        func render(_ state: SectionState, banner: SectionBanner? = nil) throws -> NSBitmapImageRep {
            // Unscrolled: an `NSScrollView` does not draw into an `ImageRenderer`.
            let page = SectionPage(PageCopy(.today), state: state, banner: banner, hotkey: Self.defaultKey, scrolls: false) {
                Text("Recent dictations")
            }
            .frame(width: 640, height: 520)
            .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: page)
            renderer.scale = 1
            return NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        }
        /// Pixels of the cameo's copper tape and warm shell in the centred column where the cameo sits:
        /// hue 15–30°, saturation ≥ 0.3, brightness ≥ 0.45 — the Spool materials under their shading
        /// (`Tokens.SpoolMaterial` tape face and housing are 23° and 22°). No window text colour
        /// qualifies: ink and secondary ink are too pale (saturation ≤ 0.23), the amber notice is 35°,
        /// and their anti-aliased edges keep those hues. Solid fills are counted, not a stray edge.
        func cameoPixels(_ bitmap: NSBitmapImageRep, rows: Range<Int>) -> Int {
            var count = 0
            for y in rows.lowerBound..<min(rows.upperBound, bitmap.pixelsHigh) {
                for x in 250..<390 {
                    guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.95 else { continue }
                    let hue = c.hueComponent * 360
                    if (15...30).contains(hue) && c.saturationComponent >= 0.3 && c.brightnessComponent >= 0.45 { count += 1 }
                }
            }
            return count
        }
        let empty = try render(.empty(.today, hotkey: Self.defaultKey))
        let loading = try render(.loading(.today))
        let error = try render(.error(.today, hotkey: Self.defaultKey))
        let content = try render(.content)
        let counts = (empty: cameoPixels(empty, rows: 0..<520), loading: cameoPixels(loading, rows: 0..<520),
                      error: cameoPixels(error, rows: 0..<520), content: cameoPixels(content, rows: 0..<520))
        #expect(counts.empty >= 500, "empty: \(counts)")
        #expect(counts.loading >= 500, "loading: \(counts)")
        #expect(counts.error < 10, "error: \(counts)")
        #expect(counts.content < 10, "content: \(counts)")
        // The cameo sits above the headline: in the empty page, the top half holds it.
        #expect(cameoPixels(empty, rows: 0..<260) == counts.empty)
        // Loading and empty are different pictures (loading has a page title, empty does not).
        #expect(empty.tiffRepresentation != loading.tiffRepresentation)
    }

    // MARK: - Retry, save, footer

    @MainActor final class Runs { var count = 0 }

    @Test("retry is scoped and disabled while it runs; a second press during the retry does nothing")
    func scopedRetry() async {
        let retry = ScopedRetry()
        let gate = Gate()
        let runs = Runs()
        let first = Task { @MainActor in await retry.run { runs.count += 1; await gate.wait() } }
        while !retry.isRetrying { await Task.yield() }
        #expect(retry.isRetrying)
        let second = await retry.run { runs.count += 1 }
        #expect(second == false, "a press while the scope retries is ignored")
        gate.open()
        let firstRan = await first.value
        #expect(firstRan)
        #expect(!retry.isRetrying)
        #expect(runs.count == 1)
        let again = await retry.run { runs.count += 1 }
        #expect(again)
        #expect(runs.count == 2)
    }

    @Test("a failed save keeps the entered value and the previous active value (S02)")
    func failedSaveKeepsBothValues() {
        struct DiskFull: Error {}
        var draft = SettingDraft(900)
        draft.entered = 1500
        #expect(draft.isUnsaved)
        #expect(draft.commit { _ in throw DiskFull() } == false)
        #expect(draft.entered == 1500, "the field keeps what the user typed")
        #expect(draft.active == 900, "the app keeps using the last saved value")
        #expect(draft.failure == .S02)
        let banner = draft.failureBanner
        #expect(banner?.headline == RecoveryCatalog.entry(.S02).headline)
        #expect(banner?.body == "Your previous setting is still active.")
        var saved: Int?
        #expect(draft.commit { saved = $0 })
        #expect(saved == 1500 && draft.active == 1500 && draft.failure == nil && !draft.isUnsaved)
        draft.entered = 600
        draft.revert()
        #expect(draft.entered == 1500 && !draft.isUnsaved)
    }

    @Test("the sidebar footer says Ready only when nothing blocks dictation, and Muted when muted")
    func footerIsTruthful() {
        let row = { (id: String, ready: Bool) in
            TodaySectionViewModel.ReadinessRow(id: id, glyph: "", label: id, word: "", detail: "", actionTitle: nil, isReady: ready)
        }
        let key = Self.defaultKey
        #expect(WindowFooter.from(readiness: [row("key", true), row("mute", true)], hotkey: key).status == .ready)
        #expect(WindowFooter.from(readiness: [row("key", true), row("mute", false)], hotkey: key).status == .muted)
        #expect(WindowFooter.from(readiness: [row("model", false), row("mute", false)], hotkey: key).status == .muted)
        #expect(WindowFooter.from(readiness: [row("model", false), row("mute", true)], hotkey: key).status == .notReady)
        #expect(WindowFooter(status: .ready, hotkey: key).statusLine == "Ready · On this Mac")
        #expect(WindowFooter(status: .muted, hotkey: key).statusLine == "Muted · On this Mac")
        for status in [WindowFooter.Status.ready, .muted, .notReady] {
            #expect(!status.word.isEmpty && !status.systemImage.isEmpty, "never colour alone")
        }
        // Wired to Today's live readiness strip.
        let mute = InMemoryMuteStore()
        mute.saveMuted(true)
        let window = Self.window(mute: mute)
        #expect(window.footer.status == .muted)
        #expect(window.footer.hintLine == "Hold Option to speak")
    }

    // MARK: - Components stay on the tokens

    @Test("components write no hex colour, no custom focus ring, and read the G0.3 tokens")
    func componentsUseTokens() throws {
        let directory = Self.packageRoot.appendingPathComponent("App/UI/Components", isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".swift") }.sorted()
        for required in ["PageHeader.swift", "GroupBox.swift", "EmptyState.swift", "ScopedBanner.swift", "StatusTag.swift",
                         "SegmentedControl.swift", "KeyCap.swift", "SpoolCameo.swift", "SectionPage.swift"] {
            #expect(names.contains(required), "App/UI/Components/\(required) is missing")
        }
        let hex = try NSRegularExpression(pattern: "#[0-9A-Fa-f]{6}")
        for name in names {
            let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            #expect(hex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil, "\(name) writes a hex colour")
            #expect(!text.contains("focusEffectDisabled"), "\(name) suppresses the focus ring")
            #expect(!text.contains("Color(red:") && !text.contains("NSColor(red:"), "\(name) makes its own colour")
            #expect(!text.contains("ProgressView()"), "\(name) spins: loading is static text (DESIGN §6.3)")
        }
        // The banner's tint is the prototype's alpha over the attention token.
        #expect(abs(ScopedBannerStyle.fillOpacity - 16.0 / 255) < 0.0001)
        #expect(abs(ScopedBannerStyle.outlineOpacity - 85.0 / 255) < 0.0001)
        #expect(SpoolCameo.Size.emptyState.width == 88 && SpoolCameo.Size.note.width == 53)
        #expect(SpoolCameo.Size.standard.height == 66, "152 : 132 cameo aspect")
        #expect(KeyCap.accessibilityLabel(for: "fn / 🌐") == "fn / 🌐 key")
        #expect(StatusTag.Kind.good.systemImage != nil && StatusTag.Kind.warn.systemImage != nil)
    }
}
