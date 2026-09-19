import AppKit
import SwiftUI
import UniformTypeIdentifiers

// S7d — Dictionary & Apps (design §8.3; prototype `case 'dictionary'`): the page header ("Dictionary
// & Apps" / "Your spellings. Your way of writing." with the pane's primary action), the Dictionary /
// Apps segmented control bound to `window.dictionaryPane` (which deep links set), and the pane,
// drawn in `SectionPage`. The page itself is always content: each pane renders its own one base
// state below the control, so an empty Dictionary never hides the way to Apps.
//
// The toolbar search (⌘F) and the pane's "Search your words" field are one query
// (`navigation.searchQuery`), kept per section by the shell.
struct DictionaryAppsScreen: SectionScreen {
    static let section: MainWindowSection = .dictionary

    let context: SectionContext
    @ObservedObject private var model: DictionaryAppsSectionViewModel
    @ObservedObject private var window: MainWindowViewModel
    @ObservedObject private var navigation: SectionNavigation
    @State private var addingApp = false
    @State private var importingFile = false

    init(context: SectionContext) {
        self.context = context
        _model = ObservedObject(wrappedValue: context.window.dictionaryApps)
        _window = ObservedObject(wrappedValue: context.window)
        _navigation = ObservedObject(wrappedValue: context.navigation)
    }

    var body: some View {
        SectionPage(context.page, state: .content, banner: model.banner, headerAction: headerAction,
                    onBannerAction: bannerAction, hotkey: context.hotkey) {
            VStack(alignment: .leading, spacing: MainWindowLayout.sectionGap) {
                SegmentedControl("Dictionary or Apps", selection: $window.dictionaryPane,
                                 identifier: "dictionaryApps.pane") { $0.title }
                    .frame(maxWidth: 260, alignment: .leading)
                switch window.dictionaryPane {
                case .dictionary:
                    DictionaryPaneView(model: model, navigation: navigation) { importingFile = true }
                case .apps:
                    AppsPaneView(model: model, navigation: navigation) { addingApp = true }
                }
            }
        }
        .task { model.connect(database: context.window.deps.database) }
        .sheet(item: $model.editor) { _ in DictionaryTermEditorSheet(model: model) }
        .sheet(item: $model.importSession) { _ in DictionaryImportSheet(model: model, contacts: contactsOffer) }
        .sheet(isPresented: $addingApp) {
            AddAppSheet(model: model) { navigation.selectionID = $0 }
        }
        .fileImporter(isPresented: $importingFile,
                      allowedContentTypes: [.plainText, .commaSeparatedText, .tabSeparatedText]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                model.beginFileImport(text: text, fileName: url.lastPathComponent)
            } else {
                model.fileImportFailed(fileName: url.lastPathComponent)
            }
        }
    }

    /// The pane's primary action (prototype: "Add a word" on the page title).
    private var headerAction: PageAction {
        switch window.dictionaryPane {
        case .dictionary:
            return PageAction(DictionaryAppsCopy.addWord, isEnabled: model.dictionaryState.rendering != .loading
                              && model.dictionaryState.rendering != .error,
                              identifier: "dictionary.add") { model.beginAdd() }
        case .apps:
            return PageAction(DictionaryAppsCopy.addApp, isEnabled: model.appsState.rendering != .loading
                              && model.appsState.rendering != .error,
                              identifier: "apps.add") { addingApp = true }
        }
    }

    private func bannerAction() {
        if model.bannerAction == .openContactsSettings { NSWorkspace.shared.open(ContactsImportCopy.settingsURL) }
        model.clearBanner()
    }

    private var contactsOffer: ContactsImportOffer {
        ContactsImportOffer(store: context.window.deps.contacts, database: context.window.deps.database,
                            settings: context.window.deps.settingsStore)
    }
}
