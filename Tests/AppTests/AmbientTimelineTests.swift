import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// R8.3 — the Timeline (`AmbientTimeline`): search, source filters, delete and delete-all, each with
/// its empty, its loading line and its error (`DESIGN.md` §9.1, V3 §8).
///
/// No XCTest, no UI testing and no simulator on this toolchain, so the `body` is not exercised —
/// every rendering is a value `TodaySectionViewModel` computes, and that is what is asserted here.
/// The store is a stub behind `AmbientTimelineReading`, which is also the point: R8.1/R8.2 own the
/// real store, and the view is not allowed a second delete path around it.
@Suite("R8.3 the Timeline: search, filters, delete, delete-all")
@MainActor
struct AmbientTimelineTests {

    static func defaults() -> UserDefaults { UserDefaults(suiteName: "vp.timeline.\(UUID().uuidString)")! }

    /// A stand-in for `AmbientTranscriptStore`, able to fail, to stall, and — the case that matters —
    /// to accept a delete and keep the row anyway.
    final class StubStore: AmbientTimelineReading, @unchecked Sendable {
        struct Boom: Error {}

        private let lock = NSLock()
        private var _rows: [TimelineRow]
        private var _queries: [TimelineQuery] = []
        private var _deleted: [String] = []
        private var _deleteAllCalls = 0

        /// Fails the read.
        var readFailure: Error?
        /// Fails the delete / delete-all outright.
        var deleteFailure: Error?
        /// Returns from delete without throwing **and without deleting** — a store whose index write
        /// failed, or a row another process had already re-added. The section must not claim it is gone.
        var deleteSilentlyDoesNothing = false
        /// The store's own source index. Empty = "I don't keep one".
        var storedSources: [TimelineSource] = []
        var sourcesFailure: Error?
        /// Holds a read open so the loading rendering can be observed while it happens.
        var gate: Gate?

        init(rows: [TimelineRow] = []) { _rows = rows }

        var rows: [TimelineRow] { lock.withLock { _rows } }
        var queries: [TimelineQuery] { lock.withLock { _queries } }
        var deleted: [String] { lock.withLock { _deleted } }
        var deleteAllCalls: Int { lock.withLock { _deleteAllCalls } }

        /// Never called: the section always asks the query overload. Kept honest anyway.
        func rows(matching query: String) async throws -> [TimelineRow] {
            try await rows(matching: TimelineQuery(text: query))
        }

        func rows(matching query: TimelineQuery) async throws -> [TimelineRow] {
            await gate?.wait()
            lock.withLock { _queries.append(query) }
            if let readFailure { throw readFailure }
            return lock.withLock { _rows.filter(query.matches) }
        }

        func sources() async throws -> [TimelineSource] {
            if let sourcesFailure { throw sourcesFailure }
            return storedSources
        }

        func delete(id: String) throws {
            if let deleteFailure { throw deleteFailure }
            lock.withLock {
                _deleted.append(id)
                guard !deleteSilentlyDoesNothing else { return }
                _rows.removeAll { $0.id == id }
            }
        }

        func deleteAll() throws {
            if let deleteFailure { throw deleteFailure }
            lock.withLock {
                _deleteAllCalls += 1
                guard !deleteSilentlyDoesNothing else { return }
                _rows = []
            }
        }
    }

    /// A store that implements only the text read — the default protocol implementations in
    /// `TodayTimeline.swift` have to do the source filtering for it.
    final class TextOnlyStore: AmbientTimelineReading, @unchecked Sendable {
        let all: [TimelineRow]
        init(_ all: [TimelineRow]) { self.all = all }
        func rows(matching query: String) async throws -> [TimelineRow] {
            query.isEmpty ? all : all.filter { $0.text.localizedCaseInsensitiveContains(query) }
        }
        func delete(id: String) throws {}
        func deleteAll() throws {}
    }

    private func row(_ text: String, source: String = "ambient", minutesAgo: Double = 0,
                     id: String = UUID().uuidString) -> TimelineRow {
        TimelineRow(id: id, time: Date().addingTimeInterval(-minutesAgo * 60), source: source, text: text)
    }

    private func today(ambient: Bool = true, reader: (any AmbientTimelineReading)?,
                       settings: (any SettingsStore)? = nil) -> TodaySectionViewModel {
        var deps = OnboardingDependencies.mock()
        if let settings { deps.settingsStore = settings }
        return TodaySectionViewModel(deps: deps,
                                     audio: AudioInputSettingsViewModel(defaults: Self.defaults()),
                                     mute: InMemoryMuteStore(),
                                     reader: reader,
                                     ambientCaptureOn: { ambient })
    }

