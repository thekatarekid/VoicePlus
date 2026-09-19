import SwiftUI

// S7a entry point — owned by S7c from here on (build doc §3: `App/Settings/Meetings*.swift`).
//
// The shell builds `MeetingsScreen(context:)` and nothing else for this section, so S7c replaces this
// body with the design's Meetings library / detail (design §8.2) drawn in `SectionPage` with
// `App/UI/Components/`, without touching the shell. Until then it hosts the R7 Meetings pane
// unchanged and keeps the pane's own query and the shell's toolbar search in step.
struct MeetingsScreen: SectionScreen {
    static let section: MainWindowSection = .meetings

    let context: SectionContext
    @ObservedObject private var meetings: MeetingsSectionViewModel
    @ObservedObject private var navigation: SectionNavigation

    init(context: SectionContext) {
        self.context = context
        _meetings = ObservedObject(wrappedValue: context.window.meetings)
        _navigation = ObservedObject(wrappedValue: context.navigation)
    }

    var body: some View {
        MeetingsSectionView(model: meetings)
            .onChange(of: navigation.searchQuery) { _, query in
                if meetings.search != query { meetings.search = query }
            }
            .onChange(of: meetings.search) { _, query in
                if navigation.searchQuery != query { navigation.searchQuery = query }
            }
    }
}
