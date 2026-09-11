import AppKit
import Engine
import Pipeline
import SwiftUI

/// Public entry point wired by P1.1 / P1.12. `show(tab:)` deep-links (e.g. Providers → `.models`).
@MainActor
public enum SettingsWindowController {
    private static var window: NSWindow?
    private static var tabModel: TabSelection?
    /// P4.6 — set by the composition root so the "Connected services" tab can drive OAuth.
    public static var connectorHub: ConnectorHub?
    /// P6.4 — sync service for the Sync tab.
    public static var syncService: SyncService?
    /// P6.2 — records ~2 s of audio for `word` and returns the one-time remember-toast text.
    public static var trainByVoice: ((String) async -> String?)?
    /// R4.3 — the live adaptation loop + training-pair store backing the Dictionary tab's
    /// "learned automatically" list and its Forget action; set by the composition root
    /// (`AppDelegate`) from `AppContainer.adaptation`. Nil (e.g. in previews) renders the empty
    /// list rather than crashing.
    public static var adaptationLoop: AdaptationLoop?
    public static var trainingPairStore: TrainingPairStore?

    final class TabSelection: ObservableObject { @Published var tab: SettingsTab = .general }

    private struct Root: View {
        @ObservedObject var selection: TabSelection
        let deps: OnboardingDependencies
        let connectedProviders: [String]
        var body: some View {
            SettingsView(
                general: GeneralSettingsViewModel(store: deps.settingsStore),
                models: ModelsSettingsViewModel(store: deps.settingsStore, models: deps.models,
                                                connectedProviders: connectedProviders, flags: deps.flags),
                personas: PersonasViewModel(database: deps.database),
                dictionary: DictionaryViewModel(database: deps.database),
                learnedDictionary: LearnedDictionaryViewModel(loop: SettingsWindowController.adaptationLoop, store: SettingsWindowController.trainingPairStore),
                benchmark: BenchmarkViewModel(report: BenchmarkViewModel.lastMeasured),
                flags: FlagsViewModel(service: deps.flags),
                data: DataPanelViewModel(database: deps.database),
                snippets: SnippetsViewModel(store: deps.database.map { DatabaseSnippetStore(database: $0) as any SnippetStoring } ?? InMemorySnippetStore()),
                corrections: CorrectionSettingsViewModel(store: deps.settingsStore),
                connectors: ConnectorsSettingsViewModel(hub: SettingsWindowController.connectorHub),
                sync: SyncSettingsViewModel(service: SettingsWindowController.syncService),
                deps: deps,
                selectedTab: $selection.tab
            )
        }
    }

    public static func show(dependencies: OnboardingDependencies, tab: SettingsTab = .general, connectedProviders: [String] = []) {
        if let window, let tabModel {
            tabModel.tab = tab
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let selection = TabSelection()
        selection.tab = tab
        let host = NSHostingController(rootView: Root(selection: selection, deps: dependencies, connectedProviders: connectedProviders))
        let w = NSWindow(contentViewController: host)
        w.title = "VoicePlus Settings"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
        tabModel = selection
    }

    public static func close() { window?.close(); window = nil; tabModel = nil }
}
