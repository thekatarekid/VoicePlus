import SwiftUI

// S7a entry point — owned by S7b from here on (build doc §3: `App/Settings/Today*.swift`).
//
// The shell builds `TodayScreen(context:)` and nothing else for this section, so S7b replaces this
// body with the design's Today (design §8.1: held text first, then recent dictations; turn detail and
// the recovery sheet) drawn in `SectionPage` with `App/UI/Components/`, without touching the shell.
// Until then it hosts the R7 Today pane unchanged and keeps the pane's own query and the shell's
// toolbar search (`context.navigation.searchQuery`) in step.
struct TodayScreen: SectionScreen {
    static let section: MainWindowSection = .today

    let context: SectionContext
    @ObservedObject private var today: TodaySectionViewModel
    @ObservedObject private var navigation: SectionNavigation

    init(context: SectionContext) {
        self.context = context
        _today = ObservedObject(wrappedValue: context.window.today)
        _navigation = ObservedObject(wrappedValue: context.navigation)
    }

    var body: some View {
        TodaySectionView(model: today, open: { context.open($0) })
            .onChange(of: navigation.searchQuery) { _, query in
                guard today.search != query else { return }
                today.search = query
                Task { await today.reloadTimeline() }
            }
            .onChange(of: today.search) { _, query in
                if navigation.searchQuery != query { navigation.searchQuery = query }
            }
    }
}
