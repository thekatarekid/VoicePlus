import SwiftUI
import Shared

// R7.1 — Today / Timeline's detail pane (`DESIGN.md` §9.1). Readiness first, then Needs you, then
// the Timeline. The readiness strip is outside the scaffold's state switch on purpose: §9.1 says it
// "renders immediately from cached state (it is never blank)", so a loading or broken Timeline must
// not take it off screen.

struct TodaySectionView: View {
    @ObservedObject var model: TodaySectionViewModel
    /// Jumping to another section — the Timeline's empty and error states both point at Privacy.
    var open: (MainWindowSection) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(MainWindowSection.today.detailTitle).font(.title2.weight(.semibold))
                    Text(MainWindowSection.today.subtitle).font(.callout).foregroundStyle(.secondary)
                }
                readiness
                needsYou
                timeline
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var readiness: some View {
        GroupBox("Ready to dictate") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.readiness) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Label(row.label, systemImage: row.glyph)
                            .labelStyle(.titleAndIcon)
                            .frame(width: 160, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.word).font(.body.weight(.medium))
                                .foregroundStyle(row.isReady ? AnyShapeStyle(.primary) : AnyShapeStyle(.orange))
                            Text(row.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let action = row.actionTitle {
                            Button(action) { open(.settings) }
                        }
                    }
                    .accessibilityIdentifier("today.readiness.\(row.id)")
                }
            }
            .padding(4)
        }
    }

    @ViewBuilder private var needsYou: some View {
        GroupBox("Needs you") {
            if model.held.isEmpty {
                SectionStateView(state: model.heldState)
                    .padding(4)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.held) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(HeldPillInfo(item: item).headline).font(.body.weight(.medium))
                            Text(HeldPillInfo.excerpt(of: item.text)).font(.caption.monospaced()).foregroundStyle(.secondary)
                            HStack {
                                ForEach(HeldAction.allCases, id: \.self) { action in
                                    Button(action.label) { model.perform(action, on: item) }
                                        .accessibilityIdentifier("today.held.\(action.rawValue)")
                                }
                            }
                            if let error = model.heldRowErrors[item.id] {
                                Text(error).font(.caption).foregroundStyle(.orange)
                                    .accessibilityIdentifier("today.held.rowError")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(4)
            }
        }
    }

    /// The Timeline (`AmbientTimeline`). The search field and the filter row stay on screen in every
    /// rendering: an empty caused by a search or a filter can only be undone from the control that
    /// caused it, so hiding the control with the rows would trap the user in the empty.
    @ViewBuilder private var timeline: some View {
        GroupBox("Timeline") {
            VStack(alignment: .leading, spacing: 8) {
                if let banner = model.banner { SectionBannerView(banner: banner) }
                searchField
                sourceFilters
                if model.timeline.isContent {
                    ForEach(model.timelineDays) { day in
                        Text(day.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .accessibilityIdentifier("today.timeline.day")
                        ForEach(day.rows) { row in timelineRow(row) }
                    }
                    HStack {
                        Spacer()
                        Button(SectionCopy.deleteAllTimeline, role: .destructive) { model.askToDeleteEverything() }
                            .accessibilityIdentifier("today.timeline.deleteAll")
                    }
                } else {
                    SectionStateView(state: model.timeline) { timelineAction() }
                }
                Text(model.timelinePrivacyNote).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("today.timeline.privacy")
            }
            .padding(4)
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
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            TextField("Search", text: $model.search)
                .accessibilityIdentifier("today.timeline.search")
                .onSubmit { Task { await model.reloadTimeline() } }
            if !model.search.isEmpty {
                Button(SectionCopy.clearSearch) { Task { await model.clearSearch() } }
                    .accessibilityIdentifier("today.timeline.clearSearch")
            }
        }
    }

    @ViewBuilder private var sourceFilters: some View {
        if !model.availableSources.isEmpty {
            HStack(spacing: 8) {
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
            Text(row.time, style: .time).font(.caption.monospacedDigit()).frame(width: 70, alignment: .leading)
            Text(TimelineSource.named(row.source).label).font(.caption).foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(row.text).font(.caption.monospaced())
            Spacer()
            if model.deletingRows.contains(row.id) {
                Text(SectionCopy.timelineDeleting).font(.caption).foregroundStyle(.secondary)
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
        case SectionCopy.clearSearch: Task { await model.clearSearch() }
        case SectionCopy.showEverySource: Task { await model.showEverySource() }
        case SectionCopy.tryAgain: Task { await model.reloadTimeline() }
        default: open(.privacy)
        }
    }
}
