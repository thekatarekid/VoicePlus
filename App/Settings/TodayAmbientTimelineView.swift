import SwiftUI
import Shared

// R8.3, re-homed by S7b — the ambient Timeline as one group of Today, below the dictations and only
// while ambient capture is on (design §8.1 keeps Today to held text, then dictations; the ambient
// transcript history stays reachable here). Same view model, same states, same delete paths as the
// R7 pane: its search is the section's toolbar search, its source filters and deletes are its own.

struct TodayAmbientTimelineView: View {
    @ObservedObject var model: TodaySectionViewModel
    var open: (WindowRoute) -> Void

    var body: some View {
        GroupBox(TodayAmbientCopy.heading) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                if let banner = model.banner { ScopedBanner(banner) }
                sourceFilters
                if model.timeline.isContent {
                    ForEach(model.timelineDays) { day in
                        Text(day.title)
                            .windowFont(Tokens.Typography.meta)
                            .foregroundStyle(WindowColor.secondaryInk)
                            .accessibilityIdentifier("today.timeline.day")
                        ForEach(day.rows) { row in timelineRow(row) }
                    }
                    HStack {
                        Spacer()
                        Button(SectionCopy.deleteAllTimeline, role: .destructive) { model.askToDeleteEverything() }
                            .accessibilityIdentifier("today.timeline.deleteAll")
                    }
                } else {
                    VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                        Text(model.timeline.headline)
                            .windowFont(Tokens.Typography.body)
                            .foregroundStyle(WindowColor.ink)
                        if let detail = model.timeline.detail {
                            Text(detail)
                                .windowFont(Tokens.Typography.meta)
                                .foregroundStyle(WindowColor.secondaryInk)
                        }
                        if let title = model.timeline.actionTitle {
                            Button(title) { timelineAction() }
                                .accessibilityIdentifier("today.timeline.action")
                        }
                    }
                    .accessibilityIdentifier("today.timeline.\(model.timeline.rendering.rawValue)")
                }
                Text(model.timelinePrivacyNote)
                    .windowFont(Tokens.Typography.meta)
                    .foregroundStyle(WindowColor.secondaryInk)
                    .accessibilityIdentifier("today.timeline.privacy")
            }
        }
        // §5.3: a sheet only for a genuine either/or. Delete-all and a row delete are both one.
        .confirmationDialog(model.confirmation?.headline ?? SectionCopy.confirmDelete,
                            isPresented: Binding(get: { model.confirmation != nil },
                                                 set: { if !$0 { model.cancelConfirmation() } }),
                            titleVisibility: .visible,
                            presenting: model.confirmation) { pending in
            Button(pending.confirmTitle, role: .destructive) { Task { await model.confirm() } }
                .accessibilityIdentifier("today.timeline.confirmDelete")
            Button(pending.cancelTitle, role: .cancel) { model.cancelConfirmation() }
        } message: { pending in
            Text(pending.detail)
        }
        .accessibilityIdentifier("today.timeline")
    }

    @ViewBuilder private var sourceFilters: some View {
        if !model.availableSources.isEmpty {
            HStack(spacing: Tokens.Spacing.s) {
                ForEach(model.availableSources) { source in
                    Toggle(source.label, isOn: Binding(get: { model.isSelected(source: source.id) },
                                                       set: { _ in Task { await model.toggle(source: source.id) } }))
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier("today.timeline.source.\(source.id)")
                }
            }
        }
    }

    private func timelineRow(_ row: TimelineRow) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(row.time, style: .time)
                .windowFont(Tokens.Typography.meta)
                .monospacedDigit()
                .frame(width: 70, alignment: .leading)
            Text(TimelineSource.named(row.source).label)
                .windowFont(Tokens.Typography.meta)
                .foregroundStyle(WindowColor.secondaryInk)
                .frame(width: 90, alignment: .leading)
            Text(row.text).windowFont(Tokens.Typography.body)
            Spacer()
            if model.deletingRows.contains(row.id) {
                Text(SectionCopy.timelineDeleting)
                    .windowFont(Tokens.Typography.meta)
                    .foregroundStyle(WindowColor.secondaryInk)
            } else {
                Button(role: .destructive) { model.askToDelete(rowID: row.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(SectionCopy.confirmDelete)
            }
        }
        .accessibilityIdentifier("today.timeline.row")
        .accessibilityElement(children: .combine)
    }

    /// The one action each Timeline state offers. Search and filter empties undo themselves; the rest
    /// point at Privacy, where ambient capture and the store live.
    private func timelineAction() {
        switch model.timeline.actionTitle {
        case SectionCopy.clearSearch: Task { await model.clearHistorySearch() }
        case SectionCopy.showEverySource: Task { await model.showEverySource() }
        case SectionCopy.tryAgain: Task { await model.reloadTimeline() }
        default: open(WindowRoute(.privacy))
        }
    }
}

enum TodayAmbientCopy {
    /// V3 §4.7: the Timeline the window shows is the ambient one.
    static let heading = "Ambient timeline"
}
