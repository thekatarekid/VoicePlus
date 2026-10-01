import Engine
import Foundation
import Pipeline
import Shared
import Testing
@testable import VoicePlusApp

/// V5 N1 (Notes section), N2 (routes into Notes), N3 (pill chip + menu row).
@Suite("Notes section, routes, chip (V5 N1–N3)")
@MainActor
struct NotesSectionTests {
    static let now = Date(timeIntervalSince1970: 1_700_000_000)

    final class Box: @unchecked Sendable { var copied: [String] = []; var inserted: [String] = [] }

    struct Rig {
        let store: NotesStore
        let root: URL
        let settings = InMemorySettingsStore()
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("n1-\(UUID().uuidString)", isDirectory: true)
            store = NotesStore(root: root, database: try AppDatabase.inMemory(), clock: { NotesSectionTests.now })
        }
        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    static func model(_ rig: Rig, box: Box, insertSucceeds: Bool? = true) -> NotesSectionViewModel {
        let insert: ((String) async -> Bool)? = insertSucceeds.map { ok in { text in box.inserted.append(text); return ok } }
        return NotesSectionViewModel(store: rig.store, settings: rig.settings, insertText: insert,
                                     copyText: { box.copied.append($0) }, now: { NotesSectionTests.now })
    }

    // MARK: N1 — section

    @Test("Notes is a sidebar section with search, after Meetings, and loads on open")
    func section() {
        #expect(MainWindowSection.allCases.firstIndex(of: .notes) == MainWindowSection.allCases.firstIndex(of: .meetings)! + 1)
        #expect(MainWindowSection.notes.title == "Notes")
        #expect(MainWindowSection.notes.detailTitle == NotesCopy.title)
        #expect(!MainWindowSection.notes.subtitle.isEmpty)
        #expect(MainWindowSection.notes.hasSearchField)
        #expect(MainWindowSection.notes.isPostPrototype)
        #expect(SettingsReachability.sourceFiles(for: .notes) == ["App/Settings/NotesScreen.swift"])
    }

    @Test("empty, content and no-match renderings; rows grouped by day, newest first")
    func renderings() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let box = Box()
        let model = Self.model(rig, box: box)
        await model.reload()
        #expect(model.page.rendering == .empty && model.page.headline == NotesCopy.emptyHeadline)
        #expect(model.page.isWellFormed)

        try rig.store.add("yesterday's idea", source: .noField, at: Self.now.addingTimeInterval(-86_400))
        try rig.store.add("first today", source: .latch, at: Self.now.addingTimeInterval(-60))
        try rig.store.add("second today", source: .wakeVerb, at: Self.now)
        await model.reload()
        #expect(model.page == .content)
        #expect(model.days.map(\.title) == ["Today", "Yesterday"])
        #expect(model.days[0].rows.map(\.text) == ["second today", "first today"])
        #expect(model.days[0].rows.map(\.source) == [.wakeVerb, .latch])