    // MARK: - Search

    @Test("search asks the store for the text, and no-matches explains itself and offers the way back")
    func searchAndItsEmpty() async {
        let store = StubStore(rows: [row("the roof needs doing"), row("call the plumber")])
        let model = today(reader: store)
        await model.reloadTimeline()
        #expect(model.timelineRows.count == 2)

        await model.setSearch("plumber")
        #expect(store.queries.last?.text == "plumber", "the store does the matching, not the view")
        #expect(model.timelineRows.map(\.text) == ["call the plumber"])
        #expect(model.timeline.isContent)

        await model.setSearch("helicopter")
        #expect(model.timelineRows.isEmpty)
        #expect(model.timeline.rendering == .empty)
        #expect(model.timeline.headline == SectionCopy.timelineNoMatches)
        #expect(model.timeline.detail?.contains("helicopter") == true, "the empty names what was searched for")
        #expect(model.timeline.actionTitle == SectionCopy.clearSearch)
        #expect(model.timeline.isWellFormed)

        await model.clearSearch()
        #expect(model.search.isEmpty)
        #expect(model.timelineRows.count == 2, "clearing the search is the way out of its own empty")
    }

    @Test("searching shows its own one-line loading state, and content is never shown beside it")
    func searchLoading() async {
        let store = StubStore(rows: [row("kept")])
        let model = today(reader: store)
        await model.reloadTimeline()
        let gate = Gate()
        store.gate = gate
        model.search = "kept"
        let running = Task { await model.reloadTimeline() }
        await Task.yield()
        #expect(model.timeline.rendering == .loading)
        #expect(model.timeline.headline == SectionCopy.timelineSearching)
        #expect(model.timeline.actionTitle == nil, "loading is one static line, never an action")
        #expect(model.timeline.isWellFormed)
        gate.open()
        await running.value
        #expect(model.timeline.isContent)
    }

    @Test("a superseded read cannot land on top of a newer one")
    func supersededReadCannotLand() async {
        let store = StubStore(rows: [row("first", id: "1"), row("second", id: "2")])
        let slow = Gate()
        store.gate = slow
        let model = today(reader: store)
        model.search = "first"
        let stale = Task { await model.reloadTimeline() }
        await Task.yield()
        // A second keystroke starts a newer read; let that one finish first.
        store.gate = nil
        await model.setSearch("second")
        #expect(model.timelineRows.map(\.id) == ["2"])
        slow.open()
        await stale.value
        #expect(model.timelineRows.map(\.id) == ["2"], "the first answer must not win")
        #expect(model.search == "second")
    }

    @Test("a search that fails says so and offers Try again; with rows on screen it is a banner")
    func searchFailure() async {
        let store = StubStore(rows: [row("kept")])
        let empty = today(reader: store)
        store.readFailure = StubStore.Boom()
        await empty.setSearch("kept")
        #expect(empty.timeline.rendering == .error)
        #expect(empty.timeline.headline == SectionCopy.timelineSearchFailed)
        #expect(empty.timeline.actionTitle == SectionCopy.tryAgain)
        #expect(empty.timeline.isWellFormed)

        let store2 = StubStore(rows: [row("kept")])
        let withRows = today(reader: store2)
        await withRows.reloadTimeline()
        #expect(withRows.timeline.isContent)
        store2.readFailure = StubStore.Boom()
        await withRows.setSearch("kept")
        #expect(withRows.timeline.isContent, "rows on screen do not vanish because a search failed")
        #expect(withRows.banner?.headline == SectionCopy.timelineSearchFailed)
        #expect(withRows.banner?.diagnostics != nil, "raw detail stays behind Copy diagnostics")
    }

    // MARK: - Source filters

    @Test("the filter row comes from the store's index, or from the rows when it keeps none")
    func filterRowSources() async {
        let derived = StubStore(rows: [row("a", source: "ambient"), row("b", source: "meeting")])
        let model = today(reader: derived)
        await model.reloadTimeline()
        #expect(model.availableSources.map(\.id) == ["ambient", "meeting"], "known sources keep DESIGN's order")

        let indexed = StubStore(rows: [row("a", source: "ambient")])
        indexed.storedSources = [.ambient, .dictation, .meeting]
        let withIndex = today(reader: indexed)
        await withIndex.reloadTimeline()
        #expect(withIndex.availableSources.map(\.id) == ["ambient", "dictation", "meeting"])

        // A source index that cannot be read is not an error: the filter row is not a claim about the
        // store, so it falls back to what the rows show and the section keeps its content.
        let broken = StubStore(rows: [row("a", source: "ambient")])
        broken.sourcesFailure = StubStore.Boom()
        let fallback = today(reader: broken)
        await fallback.reloadTimeline()
        #expect(fallback.timeline.isContent)
        #expect(fallback.availableSources.map(\.id) == ["ambient"])
    }

