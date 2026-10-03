import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// H25 — one outcome type drives the pill, Today, the menu, the turn detail and Recent (§2 strings).
@Suite("Turn outcome (H25)")
struct OutcomeTurnTests {
    /// §2 "Exact text", one row per situation.
    static let expected: [(TurnOutcome, String)] = [
        (.inserted(app: "Claude"), "Inserted in Claude"),
        (.replacedSelection(app: "Claude"), "Replaced selection in Claude"),
        (.edited(action: "Shortened selection", app: "Claude"), "Shortened selection in Claude"),
        (.edited(action: "Made a bulleted list", app: "Notes"), "Made a bulleted list in Notes"),
        (.actionDone(action: "Undo", app: "Mail"), "Undo done in Mail"),
        (.savedToNotes(intendedApp: "Claude", reason: .noTextField), "Saved to Notes · no text field"),
        (.savedToNotes(intendedApp: "Claude", reason: .windowClosed), "Saved to Notes · Claude window closed"),
        (.savedToNotes(intendedApp: "Claude", reason: .couldNotReturn), "Saved to Notes · couldn’t return to Claude"),
        (.savedToNotes(intendedApp: "Claude", reason: .editFailed), "Couldn’t edit the selection · Saved to Notes"),
        (.cancelledToNotes(intendedApp: "Claude"), "Cancelled · Saved to Notes"),
        (.cancelled, "Cancelled · nothing typed"),
        (.refusedSecure, "Not typed · password field"),
        (.nothingHeard, "Didn’t hear anything · Nothing was typed."),
        (.notesSaveFailed(intendedApp: "Claude"), "Couldn’t save to Notes"),
        (.handsFreeSegment(app: "Slack"), "Inserted in Slack"),
        (.handsFreeEnded(app: "Slack", inserted: 3, savedToNotes: 0), "Hands-free ended · 3 inserted in Slack"),
        (.handsFreeEnded(app: "Slack", inserted: 3, savedToNotes: 1),
         "Hands-free ended · 3 inserted in Slack · 1 saved to Notes"),
    ]

    @Test("every §2 string, on every surface", arguments: OutcomeSurface.allCases)
    func everyStringEverySurface(_ surface: OutcomeSurface) {
        for (outcome, text) in Self.expected {
            let want: String
            switch surface {
            case .menu: want = "Last: " + text
            case .pill where outcome == .nothingHeard: want = "Didn’t hear anything"
            default: want = text
            }
            #expect(outcome.line(on: surface) == want, "\(surface) \(outcome)")
        }
    }

    @Test("named accessors match the surfaces")
    func accessors() {
        let o = TurnOutcome.savedToNotes(intendedApp: "Claude", reason: .windowClosed)
        #expect(o.pillLine == o.line(on: .pill))
        #expect(o.todayLine == o.line(on: .today))
        #expect(o.menuLine == o.line(on: .menu))
        #expect(o.turnDetailLine == o.line(on: .turnDetail))
        #expect(o.recentLine == o.line(on: .recent))
    }

