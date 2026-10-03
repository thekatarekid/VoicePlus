import Engine
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// H24 — every note carries the app the words were meant for and why they are in Notes.
@Suite("Notes intended app + reason (H24)")
struct NotesReasonTests {
    static let now = Date(timeIntervalSince1970: 1_700_000_000)

    static func makeStore() throws -> (NotesStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("h24-\(UUID().uuidString)", isDirectory: true)
        let store = NotesStore(root: root, database: try AppDatabase.inMemory(), clock: { now })
        return (store, root)
    }

    @Test("a note stores intended app + reason and reads 'Not typed in <App> · <why>'")
    func storesAndShows() throws {
        let (store, root) = try Self.makeStore(); defer { try? FileManager.default.removeItem(at: root) }
        let result = NotesFunnel.save(text: "ship it friday", intendedApp: "Claude", reason: .windowClosed,
                                      at: Self.now, store: store)
        let id = try result.get()
        let note = try #require(store.notes().first { $0.id == id })
        #expect(note.intendedApp == "Claude")
        #expect(note.reason == .windowClosed)
        #expect(note.source == .notTyped)
        #expect(note.reasonLine == "Not typed in Claude · window closed")
    }

    @Test("every reason has a row line, with and without an app", arguments: NoteReason.allCases)
    func everyReasonLine(_ reason: NoteReason) {
        let withApp = reason.noteLine(intendedApp: "Mail")
        let without = reason.noteLine(intendedApp: nil)
        #expect(withApp.hasSuffix(" · " + reason.why))
        #expect(without.hasSuffix(" · " + reason.why))
        if reason.isIntentional {
            #expect(withApp == "Saved to Notes · " + reason.why)
        } else {
            #expect(withApp == "Not typed in Mail · " + reason.why)
            #expect(without == "Not typed · " + reason.why)
        }
    }

    @Test("§2 examples")
    func examples() {
        #expect(NoteReason.windowClosed.noteLine(intendedApp: "Claude") == "Not typed in Claude · window closed")
        #expect(NoteReason.noTextField.noteLine(intendedApp: "Finder") == "Not typed in Finder · no text field")
        #expect(NoteReason.cancelled.noteLine(intendedApp: "Slack") == "Not typed in Slack · cancelled")
    }

    @Test("migration: a pre-H24 note (no metadata) reads its source's reason")
    func legacyNote() throws {
        let (store, root) = try Self.makeStore(); defer { try? FileManager.default.removeItem(at: root) }
        // Written the old way: no intended app, no reason, no metadata file.
        let id = try #require(try store.add("old words", source: .noField, at: Self.now))
        let dir = store.meetings.directory(for: AmbientTranscriptStore.recordID(ofEntry: id))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(NotesStore.metaFile).path))
        let note = try #require(store.notes().first)
        #expect(note.reason == nil && note.intendedApp == nil)
        #expect(note.effectiveReason == .noTextField)
        #expect(note.reasonLine == "Not typed · no text field")
        for source in NoteSource.allCases where source != .ambient && source != .notTyped {
            #expect(source.defaultReason != nil, "\(source)")
        }
        #expect(NoteSource.ambient.defaultReason == nil)
    }

    @Test("reasons file under a stable source; the funnel's reason survives a reload")
    func sourceMapping() throws {
        let (store, root) = try Self.makeStore(); defer { try? FileManager.default.removeItem(at: root) }
        for (i, reason) in NoteReason.allCases.enumerated() {
            _ = try NotesFunnel.save(text: "w\(i)", intendedApp: "App\(i)", reason: reason,
                                     at: Self.now.addingTimeInterval(Double(i)), store: store).get()
        }
        let reopened = NotesStore(root: root, database: nil, clock: { Self.now })
        let notes = reopened.notes()
        #expect(notes.count == NoteReason.allCases.count)
        for (i, reason) in NoteReason.allCases.enumerated() {
            let n = try #require(notes.first { $0.text == "w\(i)" })
            #expect(n.reason == reason && n.intendedApp == "App\(i)")
            #expect(n.source == NoteSource.of(reason))
        }
    }

    @Test("deleting a note drops its metadata; the rest keep theirs")
    func deleteKeepsOthers() throws {
        let (store, root) = try Self.makeStore(); defer { try? FileManager.default.removeItem(at: root) }
        let a = try NotesFunnel.save(text: "a", intendedApp: "Mail", reason: .couldNotReturn, at: Self.now, store: store).get()
        let b = try NotesFunnel.save(text: "b", intendedApp: "Notes", reason: .editFailed,
                                     at: Self.now.addingTimeInterval(1), store: store).get()
        try store.delete(id: a)
        let meta = store.loadMeta(AmbientTranscriptStore.recordID(ofEntry: b))
        #expect(meta[a] == nil)
        #expect(meta[b]?.intendedApp == "Notes")
        #expect(store.notes().map(\.reasonLine) == ["Not typed in Notes · couldn’t edit the selection"])
    }

    @Test("funnel failures: no store, empty text; outcome mapping")
    func funnelFailures() throws {
        let (store, root) = try Self.makeStore(); defer { try? FileManager.default.removeItem(at: root) }
        let empty = NotesFunnel.save(text: "  ", intendedApp: "Mail", reason: .noTextField, store: store)
        #expect(empty == .failure(.emptyText))
        #expect(NotesFunnel.outcome(of: empty, intendedApp: "Mail", reason: .noTextField) == .notesSaveFailed(intendedApp: "Mail"))
        #expect(NotesFunnel.outcome(of: .success("x"), intendedApp: "Mail", reason: .cancelled) == .cancelledToNotes(intendedApp: "Mail"))
        #expect(NotesFunnel.outcome(of: .success("x"), intendedApp: "Mail", reason: .windowClosed).pillLine
            == "Saved to Notes · Mail window closed")
        // A write that cannot happen (the root is a file) is a failure, not a lost note.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("h24-file-\(UUID().uuidString)")
        try Data("x".utf8).write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        let broken = NotesStore(root: file, database: nil, clock: { Self.now })
        let failed = NotesFunnel.save(text: "words", intendedApp: "Mail", reason: .noTextField, store: broken)
        if case .failure(.writeFailed) = failed {} else { Issue.record("expected writeFailed, got \(failed)") }
    }

    @Test("the router stores the intended app and the source's reason")
    func routerCarriesApp() throws {
        let (store, root) = try Self.makeStore(); defer { try? FileManager.default.removeItem(at: root) }
        let router = NotesRouter(store: store)
        router.route("no field here", signals: NotesRouteSignals(hasFocusedField: false, intendedApp: "Finder"), at: Self.now)
        let note = try #require(store.notes().first)
        #expect(note.intendedApp == "Finder" && note.reason == .noTextField)
        #expect(note.reasonLine == "Not typed in Finder · no text field")
    }
}
