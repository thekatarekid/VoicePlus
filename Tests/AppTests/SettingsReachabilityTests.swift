import Engine
import Foundation
import Injection
import Lab
import Pipeline
import Shared
import Testing
@testable import VoicePlusApp

/// R7.2 — folding the tabbed Settings window into the one window, without losing a setting.
///
/// The old window was a `TabView` with eleven tabs (`DESIGN.md` §9.6 names nine; R5.3 added `voice`
/// and R4.3 added `benchmark` afterwards). Every one of them is enumerated in `LegacySettingsTab`,
/// every setting they held is enumerated in `SettingsReachability`, and this suite reads the new
/// window's source files to prove each setting is still rendered somewhere. That source read is
/// deliberate: this toolchain has no XCTest and no UI testing, so "can the user still get at it"
/// cannot be asserted by tapping — but it *can* be asserted against the file that draws it.
@Suite("R7.2: every old tab's settings are still reachable, and no standalone window survives")
@MainActor
struct SettingsReachabilityTests {

    /// Package root, from this file's own path (the pattern `AgentCursorTests` already uses).
    static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static func source(_ relativePath: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    static func appSettingsSources() throws -> [(name: String, text: String)] {
        let directory = root.appendingPathComponent("App/Settings", isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".swift") }
        return try names.sorted().map { (name: $0, text: try String(contentsOf: directory.appendingPathComponent($0), encoding: .utf8)) }
    }

    // MARK: - The eleven tabs

