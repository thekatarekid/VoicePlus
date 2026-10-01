import AppKit
import Engine
import Lab
import Pipeline
import Shared
import SwiftUI

// R7.1 / R7.2 / S7a — the one window. There is exactly one `NSWindow` in this file and none anywhere
// else in the app except onboarding (`DESIGN.md` §5.1, §12.5): the Settings window, the Lab window,
// the Data Panel window and the enrollment window are all gone, and the entry points that used to
// open them now open a route here (`WindowRoute`: section + Settings subpage / pane / disclosure).
//
// The window opens at the design's preferred 1080 × 720 pt, never smaller than 820 × 560 pt
// (`MainWindowLayout`), remembers its frame (`setFrameAutosaveName`), its section and its Settings
// subpage, as §5.1 requires, and it is a normal resizable window — not a panel, not a sheet.

@MainActor
public enum MainWindowController {
    private static var window: NSWindow?
    private static var model: MainWindowViewModel?

    /// Everything the window needs that `OnboardingDependencies` does not carry. Set by the
    /// composition root; the legacy entry points below fill in what they were handed.
    public static var environment = MainWindowEnvironment()

    /// Set once by `AppDelegate` so any entry point — including the ones that only know about the
    /// Lab or the Data Panel — can build the window.
    public static var dependencies: OnboardingDependencies?

    // The statics the old `SettingsWindowController` owned, unchanged in meaning so the composition
    // root's wiring keeps working verbatim.
    public static var connectorHub: ConnectorHub?
    public static var syncService: SyncService?
    /// P6.2 — records ~2 s of audio for `word` and returns the one-time remember-toast text.
    public static var trainByVoice: ((String) async -> String?)?
    /// R4.3 — the live adaptation loop + training-pair store behind "learned automatically".
    public static var adaptationLoop: AdaptationLoop?
    public static var trainingPairStore: TrainingPairStore?
    /// The Sparkle-shaped updater, for Settings › Updates.
    public static var updater: UpdaterProtocol?

    public static let frameAutosaveName = "VoicePlusMainWindow"

