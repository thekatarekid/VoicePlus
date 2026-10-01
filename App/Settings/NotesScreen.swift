import AppKit
import SwiftUI
import UniformTypeIdentifiers

// V5 N1 — the Notes section's `SectionScreen`. A list grouped by day; each row: time, source tag,
// text; actions Insert here · Copy · Discard on the row (and as swipe actions), Insert all and
// Export Markdown in the header. Keyboard: ↩ inserts the selected row, ⌘C copies it, ⌫ discards it.
// Search is the shell's toolbar search (token AND over the Timeline's index, N4).
struct NotesScreen: SectionScreen {
    static let section: MainWindowSection = .notes

    let context: SectionContext
    @ObservedObject private var notes: NotesSectionViewModel
    @ObservedObject private var navigation: SectionNavigation

    init(context: SectionContext) {
        self.context = context
        _notes = ObservedObject(wrappedValue: context.window.notes)
        _navigation = ObservedObject(wrappedValue: context.navigation)
    }

    var body: some View {
        SectionPage(PageCopy(.today, title: NotesCopy.title, subtitle: NotesCopy.subtitle, name: NotesCopy.title),
                    state: notes.page,
                    headerAction: notes.rows.isEmpty ? nil
                        : PageAction(NotesCopy.insertAll, identifier: "notes.insertAll") { Task { await notes.insertAll() } },
                    onStateAction: { stateAction() },
                    hotkey: context.hotkey, scrolls: false) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                HStack {
                    if let notice = notes.notice {
                        Text(notice)
                            .windowFont(Tokens.Typography.meta)
                            .foregroundStyle(WindowColor.secondaryInk)
                            .accessibilityIdentifier("notes.notice")
                    }
                    Spacer()
                    Button(NotesCopy.export) { export() }
                        .accessibilityIdentifier("notes.export")
                }
                list
            }
        }
        .accessibilityIdentifier("notes.page")
        .task { await notes.reload(); markSeenIfShown() }
        .onReceive(NotificationCenter.default.publisher(for: NotesStore.didChange)) { _ in
            Task { await notes.reload(); markSeenIfShown() }
        }
        .onChange(of: navigation.searchQuery) { _, query in
            guard notes.search != query else { return }
            Task { await notes.searchChanged(query) }
        }
        .onChange(of: notes.search) { _, query in
            if navigation.searchQuery != query { navigation.searchQuery = query }
        }
    }

    private var list: some View {
        List(selection: $notes.selectedID) {
            ForEach(notes.days) { day in
                Section(day.title) {
                    ForEach(day.rows) { row in
                        NotesRow(entry: row)
                            .tag(row.id)
                            .swipeActions(edge: .trailing) {
                                Button(NotesCopy.discard, role: .destructive) { Task { await notes.discard(row.id) } }
                                Button(NotesCopy.copy) { notes.copy(row.id) }
                            }
                            .swipeActions(edge: .leading) {
                                Button(NotesCopy.insertHere) { Task { await notes.insert(row.id) } }
                            }
                            .contextMenu {
                                Button(NotesCopy.insertHere) { Task { await notes.insert(row.id) } }
                                Button(NotesCopy.copy) { notes.copy(row.id) }
                                Button(NotesCopy.discard, role: .destructive) { Task { await notes.discard(row.id) } }
                            }
                    }
                }
            }
        }
        .listStyle(.inset)
        .onKeyPress(.return) {
            guard let id = notes.selectedID else { return .ignored }
            Task { await notes.insert(id) }
            return .handled
        }
        .onDeleteCommand {
            if let id = notes.selectedID { Task { await notes.discard(id) } }
        }
        .onCopyCommand {
            guard let id = notes.selectedID, let entry = notes.entry(id) else { return [] }
            notes.copy(id)
            return [NSItemProvider(object: entry.text as NSString)]
        }
        .accessibilityIdentifier("notes.list")
    }

    /// Hidden (kept-alive) sections must not read notes on the user's behalf.
    private func markSeenIfShown() {
        if context.window.selection == .notes { notes.markSeen() }
    }

    private func stateAction() {
        Task {
            if notes.page.rendering == .error { await notes.reload() } else { await notes.clearSearch() }
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "VoicePlus Notes.md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? notes.exportMarkdown().data(using: .utf8)?.write(to: url, options: .atomic)
    }
}

/// One row: time · source tag · text, plus the inline actions.
struct NotesRow: View {
    let entry: NoteEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.s) {
            Text(NotesSectionViewModel.timeLabel(entry.capturedAt))
                .windowFont(Tokens.Typography.meta)
                .foregroundStyle(WindowColor.secondaryInk)
                .frame(minWidth: 56, alignment: .leading)
            StatusTag(entry.source.label)
                .accessibilityIdentifier("notes.row.source.\(entry.source.rawValue)")
            Text(entry.text)
                .windowFont(Tokens.Typography.body)
                .foregroundStyle(WindowColor.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, Tokens.Spacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("notes.row")
    }
}