    @Test("every tab of the old TabView is enumerated, named, and has a home section")
    func everyTabHasAHome() {
        #expect(LegacySettingsTab.allCases.count == 11)
        #expect(LegacySettingsTab.allCases.map(\.rawValue) ==
                ["general", "models", "voice", "personas", "dictionary", "snippets", "flags", "connectors", "sync", "data", "benchmark"])
        for tab in LegacySettingsTab.allCases {
            #expect(!tab.title.isEmpty)
            #expect(SettingsReachability.items.contains { $0.tab == tab },
                    "tab “\(tab.title)” has no settings listed, so nothing proves it survived")
        }
        // The moves `DESIGN.md` §9.6 asks for, stated as assertions rather than as prose.
        #expect(LegacySettingsTab.data.home == .privacy)
        #expect(LegacySettingsTab.dictionary.home == .dictionary)
        #expect(LegacySettingsTab.snippets.home == .dictionary)
        #expect(LegacySettingsTab.personas.home == .dictionary)
        #expect(LegacySettingsTab.benchmark.home == .voice)
        #expect(LegacySettingsTab.voice.home == .voice)
        #expect(LegacySettingsTab.general.home == .settings)
        #expect(LegacySettingsTab.models.home == .settings)
        #expect(LegacySettingsTab.flags.home == .privacy) // S7a: re-homed to Privacy › Diagnostics (design §8.5)
        #expect(LegacySettingsTab.connectors.home == .settings)
        #expect(LegacySettingsTab.sync.home == .settings)
    }

    @Test("every setting the old tabs had is rendered in its new section's source")
    func everySettingIsReachable() throws {
        var sources: [MainWindowSection: String] = [:]
        for section in MainWindowSection.allCases {
            sources[section] = try SettingsReachability.sourceFiles(for: section)
                .map { try Self.source($0) }
                .joined(separator: "\n")
        }
        for item in SettingsReachability.allItems {
            let text = sources[item.home] ?? ""
            #expect(text.contains(item.marker),
                    "“\(item.name)” (was \(item.tab.title)) is not rendered in \(item.home.detailTitle) — marker \(item.marker) is missing")
        }
        // Not vacuous: the catalogue covers every tab and every section that should hold one.
        #expect(SettingsReachability.items.count >= 35)
        #expect(Set(SettingsReachability.allItems.map(\.home)) == Set([.settings, .voice, .privacy, .dictionary, .meetings]))
    }

    @Test("a marker is never satisfied by the wrong section's file")
    func markersAreSectionSpecific() throws {
        // The egress table belongs to Privacy, the routing pickers to Settings, the counters to Voice.
        let settings = try Self.source("App/Settings/SettingsView.swift")
        #expect(!settings.contains("privacy.egressTable"))
        #expect(!settings.contains("benchmark.row"))
        #expect(!settings.contains("dictionary.filter"))
        let privacy = try Self.source("App/Settings/PrivacySectionView.swift")
        #expect(!privacy.contains("settings.routing."))
        let voice = try Self.source("App/Settings/VoiceSectionView.swift")
        #expect(!voice.contains("settings.flag."))
    }

    @Test("the nine-tab TabView is gone from the whole Settings surface")
    func noTabViewRemains() throws {
        for file in try Self.appSettingsSources() {
            #expect(!file.text.contains("TabView("), "\(file.name) still builds a TabView — R7.2 removes it")
        }
        // And the Lab's own two-tab window is gone with it.
        #expect(!(try Self.source("App/Services/LabWiring.swift").contains("TabView(")))
    }

    @Test("one window: no other controller creates an NSWindow")
    func noStandaloneWindowsRemain() throws {
        for file in try Self.appSettingsSources() where file.name != "MainWindowController.swift" {
            #expect(!file.text.contains("NSWindow("), "\(file.name) creates a window of its own")
        }
        let controller = try Self.source("App/Settings/MainWindowController.swift")
        #expect(controller.components(separatedBy: "NSWindow(").count - 1 == 1,
                "there is exactly one NSWindow in the app outside onboarding (DESIGN §5.1, §12.5)")
        // The three windows R7.2 folds in: their controllers survive only as shims.
        let enrollment = try Self.source("App/Onboarding/SpeakerEnrollmentWindow.swift")
        #expect(!enrollment.contains("NSWindow("))
        #expect(enrollment.contains("MainWindowController.showEnrollment"))
        let lab = try Self.source("App/Services/LabWiring.swift")
        #expect(!lab.contains("NSWindow("))
        #expect(lab.contains("MainWindowController.show(section: .voice)"))
        #expect(lab.contains("MainWindowController.show(section: .privacy)"))
        // Onboarding is the one allowed exception, and it is still there.
        #expect(try Self.source("App/Onboarding/OnboardingWindowController.swift").contains("NSWindow("))
    }

    @Test("the old deep links still work: a SettingsTab selects a section")
    func deepLinksStillResolve() {
        // `AppContainer` opens Settings at `.models` for the Providers link; that must land somewhere.
        #expect(MainWindowSection.section(for: .models) == .settings)
        #expect(MainWindowSection.section(for: .general) == .settings)
        #expect(MainWindowSection.section(for: .data) == .privacy)
        #expect(MainWindowSection.section(for: .benchmark) == .voice)
        // `SettingsTab` survives only as that vocabulary.
        let tab: SettingsTab = .models
        #expect(tab == LegacySettingsTab.models)
    }

    // MARK: - Preferences survive the move (V3 §1.6)

    @Test("every moved setting is still read from the key it was written to before R7")
    func preferencesArePreserved() throws {
        // Keys the settings store owns. A build from before R7.2 wrote exactly these.
        let store = InMemorySettingsStore()
        store.set(HotkeyChoice.rightCommand.rawValue, for: HotkeyService.bindingDefaultsKey)
        store.set(HotkeyChoice.rightOption.rawValue, for: HotkeyService.actBindingDefaultsKey)
        store.set(true, for: SettingsKeys.actKeyEnabled)
        store.set(true, for: HotkeyService.forceEventTapDefaultsKey)
        store.set(false, for: SettingsKeys.presenceIndicator)
        store.set(false, for: SettingsKeys.presenceHideInFullScreen)
        store.set(RefinementMode.always.rawValue, for: RefinementSettings.modeKey)
        store.set(true, for: SettingsKeys.meetingCaptureEnabled)

        let general = GeneralSettingsViewModel(store: store)
        #expect(general.hotkey == .rightCommand, "the dictation key must survive the window rewrite")
        #expect(general.actKey == .key(.rightOption))
        #expect(general.forceEventTap)
        #expect(general.presenceIndicator == false)
        #expect(general.presenceHideInFullScreen == false)

        let refinement = VoiceSettingsViewModel(store: store, readiness: RefinementReadiness(flagEnabled: true, systemReason: nil, weightsPresent: true))
        #expect(refinement.mode == .always, "Settings › Voice moved to Voice › Second pass; its key did not move")

        let meetings = MeetingsSectionViewModel(store: MeetingStore(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("vp-meetings-\(UUID().uuidString)", isDirectory: true)),
                                                settings: store,
                                                calendarAuthorized: { true },
                                                list: { _ in (records: [], unreadable: []) })
        #expect(meetings.isCaptureEnabled, "meeting capture keeps `meeting.capture.enabled`")

        // Keys that live in UserDefaults because the engine and Injection read them there.
        let defaults = UserDefaults(suiteName: "vp.reach.\(UUID().uuidString)")!
        defaults.set(true, forKey: UtteranceRecorder.defaultsKey)
        defaults.set("com.apple.keychainaccess,com.agilebits.onepassword7", forKey: InjectionSettingsKeys.neverInject)
        defaults.set(true, forKey: EgressGate.killSwitchKey)

        let privacy = PrivacySectionViewModel(settings: store, flags: .inMemory(),
                                              gate: EgressGate(defaults: defaults),
                                              audio: AudioInputSettingsViewModel(defaults: defaults),
                                              database: nil,
                                              load: { _ in [] }, bytesToday: { _ in 0 }, deleteEverything: { 0 })
        #expect(privacy.audioRetention, "“save recordings” moved from General to Privacy; the recorder's key did not move")
        #expect(privacy.killSwitch, "the Data Panel's kill switch keeps `network.killSwitch`")

        let dictionaryApps = DictionaryAppsSectionViewModel(dictionary: DictionaryViewModel(database: nil),
                                                           learned: LearnedDictionaryViewModel(loop: nil, store: nil),
                                                           personas: PersonasViewModel(database: nil),
                                                           snippets: SnippetsViewModel(store: InMemorySnippetStore()),
                                                           defaults: defaults)
        #expect(dictionaryApps.isNeverInject("com.apple.keychainaccess"))
        #expect(dictionaryApps.isNeverInject("com.agilebits.onepassword7"))
    }

    @Test("R7 adds exactly two settings keys, and both have a safe default")
    func onlyTwoNewKeys() {
        // Nothing was renamed, so nothing needs migrating. What is new is the window's own memory and
        // the retention preference R8.2 will enforce — each with a default that holds on a fresh Mac.
        #expect(MainWindowSection.selectionKey == "window.section")
        #expect(AmbientRetentionSettings.daysKey == "ambient.retention.days")
        #expect(MainWindowSection.remembered(InMemorySettingsStore()) == .today)
        #expect(AmbientRetentionSettings.days(InMemorySettingsStore()) == 7)
        // A value from a future build (or a hand-edited one) falls back rather than throwing.
        let store = InMemorySettingsStore()
        store.set("400", for: AmbientRetentionSettings.daysKey)
        #expect(AmbientRetentionSettings.days(store) == 7)
        store.set("30", for: AmbientRetentionSettings.daysKey)
        #expect(AmbientRetentionSettings.days(store) == 30)
    }

    @Test("no web view anywhere in the window (V3 §9.2, DESIGN §12.1)")
    func noWebViews() throws {
        for file in try Self.appSettingsSources() {
            for banned in ["WKWebView", "SFSafariViewController", "import WebKit"] {
                #expect(!file.text.contains(banned), "\(file.name) contains \(banned)")
            }
        }
    }
}