    public static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev build"
    }

    /// The refinement picker's view model. Built from the same store the old Voice tab used, so the
    /// saved mode survives R7.2 untouched.
    public static func refinementViewModel() -> VoiceSettingsViewModel {
        guard let dependencies else {
            return VoiceSettingsViewModel(store: nil, readiness: RefinementReadiness(flagEnabled: false, systemReason: nil, weightsPresent: false))
        }
        return VoiceSettingsViewModel(store: dependencies.settingsStore, flags: dependencies.flags)
    }

    // MARK: Show

    /// Opens the window at a section (the menu, onboarding, the Lab shims). Same as `show(route:)`
    /// with the section alone.
    @discardableResult
    public static func show(dependencies deps: OnboardingDependencies? = nil,
                            section: MainWindowSection? = nil,
                            connectedProviders: [String]? = nil) -> Bool {
        show(dependencies: deps, route: section.map { WindowRoute($0) }, connectedProviders: connectedProviders)
    }

    /// Opens the window at a full address — "Settings › Models", "Privacy › Diagnostics". `nil` opens
    /// it where it was left (the remembered section and subpage).
    @discardableResult
    public static func show(dependencies deps: OnboardingDependencies? = nil,
                            route: WindowRoute?,
                            connectedProviders: [String]? = nil) -> Bool {
        if let deps { dependencies = deps }
        if let connectedProviders { environment.connectedProviders = connectedProviders }
        guard let resolved = dependencies else {
            Log.app.error("main window asked to open before its dependencies were wired")
            return false
        }
        let model = self.model ?? make(deps: resolved)
        self.model = model
        if let route { model.open(route) } else { Task { await model.load(model.selection) } }
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return true
        }
        let host = NSHostingController(rootView: MainWindowView(model: model))
        let w = NSWindow(contentViewController: host)
        w.title = model.title
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.isReleasedWhenClosed = false
        w.setContentSize(MainWindowLayout.preferredSize)
        w.contentMinSize = MainWindowLayout.minimumSize
        // A remembered frame wins over the preferred size; a first open is centred at 1080 × 720.
        if !w.setFrameUsingName(frameAutosaveName) { w.center() }
        w.setFrameAutosaveName(frameAutosaveName)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
        return true
    }

    /// Every section's view model, built once. Nothing here needs AppKit, which is why the whole
    /// window is testable.
    private static func make(deps: OnboardingDependencies) -> MainWindowViewModel {
        let audio = AudioInputSettingsViewModel()
        // R8.1/R8.2 — ambient capture has its own switch (`ambient.capture.enabled`), not the
        // `directedSpeech` flag this used to read; and the Timeline's store is built here when the
        // composition root has not installed one, because that is also what enforces the seven-day
        // retention (`AmbientWiring.store` sweeps on the way out). Building it writes nothing: the
        // ambient directory is not created until an entry is actually captured.
        let timeline = environment.timeline
            ?? AmbientWiring.store(database: deps.database, settings: deps.settingsStore)
        let today = TodaySectionViewModel(deps: deps, audio: audio,
                                          reader: timeline,
                                          ambientCaptureOn: { AmbientCaptureSettings.isEnabled(deps.settingsStore) },
                                          heldProvider: environment.heldItems,
                                          heldAction: environment.heldAction)
        let meetings = MeetingsSectionViewModel(settings: deps.settingsStore,
                                                setCaptureEnabled: environment.setMeetingCapture,
                                                notesProvider: MeetingIntelligence.shared.notesProvider(),   // V5 M17
                                                askRoute: { MeetingIntelligence.shared.askRoute() })          // V5 M16/M21
        let snippetStore: any SnippetStoring = deps.database.map { DatabaseSnippetStore(database: $0) as any SnippetStoring } ?? InMemorySnippetStore()
        let dictionaryApps = DictionaryAppsSectionViewModel(
            dictionary: DictionaryViewModel(database: deps.database),
            learned: LearnedDictionaryViewModel(loop: adaptationLoop, store: trainingPairStore),
            personas: PersonasViewModel(database: deps.database),
            snippets: SnippetsViewModel(store: snippetStore))
        let voice = VoiceSectionViewModel(audio: audio,
                                          permissions: deps.permissions,
                                          lab: LabPanelViewModel(registry: environment.labRegistry, database: deps.database),
                                          makeEnrollment: environment.makeEnrollment)
        let privacy = PrivacySectionViewModel(settings: deps.settingsStore, flags: deps.flags,
                                              gate: environment.egressGate, audio: audio,
                                              database: deps.database)
        return MainWindowViewModel(
            deps: deps,
            today: today,
            meetings: meetings,
            dictionaryApps: dictionaryApps,
            voice: voice,
            privacy: privacy,
            general: GeneralSettingsViewModel(store: deps.settingsStore),
            models: ModelsSettingsViewModel(store: deps.settingsStore, models: deps.models,
                                            connectedProviders: environment.connectedProviders, flags: deps.flags),
            flags: FlagsViewModel(service: deps.flags),
            connectors: ConnectorsSettingsViewModel(hub: connectorHub),
            sync: SyncSettingsViewModel(service: syncService),
            corrections: CorrectionSettingsViewModel(store: deps.settingsStore),
            settingsSection: SettingsSectionViewModel(connectedProviders: { environment.connectedProviders }),
            notes: NotesSectionViewModel(store: environment.notesStore
                                            ?? NotesStore(database: deps.database, settings: deps.settingsStore),
                                         settings: deps.settingsStore,
                                         insertText: environment.insertNote))
    }

    /// Enrollment, folded into Voice (R7.2). The composition root still builds the recorder-backed
    /// view model; it is adopted by the Voice section instead of getting a window of its own.
    public static func showEnrollment(model enrollment: SpeakerEnrollmentViewModel) {
        guard show(section: .voice), let model else { return }
        model.voice.install(enrollment: enrollment)
    }

    /// Ends an inline enrollment, if one is running.
    public static func cancelEnrollment() { model?.voice.cancelEnrollment() }

    public static func close() {
        window?.close()
        window = nil
        model = nil
    }

    /// For tests: the section the window would open at, without opening anything.
    public static var selectedSection: MainWindowSection? { model?.selection }

    /// For tests: the full address the window is showing.
    public static var currentRoute: WindowRoute? { model?.currentRoute }

    /// True while an `NSWindow` exists. Used by the "no standalone windows" assertions.
    public static var isOpen: Bool { window != nil }
}

/// The old entry point, kept so `AppDelegate` and `AppContainer` need no change: opening "Settings"
/// now selects a section of the one window. `SettingsTab` survives only as the deep-link vocabulary
/// those callers already speak (`LegacySettingsTab`); the nine-tab `TabView` it used to index is gone.
public typealias SettingsTab = LegacySettingsTab

@MainActor
public enum SettingsWindowController {
    public static var connectorHub: ConnectorHub? {
        get { MainWindowController.connectorHub }
        set { MainWindowController.connectorHub = newValue }
    }
    public static var syncService: SyncService? {
        get { MainWindowController.syncService }
        set { MainWindowController.syncService = newValue }
    }
    public static var trainByVoice: ((String) async -> String?)? {
        get { MainWindowController.trainByVoice }
        set { MainWindowController.trainByVoice = newValue }
    }
    public static var adaptationLoop: AdaptationLoop? {
        get { MainWindowController.adaptationLoop }
        set { MainWindowController.adaptationLoop = newValue }
    }
    public static var trainingPairStore: TrainingPairStore? {
        get { MainWindowController.trainingPairStore }
        set { MainWindowController.trainingPairStore = newValue }
    }

    /// A legacy tab opens its re-homed address (`LegacySettingsTab.route`): `.models` → Settings ›
    /// Models, `.flags` → Privacy › Diagnostics, `.benchmark` → Voice › benchmarks, and so on.
    public static func show(dependencies: OnboardingDependencies, tab: SettingsTab = .general, connectedProviders: [String] = []) {
        MainWindowController.show(dependencies: dependencies,
                                  route: tab.route,
                                  connectedProviders: connectedProviders)
    }

    public static func close() { MainWindowController.close() }
}
