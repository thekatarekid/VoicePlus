import AppKit
import Engine
import Shared
import SwiftUI

// S7c — the Meetings page (design §8.2; prototype `meetings`): "Meetings · Thoughts worth coming back
// to." with Start recording, the unfinished-recording banner above the list it affects, the library
// rows (Today · 24 min · Notes ready · [Open]), and the Calendar footnote. One meeting opens its detail
// in place (`MeetingsDetailView`). The library draws only the static brand mark (design §8.9): no
// Spool on the list, a still cameo in the empty and loading renderings via `SectionPage`.

struct MeetingsSectionView: View {
    @ObservedObject var model: MeetingsSectionViewModel
    @ObservedObject var capture: MeetingCaptureController
    @ObservedObject var retry: ScopedRetry
    var hotkey: String
    var open: (WindowRoute) -> Void
    var expandPanel: () -> Void

    /// The removal waiting for confirmation: every one deletes the only saved copy.
    @State private var pending: MeetingRemoval?

    init(model: MeetingsSectionViewModel, hotkey: String, open: @escaping (WindowRoute) -> Void,
         expandPanel: @escaping () -> Void) {
        self.model = model
        self.capture = model.capture
        self.retry = model.retry
        self.hotkey = hotkey
        self.open = open
        self.expandPanel = expandPanel
    }

    var body: some View {
        VStack(spacing: 0) {
            if let record = model.selected {
                MeetingsDetailView(model: model, record: record, hotkey: hotkey, open: open, expandPanel: expandPanel)
            } else {
                library
            }
            detectionFooter
        }
        .confirmationDialog(pending?.title ?? "",
                            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            presenting: pending) { removal in
            Button(removal.confirm, role: .destructive) { model.delete(id: removal.id) }
            Button(MeetingsCopy.cancel, role: .cancel) {}
        } message: { removal in
            Text(removal.message)
        }
    }

    // MARK: Library

    private var library: some View {
        SectionPage(PageCopy(.meetings), state: model.state, banner: model.banner,
                    headerAction: startAction,
                    onStateAction: model.state.rendering == .error ? retryLoad : start,
                    onBannerAction: retryLoad,
                    isRetrying: retry.isRetrying,
                    hotkey: hotkey) {
            libraryContent
        }
    }

    /// "Start recording" (prototype primary header action). Disabled while a meeting is already open;
    /// Calendar and the detection opt-in never disable it.
    private var startAction: PageAction {
        PageAction(MeetingsCopy.startRecording, isEnabled: capture.state.phase == .idle,
                   identifier: "meetings.startRecording", perform: start)
    }

    private func start() {
        Task { await model.startRecording() }
    }

    private func retryLoad() {
        Task { await model.retryLoad() }
    }

