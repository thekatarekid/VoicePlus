import Foundation
import Injection
import Shared
import Testing
@testable import VoicePlusApp

/// H23 verify — with the held queue retired, a `.held` landing on the delivery pill shows where the
/// words went (Notes) instead of a held row with Needs you; secure keeps nothing; a failed save keeps
/// the legacy row (Copy). Uses a private `HeldNotesRoute` (never the shared one).
@Suite("H23 held landing → Notes on the pill")
@MainActor
struct NotesHeldPillRouteTests {
    final class Sink: @unchecked Sendable {
        var saved: [(text: String, app: String?, reason: NoteReason)] = []
        var fails = false
        func save(_ text: String, _ app: String?, _ reason: NoteReason) -> Result<String, NotesFunnelError> {
            if fails { return .failure(.writeFailed("disk")) }
            saved.append((text, app, reason))
            return .success("n\(saved.count)")
        }
    }

    private func driver(_ route: HeldNotesRoute) -> DeliveryPillDriver {
        let driver = DeliveryPillDriver(pill: PillViewModel())
        driver.notesRoute = { route.route(text: $0, destination: $1, reason: $2) }
        return driver
    }

    @Test func holdSavedByFocusGuardShowsNotesLineWithoutSecondSave() {
        let sink = Sink(), route = HeldNotesRoute()
        route.install(save: sink.save)
        route.noted("hello there", .savedToNotes(intendedApp: "Claude", reason: .windowClosed))
        let d = driver(route)
        let state = d.handle(.held(reason: "window closed"), text: "hello there", destination: "Claude")
        #expect(state == .preview(text: TurnOutcome.savedToNotes(intendedApp: "Claude", reason: .windowClosed).pillLine))
        #expect(sink.saved.isEmpty)
        #expect(d.held.items.isEmpty)
    }

    @Test func holdThatNeverReachedFocusGuardIsSavedOnce() {
        let sink = Sink(), route = HeldNotesRoute()
        route.install(save: sink.save)
        let d = driver(route)
        _ = d.handle(.held(reason: "selection changed"), text: "fix this", destination: "Notes")
        #expect(sink.saved.count == 1)
        #expect(sink.saved.first?.reason == .editFailed)
        #expect(d.held.items.isEmpty)
    }

    @Test func passwordFieldKeepsNothing() {
        let sink = Sink(), route = HeldNotesRoute()
        route.install(save: sink.save)
        let d = driver(route)
        let state = d.handle(.held(reason: DeliveryReason.secureField), text: "hunter2", destination: "Safari")
        #expect(state == .preview(text: TurnOutcome.refusedSecure.pillLine))
        #expect(sink.saved.isEmpty && d.held.items.isEmpty)
    }

    @Test func failedSaveKeepsLegacyRowWithCopy() {
        let sink = Sink(), route = HeldNotesRoute()
        sink.fails = true
        route.install(save: sink.save)
        let d = driver(route)
        let state = d.handle(.held(reason: "window closed"), text: "keep me", destination: "Mail")
        if case .held = state {} else { Issue.record("expected the held row, got \(state)") }
        #expect(d.held.items.count == 1)
    }

    @Test func noRouteInstalledKeepsLegacyRow() {
        let d = driver(HeldNotesRoute())
        let state = d.handle(.held(reason: "window closed"), text: "x", destination: "Mail")
        if case .held = state {} else { Issue.record("expected the held row, got \(state)") }
    }

    @Test func keptByUserIsCancelledToNotes() {
        #expect(NoteReason.forHeld(reason: DeliveryReason.keptByUser) == .cancelled)
        let sink = Sink(), route = HeldNotesRoute()
        route.install(save: sink.save)
        #expect(route.route(text: "words", destination: "Mail", reason: DeliveryReason.keptByUser)
                == .cancelledToNotes(intendedApp: "Mail"))
    }
}
