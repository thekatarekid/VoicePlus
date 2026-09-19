import SwiftUI

// S7a entry point — owned by S7g from here on (the Settings section's screen; S7g owns
// `SettingsView.swift`, `SettingsViewModels.swift` and the subpages).
//
// The shell draws Settings' subnav (exactly General, Shortcuts, Appearance, Models, Providers, Sync,
// Updates — `SettingsSubpage`) and builds `SettingsScreen(context:)` under it; the selected subpage is
// `context.window.settingsSubpage`, which deep links and `⌘,` set. S7g replaces this body with one
// page per subpage (design §8.6, plus the V4 rows the owner added) drawn in `SectionPage` with
// `App/UI/Components/`, splitting the R7 form by `LegacySettingsItem.subpage`, without touching the
// shell. Until then: Providers and Sync show their own panes, and every other subpage shows the whole
// R7 Settings form under its own page header, so no setting is ever out of reach.
struct SettingsScreen: SectionScreen {
    static let section: MainWindowSection = .settings

    let context: SectionContext
    @ObservedObject private var window: MainWindowViewModel

    init(context: SectionContext) {
        self.context = context
        _window = ObservedObject(wrappedValue: context.window)
    }

    var body: some View {
        let page = PageCopy.settings(window.settingsSubpage)
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(page)
                .padding(.horizontal, MainWindowLayout.outerPadding)
                .padding(.top, Tokens.Spacing.l)
            switch window.settingsSubpage {
            case .providers: ConnectorsSettingsTab(model: window.connectors)
            case .sync: SyncSettingsTab(model: window.sync)
            case .general, .shortcuts, .appearance, .models, .updates: SettingsView(model: window)
            }
        }
    }
}