    private var libraryContent: some View {
        VStack(alignment: .leading, spacing: MainWindowLayout.sectionGap) {
            if let problem = model.captureProblem {
                ScopedBanner(problem, onAction: { open(WindowRoute(.privacy)) })
                    .overlay(alignment: .topTrailing) {
                        Button { model.dismissCaptureProblem() } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain)
                            .padding(Tokens.Spacing.m)
                            .accessibilityLabel("Dismiss")
                    }
                    .accessibilityIdentifier("meetings.captureProblem")
            }
            ForEach(model.unfinished) { recording in
                UnfinishedRecordingBanner(recording: recording,
                                          showsTitle: model.unfinished.count > 1,
                                          isRecovering: model.recoveringID == recording.id,
                                          recover: { Task { await model.recover(id: recording.id) } },
                                          discard: { pending = .discard(recording) })
            }
            if model.searchHidesEverything {
                noMatches
            } else {
                GroupBox(layout: .rows) {
                    ForEach(model.rows) { row in
                        rowView(row)
                    }
                    ForEach(model.unreadableIDs, id: \.self) { id in
                        unreadableRow(id)
                    }
                }
                .accessibilityIdentifier("meetings.list")
            }
            if let note = model.calendarNote {
                Text(note)
                    .windowFont(Tokens.Typography.meta)
                    .foregroundStyle(WindowColor.secondaryInk)
                    .accessibilityIdentifier("meetings.calendarState")
            }
        }
    }

    @ViewBuilder private func rowView(_ row: MeetingRow) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            RowView(row.title, detail: row.detail) {
                HStack(spacing: Tokens.Spacing.s) {
                    if let label = row.label { StatusTag(label, kind: .warn) }
                    trailing(row)
                }
            }
            if let problem = model.rowProblems[row.id] {
                rowProblem(problem, id: row.id)
            }
        }
        .contextMenu {
            // The meeting being captured is neither exported nor deleted mid-recording: Stop it first.
            if !row.isLive, let record = model.meetings.first(where: { $0.id == row.id }) {
                Button(MeetingsCopy.export) { MeetingExport.save(record, markdown: model.markdown(for: record)) }
                Button(MeetingsCopy.delete, role: .destructive) { pending = .delete(id: row.id, title: row.title) }
            }
        }
        .accessibilityIdentifier("meetings.row")
    }

    /// A meeting whose saved file can't be read (X02): its own row, Recover from the text copy, or
    /// Delete… after confirmation. The other rows are untouched.
    @ViewBuilder private func unreadableRow(_ id: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            RowView(SectionCopy.meetingUnreadableRow, detail: model.unreadableDetails[id] ?? MeetingsCopy.savedOnThisMac) {
                HStack(spacing: Tokens.Spacing.s) {
                    Button(MeetingsCopy.recover) { Task { await model.recoverUnreadable(id: id) } }
                        .disabled(model.recoveringID != nil)
                        .accessibilityIdentifier("meetings.unreadableRow.recover")
                    Button(MeetingsCopy.delete, role: .destructive) { pending = .deleteUnreadable(id: id) }
                        .disabled(model.recoveringID == id)
                        .accessibilityIdentifier("meetings.unreadableRow.delete")
                }
            }
            if let problem = model.rowProblems[id] {
                rowProblem(problem, id: id)
            }
        }
        .accessibilityIdentifier("meetings.unreadableRow")
    }

    /// A failure on one row, under that row only.
    private func rowProblem(_ problem: SectionBanner, id: String) -> some View {
        HStack(spacing: Tokens.Spacing.s) {
            Label(problem.headline, systemImage: "exclamationmark.triangle")
                .foregroundStyle(WindowColor.attention)
            if let body = problem.body {
                Text(body).foregroundStyle(WindowColor.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if problem.actionTitle == MeetingsCopy.showInFinder {
                Button(MeetingsCopy.showInFinder) { NSWorkspace.shared.activateFileViewerSelecting([model.directory(for: id)]) }
            }
            if let diagnostics = problem.diagnostics {
                Button(SectionCopy.copyDiagnostics) { Pasteboard.copy(diagnostics) }
            }
        }
        .windowFont(Tokens.Typography.meta)
        .padding(.horizontal, Tokens.Spacing.l)
        .padding(.bottom, Tokens.Spacing.m)
        .accessibilityIdentifier("meetings.row.problem")
    }

    @ViewBuilder private func trailing(_ row: MeetingRow) -> some View {
        switch row.status {
        case .needsRecovery:
            // Recovery belongs to the affected row (design §8.9, §9).
            Button(MeetingsCopy.recover) { Task { await model.recover(id: row.id) } }
                .disabled(model.recoveringID == row.id)
                .accessibilityIdentifier("meetings.row.recover")
        case .recording, .paused:
            StatusTag(row.status.word, kind: .good)
            Button("Expand", action: expandPanel)
                .accessibilityIdentifier("meetings.row.expand")
        case .preparingNotes:
            StatusTag(row.status.word)
            Button(MeetingsCopy.open) { model.open(id: row.id) }
        case .notesReady, .transcriptSaved:
            Button(MeetingsCopy.open) { model.open(id: row.id) }
                .accessibilityIdentifier("meetings.row.open")
        }
    }

    private var noMatches: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Text(MeetingsCopy.noMatches(model.search))
                .windowFont(Tokens.Typography.section)
                .foregroundStyle(WindowColor.ink)
            Button(MeetingsCopy.clearSearch) { model.search = "" }
                .accessibilityIdentifier("meetings.clearSearch")
        }
        .accessibilityIdentifier("meetings.noMatches")
    }

    // MARK: The detection opt-in (kept reachable; optional for manual recording)

    private var detectionFooter: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            Toggle(MeetingsCopy.detectionTitle, isOn: Binding(
                get: { model.isCaptureEnabled },
                set: { model.isCaptureEnabled = $0 }
            ))
            .accessibilityIdentifier("meetings.captureEnabled")
            Text(MeetingsCopy.detectionDetail)
                .windowFont(Tokens.Typography.meta)
                .foregroundStyle(WindowColor.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .windowFont(Tokens.Typography.body)
        .padding(.horizontal, MainWindowLayout.outerPadding)
        .padding(.vertical, Tokens.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(WindowColor.separator).frame(height: 1) }
        .background(WindowColor.canvas)
    }
}

