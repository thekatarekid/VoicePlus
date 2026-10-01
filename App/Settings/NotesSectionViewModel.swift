import AppKit
import Foundation
import Shared

// V5 N1 — the Notes section's state. Pure enough to assert: no SwiftUI here; the pasteboard and the
// "insert into the app behind the window" path are closures the composition root supplies.

/// Notes' words, in one place.
public enum NotesCopy {
    public static let title = "Notes"
    public static let subtitle = "Words kept for later, never typed on their own."
    public static let emptyHeadline = "No notes yet"
    public static let emptyBody = "Say “note …” while hands-free, or speak with no text field focused. What you say is kept here instead of being typed."
    public static let unavailableHeadline = "Notes aren't available"
    public static let unavailableBody = "VoicePlus could not open its notes folder. Your other data is unaffected."
    public static let loading = "Loading notes…"
    public static func noMatches(_ query: String) -> String { "No notes match “\(query)”" }
    public static let clearSearch = "Clear search"
    public static let tryAgain = "Try again"
    public static let insertHere = "Insert here"
    public static let insertAll = "Insert all"
    public static let copy = "Copy"
    public static let discard = "Discard"
    public static let export = "Export Markdown…"
    public static let inserted = "Inserted."
    public static let insertedAll = "Inserted every note shown."
    public static let copied = "Copied."
    public static let notInserted = "Nothing took the text — it was copied instead."

    /// The pill chip (V5 N3) and menu row: "📝 notes · 3".
    public static func chip(_ count: Int) -> String { "📝 notes · \(count)" }
    /// Menu row title: "3 new notes".
    public static func menuRow(_ count: Int) -> String { count == 1 ? "1 new note" : "\(count) new notes" }
    public static let menuRowDetail = "Kept instead of typed."
}

@MainActor
public final class NotesSectionViewModel: ObservableObject {
    /// One day of rows, newest day first, newest row first.
    public struct Day: Identifiable, Equatable {
        public var id: Date
        public var title: String
        public var rows: [NoteEntry]
    }

    @Published public private(set) var rows: [NoteEntry] = []
    @Published public private(set) var page: SectionState = .loading(NotesCopy.loading)
    @Published public var search: String = ""
    @Published public var selectedID: String?
    @Published public private(set) var unreadCount: Int = 0
    @Published public private(set) var notice: String?

    public let store: NotesStore?
    private let settings: (any SettingsStore)?
    /// Inserts text into the app behind the window. `nil` (tests, no injector) → copy instead.
    public var insertText: ((String) async -> Bool)?
    public var copyText: (String) -> Void
    private let now: () -> Date
    private var observer: NSObjectProtocol?

    public init(store: NotesStore?, settings: (any SettingsStore)?,
                insertText: ((String) async -> Bool)? = nil,
                copyText: @escaping (String) -> Void = NotesSectionViewModel.pasteboardCopy,
                now: @escaping () -> Date = { Date() }) {
        self.store = store
        self.settings = settings
        self.insertText = insertText
        self.copyText = copyText
        self.now = now
        if let store {
            observer = NotificationCenter.default.addObserver(forName: NotesStore.didChange, object: store, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshUnread() }
            }
        }
        refreshUnread()
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    public nonisolated static func pasteboardCopy(_ text: String) {
        DispatchQueue.main.async {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    // MARK: Loading

    public func reload() async {
        guard let store else {
            rows = []
            page = .error(NotesCopy.unavailableHeadline, detail: NotesCopy.unavailableBody, action: NotesCopy.tryAgain)
            return
        }
        rows = store.entries(matching: search)
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if rows.isEmpty {
            page = q.isEmpty ? .empty(NotesCopy.emptyHeadline, detail: NotesCopy.emptyBody)
                : .empty(NotesCopy.noMatches(q), action: NotesCopy.clearSearch)
        } else {
            page = .content
        }
        if let id = selectedID, !rows.contains(where: { $0.id == id }) { selectedID = nil }
        refreshUnread()
    }

    public func searchChanged(_ query: String) async {
        search = query
        await reload()
    }

    public func clearSearch() async { await searchChanged("") }

    /// Rows grouped by day, newest day first.
    public var days: [Day] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: rows) { calendar.startOfDay(for: $0.capturedAt) }
        return grouped.keys.sorted(by: >).map { day in
            Day(id: day, title: Self.dayTitle(day, now: now(), calendar: calendar),
                rows: grouped[day]!.sorted { $0.capturedAt > $1.capturedAt })
        }
    }

    static func dayTitle(_ day: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: y) { return "Yesterday" }
        let f = DateFormatter()
        f.dateStyle = .medium; f.timeStyle = .none
        return f.string(from: day)
    }

    public static func timeLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .none; f.timeStyle = .short
        return f.string(from: date)
    }

    // MARK: Unread

    public func refreshUnread() {
        unreadCount = store?.unreadCount(since: NotesStore.lastSeen(settings)) ?? 0
    }

    /// Opening the section reads everything in it.
    public func markSeen() {
        NotesStore.markSeen(settings, at: now())
        refreshUnread()
    }

    // MARK: Row actions

    public func entry(_ id: String) -> NoteEntry? { rows.first { $0.id == id } }

    /// ↩ / "Insert here": into the app behind the window. Falls back to Copy, and says so.
    public func insert(_ id: String) async {
        guard let entry = entry(id) else { return }
        await insert(text: entry.text, success: NotesCopy.inserted)
    }

    /// Every row shown (the current search), oldest first, one per line.
    public func insertAll() async {
        guard !rows.isEmpty else { return }
        await insert(text: Self.joined(rows), success: NotesCopy.insertedAll)
    }

    static func joined(_ rows: [NoteEntry]) -> String {
        rows.sorted { $0.capturedAt < $1.capturedAt }.map(\.text).joined(separator: "\n")
    }

    private func insert(text: String, success: String) async {
        if let insertText, await insertText(text) {
            notice = success
        } else {
            copyText(text)
            notice = NotesCopy.notInserted
        }
    }

    /// ⌘C.
    public func copy(_ id: String) {
        guard let entry = entry(id) else { return }
        copyText(entry.text)
        notice = NotesCopy.copied
    }

    /// ⌫. Deletes the text and its search-index rows (N4).
    public func discard(_ id: String) async {
        guard let store else { return }
        do {
            try store.delete(id: id)
        } catch {
            Log.app.error("notes: discard failed: \(error)")
        }
        if selectedID == id { selectedID = nil }
        await reload()
    }

    /// The rows shown, as Markdown (the view saves it through a save panel).
    public func exportMarkdown() -> String {
        NotesStore.markdown(rows)
    }

    public func dismissNotice() { notice = nil }
}
