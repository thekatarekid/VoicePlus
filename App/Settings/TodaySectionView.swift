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

    @ViewBuilder private var timeline: some View {
        GroupBox("Timeline") {
            VStack(alignment: .leading, spacing: 8) {
                if let banner = model.banner { SectionBannerView(banner: banner) }
                if model.timeline.isContent {
                    TextField("Search", text: $model.search)
                        .accessibilityIdentifier("today.timeline.search")
                        .onSubmit { Task { await model.reloadTimeline() } }
                    ForEach(model.timelineRows) { row in
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.time, style: .time).font(.caption.monospacedDigit()).frame(width: 70, alignment: .leading)
                            Text(row.source).font(.caption).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                            Text(row.text).font(.caption.monospaced())
                            Spacer()
                            Button(role: .destructive) { model.delete(rowID: row.id) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                        }
                        .accessibilityIdentifier("today.timeline.row")
                    }
                    Button("Delete all", role: .destructive) { model.deleteAllTimeline() }
                        .accessibilityIdentifier("today.timeline.deleteAll")
                } else {
                    SectionStateView(state: model.timeline) { open(.privacy) }
                }
            }
            .padding(4)
        }
    }
}