/// The unfinished-recording banner (prototype `banner(...)` with Recover and Discard…): the design's
/// scoped banner, with two actions instead of one.
struct UnfinishedRecordingBanner: View {
    var recording: UnfinishedRecording
    var showsTitle: Bool
    var isRecovering: Bool
    var recover: () -> Void
    var discard: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.Radius.group, style: .continuous)
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Label {
                Text(recording.headline).fontWeight(.semibold)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .windowFont(Tokens.Typography.body)
            .foregroundStyle(WindowColor.attention)
            Text(showsTitle ? "\(recording.title) · \(recording.body)" : recording.body)
                .windowFont(Tokens.Typography.meta)
                .foregroundStyle(WindowColor.secondaryInk)
            HStack(spacing: Tokens.Spacing.s) {
                PageActionButton(action: PageAction(MeetingsCopy.recover, isEnabled: !isRecovering,
                                                    identifier: "meetings.unfinished.recover", perform: recover))
                PageActionButton(action: PageAction(MeetingsCopy.discard, isPrimary: false, isEnabled: !isRecovering,
                                                    identifier: "meetings.unfinished.discard", perform: discard))
            }
            .padding(.top, Tokens.Spacing.xs)
        }
        .padding(Tokens.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(WindowColor.attention.opacity(ScopedBannerStyle.fillOpacity)))
        .overlay(shape.strokeBorder(WindowColor.attention.opacity(ScopedBannerStyle.outlineOpacity), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meetings.unfinished")
    }
}

/// A removal the user confirms first. Discard (an unfinished recording), Delete… (a saved meeting)
/// and Delete… on an unreadable row all remove the only saved copy.
enum MeetingRemoval: Equatable, Identifiable {
    case discard(UnfinishedRecording)
    case delete(id: String, title: String)
    case deleteUnreadable(id: String)

    var id: String {
        switch self {
        case .discard(let recording): return recording.id
        case .delete(let id, _), .deleteUnreadable(let id): return id
        }
    }

    var title: String {
        switch self {
        case .discard: return MeetingsCopy.discardTitle
        case .delete(_, let title): return MeetingsCopy.deleteTitle(title)
        case .deleteUnreadable: return MeetingsCopy.deleteUnreadableTitle
        }
    }

    var message: String {
        switch self {
        case .discard(let recording): return recording.discardMessage
        case .delete: return MeetingsCopy.deleteMessage
        case .deleteUnreadable: return MeetingsCopy.deleteUnreadableMessage
        }
    }

    var confirm: String {
        switch self {
        case .discard: return MeetingsCopy.discardConfirm
        case .delete, .deleteUnreadable: return MeetingsCopy.deleteConfirm
        }
    }
}

/// Export… (prototype detail header action): the meeting as Markdown, where the user chooses.
enum MeetingExport {
    @MainActor
    static func save(_ record: MeetingRecord, markdown: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(record.title).md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? markdown.data(using: .utf8)?.write(to: url, options: .atomic)
    }
}
