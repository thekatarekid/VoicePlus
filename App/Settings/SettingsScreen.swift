import SwiftUI

// S7a entry point, owned by S7g (design §8.6, `DESIGN.md` §9.6).
//
// The shell draws Settings' subnav (exactly General, Shortcuts, Appearance, Models, Providers, Sync,
// Updates — `SettingsSubpage`) and builds `SettingsScreen(context:)` under it; the selected subpage is
// `context.window.settingsSubpage`, which deep links and `⌘,` set. Each subpage is one page drawn in
// `SectionPage` (`SettingsView.swift`). The page models the shell does not build — Models, Shortcuts,
// provider credentials, Updates — live here, built once from the window's dependencies, so the shell
// needs no new field.
//
// Larger Text applies here, to the Settings pages. The window root (sidebar and the other sections)
// takes the same `AppearanceSettings.textSize(store).scale` through `windowTextScale` — one line in
// `MainWindowView`, which S7g does not own (hand-off, see the S7g report).
struct SettingsScreen: SectionScreen {
    static let section: MainWindowSection = .settings

    let context: SectionContext
    @ObservedObject private var window: MainWindowViewModel
    @ObservedObject private var general: GeneralSettingsViewModel
    @StateObject private var shortcuts: ShortcutsPageModel
    @StateObject private var models: ModelsPageModel
    @StateObject private var credentials: ProviderCredentialsModel
    @StateObject private var updates: UpdatesPageModel
    @StateObject private var computerUse: ComputerUseSettingsModel   // V5 CU1

    init(context: SectionContext) {
        self.init(context: context, credentials: ProviderCredentialsModel(), inventory: LiveModelInventory())
    }

    /// The same screen over a given credential store and disk reader — how tests render it without
    /// reading this Mac's Keychain or models folder. Both are built once, when the screen is.
    init(context: SectionContext, credentials: @autoclosure @escaping () -> ProviderCredentialsModel,
         inventory: ModelInventoryReading) {
        self.context = context
        let window = context.window
        _window = ObservedObject(wrappedValue: window)
        _general = ObservedObject(wrappedValue: window.general)
        _shortcuts = StateObject(wrappedValue: ShortcutsPageModel(general: window.general))
        _models = StateObject(wrappedValue: ModelsPageModel(models: window.deps.models, inventory: inventory,
                                                            store: window.deps.settingsStore,
                                                            load: ModelsPageModel.loader(for: window.deps)))
        _credentials = StateObject(wrappedValue: credentials())
        _updates = StateObject(wrappedValue: UpdatesPageModel.live(deps: window.deps))
        _computerUse = StateObject(wrappedValue: ComputerUseSettingsModel(store: window.deps.settingsStore,
                                                                          general: window.general, models: window.models))
    }

    var body: some View {
        page(window.settingsSubpage)
            .environment(\.windowTextScale, general.textSize.scale)
    }

    @ViewBuilder private func page(_ subpage: SettingsSubpage) -> some View {
        let hotkey = context.hotkey
        switch subpage {
        case .general:
            GeneralSettingsPage(general: general, corrections: window.corrections,
                                hotkey: hotkey, open: { window.settingsSubpage = $0 },
                                runOnboarding: { OnboardingWindowController.show(dependencies: window.deps) })
        case .shortcuts:
            ShortcutsSettingsPage(general: general, shortcuts: shortcuts, hotkey: hotkey)
        case .appearance:
            AppearanceSettingsPage(general: general, hotkey: hotkey)
        case .models:
            ModelsSettingsPage(page: models, models: window.models,
                               refinement: RefinementReadiness.resolve(flags: window.deps.flags), hotkey: hotkey)
        case .providers:
            ProvidersSettingsPage(credentials: credentials, connectors: window.connectors, models: window.models,
                                  hotkey: hotkey)
        case .computerUse:
            ComputerUseSettingsPage(model: computerUse, general: general, hotkey: hotkey)
        case .sync:
            SyncSettingsPage(sync: window.sync, database: window.deps.database, hotkey: hotkey)
        case .updates:
            UpdatesSettingsPage(updates: updates, hotkey: hotkey)
        }
    }
}
