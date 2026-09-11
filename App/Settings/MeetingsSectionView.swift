import AppKit
import Engine
import SwiftUI
import Shared

// R7.1 — Meetings (`DESIGN.md` §9.2). The capture switch and the Calendar state sit at the top, above
// whichever of the four renderings the list is in, because they are what the empty states are *about*.

struct MeetingsSectionView: View {
    @ObservedObject var model: MeetingsSectionViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(MainWindowSection.meetings.detailTitle).font(.title2.weight(.semibold))
                Text(MainWindowSection.meetings.subtitle).font(.callout).foregroundStyle(.secondary)
            }
            controls
            if let banner = model.banner { SectionBannerView(banner: banner) }
            if model.state.isContent {
                list
            } else {
                SectionStateView(state: model.state) {
                    if !model.isCaptureEnabled {
                        model.isCaptureEnabled = true
                    } else {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var controls: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Capture meetings", isOn: Binding(
                    get: { model.isCaptureEnabled },
                    set: { model.isCaptureEnabled = $0 }
                ))
                .accessibilityIdentifier("meetings.captureEnabled")
                Text("Off by default. Nothing about meetings runs — no Calendar, no Reminders, no notification request — until this is on.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Label(model.isCalendarAuthorized ? "Calendar access is on" : SectionCopy.calendarOff,
                          systemImage: model.isCalendarAuthorized ? "calendar" : "calendar.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(model.isCalendarAuthorized ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                    if !model.isCalendarAuthorized {
                        Button(SectionCopy.openSystemSettings) {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                        }
                        .font(.caption)
                    }
                }
                .accessibilityIdentifier("meetings.calendarState")
            }
            .padding(4)
        }
    }

    private var list: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Search", text: $model.search).accessibilityIdentifier("meetings.search")
                List(model.filtered, selection: Binding(
                    get: { model.selected?.id },
                    set: { id in model.select(model.meetings.first { $0.id == id }) }
                )) { record in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(record.title)
                        Text("\(record.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(duration(record))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(record.id)
                    .contextMenu { Button("Delete", role: .destructive) { model.delete(id: record.id) } }
                }
                .frame(minWidth: 220)
                ForEach(model.unreadableIDs, id: \.self) { id in
                    HStack {
                        Label(SectionCopy.meetingUnreadableRow, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                        Spacer()
                        Button("Delete", role: .destructive) { model.delete(id: id) }.font(.caption)
                    }
                    .accessibilityIdentifier("meetings.unreadableRow")
                }
            }
            Divider()
            transcript
        }
    }

    @ViewBuilder private var transcript: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let record = model.selected {
                if model.transcript.isContent {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(record.transcript.utterances.enumerated()), id: \.offset) { _, utterance in
                                Text("\(utterance.speaker.label): \(utterance.text)")
                                    .font(.caption.monospaced())
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    HStack {
                        Button("Copy") { Pasteboard.copy(model.markdown(for: record)) }
                        Button("Export…") { export(record) }
                        Button("Delete", role: .destructive) { model.delete(id: record.id) }
                    }
                } else {
                    SectionStateView(state: model.transcript)
                }
            } else {
                Text("Pick a meeting to read its transcript.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func duration(_ record: MeetingRecord) -> String {
        guard let ended = record.endedAt else { return "still going" }
        let minutes = Int(ended.timeIntervalSince(record.startedAt) / 60)
        return "\(minutes) min"
    }

    private func export(_ record: MeetingRecord) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(record.title).md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? model.markdown(for: record).data(using: .utf8)?.write(to: url, options: .atomic)
    }
}
