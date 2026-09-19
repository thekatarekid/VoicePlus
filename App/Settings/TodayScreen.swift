import SwiftUI

// S7b — Today's `SectionScreen` (build doc S7b; design §8.1). The shell builds `TodayScreen(context:)`
// and nothing else for this section. It shows either the Today page (`TodaySectionView`) or, when a
// row was opened, the turn detail (`TurnDetailView`) — Today stays selected in the sidebar for both,
// as in the prototype — and presents the recovery sheet over either. Closing the sheet keeps the draft.
//
// It keeps the shell's toolbar search (`context.navigation.searchQuery`) and the section's query in
// step, and reloads when the turn store changes so an open Today follows new turns.
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
        Group {
            if let detail = today.detail {
                TurnDetailView(model: detail, hotkey: context.hotkey, back: { today.closeTurn() })
            } else {
                TodaySectionView(model: today, hotkey: context.hotkey, open: { context.open($0) })
            }
        }
        .sheet(item: $today.recovery, onDismiss: { today.refreshHeld() }) { sheet in
            RecoverySheetView(model: sheet, close: { today.closeRecovery() })
        }
        .task { await today.reloadHistory() }
        .onReceive(NotificationCenter.default.publisher(for: today.services.turnsDidChange)) { _ in
            today.turnsChanged()
        }
        .onChange(of: navigation.searchQuery) { _, query in
            guard today.search != query else { return }
            Task { await today.searchChanged(query) }
        }
        .onChange(of: today.search) { _, query in
            if navigation.searchQuery != query { navigation.searchQuery = query }
        }
    }
}
