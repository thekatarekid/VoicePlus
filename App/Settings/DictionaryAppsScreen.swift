import SwiftUI

// S7a entry point — owned by S7d from here on (build doc §3: `App/Settings/DictionaryApps*.swift`).
//
// The shell builds `DictionaryAppsScreen(context:)` and nothing else for this section, so S7d
// replaces this body with the design's Dictionary & Apps (design §8.3) — its Dictionary / Apps
// `SegmentedControl` bound to `context.window.dictionaryPane`, which deep links set — drawn in
// `SectionPage` with `App/UI/Components/`, without touching the shell. Until then it hosts the R7
// pane unchanged and keeps the dictionary filter and the shell's toolbar search in step.
struct DictionaryAppsScreen: SectionScreen {
    static let section: MainWindowSection = .dictionary

    let context: SectionContext
    @ObservedObject private var dictionary: DictionaryViewModel
    @ObservedObject private var navigation: SectionNavigation

    init(context: SectionContext) {
        self.context = context
        _dictionary = ObservedObject(wrappedValue: context.window.dictionaryApps.dictionary)
        _navigation = ObservedObject(wrappedValue: context.navigation)
    }

    var body: some View {
        DictionaryAppsSectionView(model: context.window.dictionaryApps, deps: context.window.deps)
            .onChange(of: navigation.searchQuery) { _, query in
                if dictionary.filter != query { dictionary.filter = query }
            }
            .onChange(of: dictionary.filter) { _, query in
                if navigation.searchQuery != query { navigation.searchQuery = query }
            }
    }
}