    @Test("filtering to one source keeps the other filters, and its empty offers Show everything")
    func sourceFilterEmpty() async {
        let store = StubStore(rows: [row("said aloud", source: "ambient"), row("dictated", source: "dictation")])
        let model = today(reader: store)
        await model.reloadTimeline()
        #expect(model.selectedSources.isEmpty)
        #expect(model.isSelected(source: "ambient") && model.isSelected(source: "dictation"),
                "an untouched filter row hides nothing")

        await model.toggle(source: "ambient")
        #expect(model.selectedSources == ["ambient"])
        #expect(model.timelineRows.map(\.text) == ["said aloud"])
        #expect(store.queries.last?.sources == ["ambient"], "the restriction goes to the store")
        #expect(model.availableSources.map(\.id) == ["ambient", "dictation"],
                "filtering to one source must not make the others disappear")

        // Nothing from the picked sources: its own empty, with its own way out.
        await model.toggle(source: "ambient")
        await model.toggle(source: "meeting")
        #expect(model.timelineRows.isEmpty)
        #expect(model.timeline.rendering == .empty)
        #expect(model.timeline.headline == SectionCopy.timelineNoMatchingSource)
        #expect(model.timeline.actionTitle == SectionCopy.showEverySource)
        #expect(model.timeline.isWellFormed)
        await model.showEverySource()
        #expect(model.selectedSources.isEmpty)
        #expect(model.timelineRows.count == 2)
    }

    @Test("ticking every source means everything, not a list that hides a source nobody ticked")
    func tickingEverySourceCollapses() async {
        let store = StubStore(rows: [row("a", source: "ambient"), row("b", source: "dictation")])
        let model = today(reader: store)
        await model.reloadTimeline()
        await model.toggle(source: "ambient")
        await model.toggle(source: "dictation")
        #expect(model.selectedSources.isEmpty)
        #expect(model.query.isEverySource)
        #expect(model.timelineRows.count == 2)
    }

    @Test("a store that only matches text still filters by source, through the protocol's default")
    func textOnlyStoreStillFilters() async {
        let store = TextOnlyStore([row("said aloud", source: "ambient"), row("dictated", source: "dictation")])
        let model = today(reader: store)
        await model.reloadTimeline()
        #expect(model.timelineRows.count == 2)
        await model.toggle(source: "dictation")
        #expect(model.timelineRows.map(\.text) == ["dictated"])
        #expect(model.availableSources.map(\.id) == ["ambient", "dictation"])
    }

    // MARK: - Delete

    @Test("delete goes through the store, and the row only leaves when the store says it is gone")
    func deleteGoesThroughTheStore() async {
        let store = StubStore(rows: [row("one", id: "1"), row("two", id: "2")])
        let model = today(reader: store)
        await model.reloadTimeline()

        await model.delete(rowID: "1")
        #expect(store.deleted == ["1"], "deletion is the store's path — the index clearing lives there")
        #expect(model.timelineRows.map(\.id) == ["2"])
        #expect(model.banner == nil)
        #expect(model.deletingRows.isEmpty)

        // Deleting the last row brings the explained empty back rather than a bare gap.
        await model.delete(rowID: "2")
        #expect(model.timelineRows.isEmpty)
        #expect(model.timeline.rendering == .empty)
        #expect(model.timeline.headline == SectionCopy.nothingDictated)
        #expect(model.timeline.isWellFormed)
    }

    @Test("a delete that throws keeps its row and says so; the section keeps its content")
    func deleteFailureKeepsRow() async {
        let store = StubStore(rows: [row("one", id: "1")])
        let model = today(reader: store)
        await model.reloadTimeline()
        store.deleteFailure = StubStore.Boom()
        await model.delete(rowID: "1")
        #expect(model.timelineRows.map(\.id) == ["1"], "a row whose delete failed is never dropped")
        #expect(model.banner?.headline == SectionCopy.timelineRowNotDeleted)
        #expect(model.banner?.diagnostics != nil)
        #expect(model.timeline.isContent)
        #expect(model.deletingRows.isEmpty)
    }

    @Test("a delete that returns success and deletes nothing is reported, not believed")
    func silentDeleteIsNotBelieved() async {
        let store = StubStore(rows: [row("one", id: "1")])
        store.deleteSilentlyDoesNothing = true
        let model = today(reader: store)
        await model.reloadTimeline()
        await model.delete(rowID: "1")
        #expect(store.deleted == ["1"])
        #expect(model.timelineRows.map(\.id) == ["1"])
        #expect(model.banner?.headline == SectionCopy.timelineRowStillThere,
                "the view reflects the store's answer, not the fact that the call returned")
        #expect(model.timeline.isContent)
    }

    @Test("no store: a delete cannot pretend to have happened")
    func deleteWithNoStore() async {
        let model = today(reader: nil)
        await model.delete(rowID: "1")
        #expect(model.banner?.headline == SectionCopy.timelineRowNotDeleted)
        await model.deleteEverything()
        #expect(model.banner?.headline == SectionCopy.deleteAllPartial)
    }

    // MARK: - Delete all

    @Test("delete-all asks first, says how much, and deletes nothing until it is confirmed")
    func deleteAllConfirmation() async {
        let store = StubStore(rows: [row("one", id: "1"), row("two", id: "2")])
        let model = today(reader: store)
        await model.reloadTimeline()

        model.askToDeleteEverything()
        let pending = try? #require(model.confirmation)
        #expect(pending?.deletesEverything == true)
        #expect(pending?.detail.contains("2") == true, "the sentence says how much will go")
        #expect(pending?.detail.contains("this Mac") == true)
        #expect(pending?.confirmTitle == SectionCopy.confirmDelete)
        #expect(pending?.cancelTitle == SectionCopy.cancel)
        #expect(pending?.isWellFormed == true)
        #expect(store.deleteAllCalls == 0, "nothing is deleted while the question is on screen")

        model.cancelConfirmation()
        #expect(model.confirmation == nil)
        #expect(store.deleteAllCalls == 0)
        #expect(model.timelineRows.count == 2)

        model.askToDeleteEverything()
        await model.confirm()
        #expect(store.deleteAllCalls == 1)
        #expect(model.confirmation == nil)
        #expect(model.timelineRows.isEmpty)
        #expect(model.timeline.rendering == .empty)
        #expect(model.timeline.headline == SectionCopy.nothingDictated)
    }

    @Test("delete-all that leaves something behind says 'Some of it is still here'")
    func deleteAllPartial() async {
        let store = StubStore(rows: [row("one", id: "1")])
        store.deleteSilentlyDoesNothing = true
        let model = today(reader: store)
        await model.reloadTimeline()
        model.askToDeleteEverything()
        await model.confirm()
        #expect(model.timelineRows.count == 1)
        #expect(model.banner?.headline == SectionCopy.deleteAllPartial)
        #expect(model.banner?.actionTitle == RecoveryCatalog.entry(.S04).action)   // S11: "Retry deletion"

        let thrower = StubStore(rows: [row("one", id: "1")])
        thrower.deleteFailure = StubStore.Boom()
        let failing = today(reader: thrower)
        await failing.reloadTimeline()
        await failing.deleteEverything()
        #expect(failing.timelineRows.count == 1)
        #expect(failing.banner?.headline == SectionCopy.deleteAllPartial)
        #expect(failing.banner?.diagnostics != nil)
    }

    @Test("a row confirmation names the row by its first words, and confirming deletes that row")
    func rowConfirmation() async {
        let long = String(repeating: "a sentence that runs on ", count: 6)
        let store = StubStore(rows: [row(long, id: "1"), row("two", id: "2")])
        let model = today(reader: store)
        await model.reloadTimeline()
        model.askToDelete(rowID: "1")
        let pending = try? #require(model.confirmation)
        #expect(pending?.rowID == "1")
        #expect(pending?.isWellFormed == true)
        #expect((pending?.detail.count ?? 0) < long.count, "a dialog shows an excerpt, not the transcript")
        await model.confirm()
        #expect(store.deleted == ["1"])
        #expect(model.timelineRows.map(\.id) == ["2"])

        // A row that is no longer on screen cannot be queued for deletion at all.
        model.askToDelete(rowID: "gone")
        #expect(model.confirmation == nil)
    }

    // MARK: - Grouping, states, copy

    @Test("rows are grouped by day, newest day first, newest row first inside the day")
    func grouping() async {
        let cal = Calendar.current
        // Noon today, so "an hour ago" is still today when the suite runs between 00:00 and 01:00.
        let now = cal.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        let rows = [
            TimelineRow(id: "old", time: cal.date(byAdding: .day, value: -2, to: now)!, source: "ambient", text: "old"),
            TimelineRow(id: "early", time: now.addingTimeInterval(-3600), source: "ambient", text: "early"),
            TimelineRow(id: "late", time: now.addingTimeInterval(-60), source: "ambient", text: "late"),
            TimelineRow(id: "yesterday", time: cal.date(byAdding: .day, value: -1, to: now)!, source: "ambient", text: "yesterday"),
        ]
        let days = TimelineDay.group(rows, calendar: cal, now: now)
        #expect(days.count == 3)
        #expect(days.first?.title == "Today")
        #expect(days.first?.rows.map(\.id) == ["late", "early"])
        #expect(days[1].title == "Yesterday")
        #expect(days[2].title != "Today" && days[2].title != "Yesterday", "older days are dated, not counted")
        #expect(days.map(\.id).count == Set(days.map(\.id)).count)

        let store = StubStore(rows: rows)
        let model = today(reader: store)
        await model.reloadTimeline()
        #expect(model.timelineDays.count == 3)
    }

    @Test("ambient on with no store says the store isn't running, not 'turn ambient on'")
    func storeMissingIsItsOwnState() async {
        let model = today(ambient: true, reader: nil)
        await model.reloadTimeline()
        #expect(model.timeline.rendering == .error)
        #expect(model.timeline.headline == SectionCopy.timelineStoreMissing)
        #expect(model.timeline.detail == SectionCopy.timelineStoreMissingDetail)
        // S11: S01's own action, scoped — never a claim that the Timeline is off.
        #expect(model.timeline.actionTitle == RecoveryCatalog.entry(.S01).action)
        #expect(model.timeline.recoveryID == .S01)
        #expect(model.timeline.isWellFormed)

        let off = today(ambient: false, reader: nil)
        await off.reloadTimeline()
        #expect(off.timeline.headline == SectionCopy.timelineOff)
        #expect(off.timeline.isWellFormed)
    }

    @Test("every state search, filters and deletion can produce is well formed")
    func everyTimelineStateIsWellFormed() async {
        var states: [SectionState] = []
        let store = StubStore(rows: [row("kept", source: "ambient")])
        let model = today(reader: store)
        states.append(model.timeline)                     // loading, before any read
        await model.reloadTimeline()
        states.append(model.timeline)                     // content
        await model.setSearch("nothing like it")
        states.append(model.timeline)                     // empty — no matches
        await model.clearSearch()
        await model.toggle(source: "meeting")
        states.append(model.timeline)                     // empty — no matching source
        await model.showEverySource()
        model.askToDeleteEverything()
        await model.confirm()
        states.append(model.timeline)                     // empty — nothing dictated
        store.readFailure = StubStore.Boom()
        await model.reloadTimeline()
        states.append(model.timeline)                     // error — unreadable
        await model.setSearch("kept")
        states.append(model.timeline)                     // error — search failed
        states.append(today(ambient: true, reader: nil).timeline)

        for state in states { #expect(state.isWellFormed, "\(state.rendering): \(state.headline)") }
        #expect(Set(states.map(\.rendering)) == Set(SectionRendering.allCases))
    }

    @Test("the privacy line says what is captured, saved and transmitted, and never claims zero bytes")
    func privacyCopy() {
        let settings = InMemorySettingsStore()
        AmbientRetentionSettings.setDays(7, store: settings)
        let model = today(reader: nil, settings: settings)
        let note = model.timelinePrivacyNote
        #expect(note.contains("transcript only"), "what is captured")
        #expect(note.contains("this Mac"), "where it is saved")
        #expect(note.contains("network"), "what is transmitted")
        #expect(note.contains("7 days"), "and how long it is kept")
        for forbidden in ["zero bytes", "no network", "never leaves", "nothing ever leaves"] {
            #expect(!note.lowercased().contains(forbidden), "V3 §9.6: never claim literal zero network bytes")
        }
    }

    @Test("V3 §4.7: the Timeline the window shows is the ambient one, and no copy renames it")
    func namingRule() {
        // Every user-facing Timeline sentence is about ambient transcript history.
        #expect(SectionCopy.timelineStoreMissingDetail.contains("Ambient capture"))
        #expect(SectionCopy.timelinePrivacy.contains("Ambient capture"))
        // The sources the filter row can name, in DESIGN's order, each with a word of its own.
        #expect(TimelineSource.known.map(\.id) == ["ambient", "dictation", "meeting"])
        for source in TimelineSource.known { #expect(!source.label.isEmpty) }
        // A source from a future build is shown and filtered on, never dropped.
        let future = TimelineSource.named("huddle")
        #expect(future.id == "huddle")
        #expect(future.label == "Huddle")
        #expect(TimelineQuery(text: "", sources: ["huddle"]).matches(row("x", source: "huddle")))
    }
}
