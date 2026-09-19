import SwiftUI

// S7c — the Meetings section's entry point (build doc §3: `App/Settings/Meetings*.swift`). The shell
// builds `MeetingsScreen(context:)` and nothing else for this section. It draws the design's Meetings
// library and detail (design §8.2) through `MeetingsSectionView`, keeps the page's query in step with
// the shell's toolbar search, and records the open meeting in the section's preserved navigation.
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
        MeetingsSectionView(model: meetings, hotkey: context.hotkey,
                            open: { context.open($0) },
                            expandPanel: { MeetingPanelController.shared.show() })
            .onAppear { meetings.hotkey = context.hotkey }
            .onChange(of: navigation.searchQuery) { _, query in
                if meetings.search != query { meetings.search = query }
            }
            .onChange(of: meetings.search) { _, query in
                if navigation.searchQuery != query { navigation.searchQuery = query }
            }
            .onChange(of: meetings.selected?.id) { _, id in
                if navigation.selectionID != id { navigation.selectionID = id }
            }
    }
}