    @Test("no app known: the line drops the app, never says 'in nil'")
    func noApp() {
        #expect(TurnOutcome.inserted(app: nil).text == "Inserted")
        #expect(TurnOutcome.inserted(app: "  ").text == "Inserted")
        #expect(TurnOutcome.savedToNotes(intendedApp: nil, reason: .windowClosed).text == "Saved to Notes · window closed")
        #expect(TurnOutcome.savedToNotes(intendedApp: nil, reason: .couldNotReturn).text
            == "Saved to Notes · couldn’t return to the app")
    }

    @Test("Copy goes only with a failed Notes save; Notes flag and secure flag")
    func flags() {
        #expect(TurnOutcome.notesSaveFailed(intendedApp: nil).offersCopy)
        #expect(!TurnOutcome.inserted(app: "Mail").offersCopy)
        #expect(TurnOutcome.cancelledToNotes(intendedApp: nil).savedToNotes)
        #expect(TurnOutcome.handsFreeEnded(app: nil, inserted: 1, savedToNotes: 2).savedToNotes)
        #expect(!TurnOutcome.handsFreeEnded(app: nil, inserted: 1, savedToNotes: 0).savedToNotes)
        #expect(TurnOutcome.refusedSecure.isSecureRefusal)
    }

    @Test("every outcome round-trips through the generic extras keys")
    func roundTrip() {
        let all: [TurnOutcome] = Self.expected.map(\.0) + [
            .unconfirmed(app: "Mail"), .partial(app: "Mail"), .undone(app: "Mail"), .notTyped(app: "Mail"),
            .inProgress(app: "Mail"), .savedToNotes(intendedApp: "Mail", reason: .otherVoice),
        ]
        for outcome in all {
            var extras = TurnRecordExtras()
            outcome.write(into: &extras)
            #expect(TurnOutcome.recorded(in: extras) == outcome, "\(outcome)")
            #expect(extras.recordedOutcome == outcome)
        }
    }

    @Test("extras without outcome keys still decode (pre-H25 rows)")
    func legacyExtras() throws {
        let old = #"{"fieldRole":"AXTextArea"}"#
        let extras = try JSONDecoder().decode(TurnRecordExtras.self, from: Data(old.utf8))
        #expect(extras.outcomeKind == nil && extras.recordedOutcome == nil)
    }

    // MARK: Derivation from a turn

    static func entry(_ stage: TurnStage, outcome: DeliveryOutcome? = nil, app: String? = "Mail",
                      extras: TurnRecordExtras = TurnRecordExtras()) -> TurnEntry {
        var record = TurnRecord(turnID: TurnID(), startedAt: Date(timeIntervalSinceReferenceDate: 700_000_000),
                                destination: .init(bundleID: "com.apple.mail", appName: app),
                                rawText: "hi", finalText: "hi")
        record.outcome = outcome
        return TurnEntry(record: record, stage: stage, updatedAt: record.startedAt, persisted: false, extras: extras)
    }

    @Test("derived from stage and delivery when no producer recorded one")
    func derived() {
        #expect(Self.entry(.landed, outcome: .delivered(verified: true, method: "ax")).turnOutcome == .inserted(app: "Mail"))
        #expect(Self.entry(.landed, outcome: .delivered(verified: false, method: "ax")).turnOutcome == .unconfirmed(app: "Mail"))
        #expect(Self.entry(.landed, outcome: .partial(method: "keystroke")).turnOutcome == .partial(app: "Mail"))
        #expect(Self.entry(.failed, outcome: .failed(reason: "secure field")).turnOutcome == .refusedSecure)
        #expect(Self.entry(.failed, outcome: .failed(reason: "every method threw")).turnOutcome == .notTyped(app: "Mail"))
        #expect(Self.entry(.held, outcome: .held(reason: "destination changed")).turnOutcome == .notTyped(app: "Mail"))
        #expect(Self.entry(.resolved, outcome: .delivered(verified: true, method: "ax")).turnOutcome == .undone(app: "Mail"))
        #expect(Self.entry(.cancelled).turnOutcome == .cancelled)
        #expect(Self.entry(.empty).turnOutcome == .nothingHeard)
        #expect(Self.entry(.inserting).turnOutcome == .inProgress(app: "Mail"))
    }

    @Test("a recorded outcome wins over the derived one; app falls back to the destination")
    func recordedWins() {
        var extras = TurnRecordExtras()
        extras.outcomeKind = TurnOutcome.Kind.savedToNotes.rawValue
        extras.outcomeReason = NoteReason.windowClosed.rawValue
        let entry = Self.entry(.failed, outcome: .failed(reason: "no destination"), app: "Claude", extras: extras)
        #expect(entry.turnOutcome == .savedToNotes(intendedApp: "Claude", reason: .windowClosed))
        #expect(entry.turnOutcome.todayLine == "Saved to Notes · Claude window closed")
    }

    // MARK: Surfaces read the one type

    @Test("pill copy reads TurnOutcome")
    func pillSurface() {
        #expect(PillDeck.insertedStatus(destination: "Mail") == "✓ " + TurnOutcome.inserted(app: "Mail").pillLine)
        #expect(PillDeck.insertedUnreadableStatus(destination: "Mail") == TurnOutcome.inserted(app: "Mail").pillLine)
        #expect(PillDeck.didntHearAnything == TurnOutcome.nothingHeard.pillLine)
        let notes = TurnOutcome.savedToNotes(intendedApp: "Claude", reason: .noTextField)
        #expect(PillDeck.outcomeStatus(notes) == "Saved to Notes · no text field")
    }

    @Test("Today row carries the turn's outcome line")
    func todaySurface() throws {
        var extras = TurnRecordExtras()
        TurnOutcome.savedToNotes(intendedApp: "Claude", reason: .couldNotReturn).write(into: &extras)
        let row = try #require(TodayTurnRow(Self.entry(.failed, outcome: .failed(reason: "x"), app: "Claude", extras: extras)))
        #expect(row.outcomeLine == "Saved to Notes · couldn’t return to Claude")
        let landed = try #require(TodayTurnRow(Self.entry(.landed, outcome: .delivered(verified: true, method: "ax"))))
        #expect(landed.outcomeLine == "Inserted in Mail")
    }

    // MARK: Recent (menu)

    static func save(_ store: TurnStore, _ text: String, at s: TimeInterval, stage: TurnStage = .landed,
                     outcome: DeliveryOutcome? = .delivered(verified: true, method: "ax"), secure: Bool = false,
                     _ extras: (inout TurnRecordExtras) -> Void = { _ in }) -> TurnID {
        var record = TurnRecord(turnID: TurnID(), startedAt: Date(timeIntervalSinceReferenceDate: 700_000_000 + s),
                                destination: .init(bundleID: "com.anthropic.claude", appName: "Claude", isSecure: secure),
                                rawText: text, finalText: text)
        record.outcome = outcome
        store.save(record, stage: stage)
        store.setExtras(record.turnID, save: false, extras)
        return record.turnID
    }

    @Test("Recent: newest first, any destination, at most 5")
    func recentLimit() {
        let store = TurnStore(database: nil)
        for i in 0..<7 { _ = Self.save(store, "line \(i)", at: Double(i)) }
        _ = Self.save(store, "to notes", at: 10, stage: .failed, outcome: .failed(reason: "no destination")) {
            TurnOutcome.savedToNotes(intendedApp: "Claude", reason: .noTextField).write(into: &$0)
        }
        let rows = store.recentDictations(limit: 5)
        #expect(rows.count == 5)
        #expect(rows.first?.text == "to notes")
        #expect(rows.first?.outcome.recentLine == "Saved to Notes · no text field")
        #expect(rows.map(\.text) == ["to notes", "line 6", "line 5", "line 4", "line 3"])
    }

    @Test("Recent never lists a password-field turn (by outcome reason, not key-down isSecure)")
    func recentSecure() {
        let store = TurnStore(database: nil)
        _ = Self.save(store, "hunter2", at: 1, stage: .failed, outcome: .failed(reason: "secure field"))
        _ = Self.save(store, "refused", at: 2, stage: .failed, outcome: nil) {
            TurnOutcome.refusedSecure.write(into: &$0)
        }
        // A key-down secure snapshot whose words actually landed in a normal field is listed.
        _ = Self.save(store, "landed fine", at: 3, secure: true)
        #expect(store.recentDictations().map(\.text) == ["landed fine"])
    }

    @Test("Recent: a hands-free session is one row; edit commands read 'Edit · <command>'")
    func recentSessionAndEdit() {
        let store = TurnStore(database: nil)
        for i in 0..<6 { _ = Self.save(store, "piece\(i)", at: Double(i)) { $0.handsFreeSessionID = "S1" } }
        _ = Self.save(store, "Dear team, …", at: 10) {
            $0.editCommand = "Make this formal"
            TurnOutcome.edited(action: "Made formal", app: "Claude").write(into: &$0)
        }
        _ = Self.save(store, "", at: 11, stage: .empty, outcome: nil)
        let rows = store.recentDictations()
        #expect(rows.count == 2)
        #expect(rows[0].line == "Edit · Make this formal")
        #expect(rows[0].text == "Dear team, …")
        #expect(rows[1].text == "piece0 piece1 piece2 piece3 piece4 piece5")
    }

    @Test("menu Copy is verified (write, then read back)")
    func copyVerified() {
        final class Board: TodayPasteboard {
            var stored: String?
            var lies = false
            func write(_ text: String) -> Bool { stored = lies ? "other" : text; return true }
            func read() -> String? { stored }
        }
        let board = Board()
        #expect(TodayServices.copyVerified("hello", pasteboard: board))
        board.lies = true
        #expect(!TodayServices.copyVerified("hello", pasteboard: board))
    }
}