        await model.searchChanged("idea")
        #expect(model.rows.map(\.text) == ["yesterday's idea"])
        await model.searchChanged("zebra")
        #expect(model.page.rendering == .empty && model.page.actionTitle == NotesCopy.clearSearch)
        await model.clearSearch()
        #expect(model.rows.count == 3)
    }

    @Test("no store: an error that names a way out")
    func unavailable() async {
        let model = NotesSectionViewModel(store: nil, settings: nil)
        await model.reload()
        #expect(model.page.rendering == .error && model.page.isWellFormed)
    }

    @Test("Insert here, Insert all (oldest first), Copy, Discard")
    func actions() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let box = Box()
        let model = Self.model(rig, box: box)
        let a = try #require(try rig.store.add("alpha", source: .latch, at: Self.now.addingTimeInterval(-10)))
        let b = try #require(try rig.store.add("beta", source: .noField, at: Self.now))
        await model.reload()

        await model.insert(a)
        #expect(box.inserted == ["alpha"] && model.notice == NotesCopy.inserted)
        await model.insertAll()
        #expect(box.inserted.last == "alpha\nbeta" && model.notice == NotesCopy.insertedAll)
        model.copy(b)
        #expect(box.copied == ["beta"] && model.notice == NotesCopy.copied)
        // Inserting keeps the note; discarding deletes it (and its index rows, N4).
        #expect(model.rows.count == 2)
        model.selectedID = b
        await model.discard(b)
        #expect(model.rows.map(\.id) == [a])
        #expect(model.selectedID == nil)
    }

    @Test("an insert nothing took falls back to Copy and says so")
    func insertFallsBackToCopy() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let box = Box()
        let failing = Self.model(rig, box: box, insertSucceeds: false)
        let id = try #require(try rig.store.add("gamma", source: .latch, at: Self.now))
        await failing.reload()
        await failing.insert(id)
        #expect(box.copied == ["gamma"] && failing.notice == NotesCopy.notInserted)

        let noInserter = Self.model(rig, box: box, insertSucceeds: nil)
        await noInserter.reload()
        await noInserter.insert(id)
        #expect(box.copied == ["gamma", "gamma"])
    }

    @Test("Export Markdown is the rows shown")
    func export() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = Self.model(rig, box: Box())
        try rig.store.add("ship the notes", source: .wakeVerb, at: Self.now)
        try rig.store.add("other", source: .latch, at: Self.now.addingTimeInterval(-5))
        await model.searchChanged("ship")
        let md = model.exportMarkdown()
        #expect(md.contains("ship the notes") && !md.contains("other"))
    }

    @Test("unread count: notes since last opened; opening marks them seen")
    func unread() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = Self.model(rig, box: Box())
        #expect(model.unreadCount == 0)
        try rig.store.add("one", source: .latch, at: Self.now.addingTimeInterval(-5))
        try rig.store.add("two", source: .noField, at: Self.now.addingTimeInterval(-4))
        model.refreshUnread()
        #expect(model.unreadCount == 2)
        model.markSeen()
        #expect(model.unreadCount == 0)
    }

    @Test("the window model owns a Notes view model and loads it when Notes opens")
    func windowLoadsNotes() async throws {
        let store = InMemorySettingsStore()
        let window = MainWindowShellS7aTests.window(store: store, section: .notes)
        #expect(window.selection == .notes)
        await window.load(.notes)
        // No store injected by the test harness → the honest error, not a blank page.
        #expect(window.notes.page.rendering == .error)
        window.apply(WindowRoute(.today))
        window.apply(WindowRoute(.notes))
        #expect(MainWindowSection.remembered(store) == .notes)
    }

    // MARK: N2 — routes

    @Test("every N2 route maps to its source tag")
    func routes() throws {
        let g = WakeVerbGrammar()
        typealias S = NotesRouteSignals
        #expect(NotesRoute.decide("note buy milk", S(wakeVerb: g.parse("note buy milk"), latched: true)) == .note(.wakeVerb, text: "buy milk"))
        #expect(NotesRoute.decide("hello", S(hasFocusedField: false)).source == .noField)
        #expect(NotesRoute.decide("hello", S(appSwitchedMidSegment: true)).source == .appSwitch)
        #expect(NotesRoute.decide("hello", S(ambientBand: .note)).source == .lowerMiddle)
        #expect(NotesRoute.decide("hello", S(declinedAsk: true)).source == .declinedAsk)
        #expect(NotesRoute.decide("hello", S(ambientBand: .act, listenAndNote: true)).source == .listenAndNote)
        #expect(NotesRoute.decide("hello", S(ambientBand: .note, listenAndNote: true)).source == .listenAndNote)
        #expect(NotesRoute.decide("hello", S(latched: true, meetingActive: true)).source == .meetingAside)
        #expect(NotesRoute.decide("hello", S(agentActionRunning: true)).source == .agentRunning)
        #expect(NotesRoute.decide("hello", S(latched: true, arbiterChoseNote: true)).source == .latch)
    }

    @Test("not a note: a focused field, ambient ignore / act outside Listen & note, empty text, a bare verb")
    func passThrough() {
        let g = WakeVerbGrammar()
        #expect(NotesRoute.decide("hello", NotesRouteSignals()) == .passThrough)
        #expect(NotesRoute.decide("hello", NotesRouteSignals(ambientBand: .ignore, listenAndNote: true)) == .passThrough)
        #expect(NotesRoute.decide("hello", NotesRouteSignals(ambientBand: .act)) == .passThrough)
        #expect(NotesRoute.decide("hello", NotesRouteSignals(ambientBand: .ask)) == .passThrough)
        #expect(NotesRoute.decide("   ", NotesRouteSignals(hasFocusedField: false)) == .passThrough)
        #expect(NotesRoute.decide("type hello", NotesRouteSignals(wakeVerb: g.parse("type hello"))) == .passThrough)
    }

    @Test("precedence: the wake verb outranks a missing field; ambient never reaches the no-field route")
    func precedence() {
        let g = WakeVerbGrammar()
        let s = NotesRouteSignals(hasFocusedField: false, wakeVerb: g.parse("note x y"), agentActionRunning: true)
        #expect(NotesRoute.decide("note x y", s) == .note(.wakeVerb, text: "x y"))
        #expect(NotesRoute.decide("hi", NotesRouteSignals(hasFocusedField: false, ambientBand: .ignore)) == .passThrough)
        #expect(NotesRoute.decide("hi", NotesRouteSignals(declinedAsk: true, agentActionRunning: true)).source == .declinedAsk)
    }

    @Test("the router stores what it routes, with the source tag, and tells the chip")
    func router() throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let router = NotesRouter(store: rig.store)
        final class Seen: @unchecked Sendable { var sources: [NoteSource] = [] }
        let seen = Seen()
        router.onNoted = { source, _ in seen.sources.append(source) }
        #expect(router.route("words with nowhere to go", signals: NotesRouteSignals(hasFocusedField: false), at: Self.now).source == .noField)
        #expect(router.route("typed normally", signals: NotesRouteSignals(), at: Self.now) == .passThrough)
        #expect(rig.store.notes().map(\.text) == ["words with nowhere to go"])
        #expect(rig.store.notes().first?.source == .noField)
        #expect(seen.sources == [.noField])
        let other = try #require(router.routeOtherVoice("someone else", meetingActive: true, at: Self.now.addingTimeInterval(1)))
        #expect(rig.store.notes().first { $0.id == other }?.source == .meetingAside)
    }

    // MARK: N3 — pill chip and menu row

    @Test("the chip reads '📝 notes · N' and shows only while N > 0")
    func chip() {
        #expect(!NotesChip.isVisible(count: 0))
        #expect(NotesChip.isVisible(count: 2))
        #expect(NotesChip.title(count: 3) == "📝 notes · 3")
        #expect(NotesChip.accessibilityLabel(count: 1) == "1 note kept")
    }

    @Test("the chip feed follows the store and clears when Notes is opened")
    func chipFeed() throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let feed = NotesChipFeed(store: rig.store, settings: rig.settings)
        final class Counts: @unchecked Sendable { var values: [Int] = [] }
        let counts = Counts()
        feed.onCount = { counts.values.append($0) }
        #expect(counts.values == [0])
        try rig.store.add("a", source: .latch, at: Self.now)
        // Delivered on the main queue; the feed's own count is current immediately.
        #expect(feed.count == 1)
        NotesStore.markSeen(rig.settings, at: Self.now.addingTimeInterval(1))
        #expect(feed.count == 0)
    }

    @Test("the pill model carries the count; the chip row is part of a turn's lanes")
    func pillModel() {
        let pill = PillViewModel()
        #expect(pill.notesCount == 0)
        pill.notesCount = 4
        var opened = false
        pill.onOpenNotes = { opened = true }
        pill.onOpenNotes?()
        #expect(opened && pill.notesCount == 4)
    }

    @Test("menu: 'N new notes' row only when there are unread notes; it opens Notes")
    func menuRow() throws {
        let none = StatusMenuSpec.entries(StatusMenuState())
        #expect(StatusMenuSpec.entry(StatusMenuSpec.ID.notes, in: none) == nil)
        let some = StatusMenuSpec.entries(StatusMenuState(notesUnread: 3))
        let row = try #require(StatusMenuSpec.entry(StatusMenuSpec.ID.notes, in: some))
        #expect(row.title == "3 new notes" && row.action == .openNotes && row.isEnabled)
        #expect(StatusMenuSpec.entries(StatusMenuState(notesUnread: 1)).contains { $0.title == "1 new note" })
        // It sits with the capture rows, before the app rows.
        let ids = some.map(\.id)
        #expect(ids.firstIndex(of: StatusMenuSpec.ID.notes)! < ids.firstIndex(of: StatusMenuSpec.ID.openWindow)!)
    }
}
