import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// V5 K19 — a timed outcome row can never outlive its dwell: every one gets a hard deadline when
/// shown (release + `PillRetention.slack`), and the backstop takes it down with a diagnostics event.
/// The live Timer firing is not exercised; tests drive `enforceRetention()` with an advanced clock.
@Suite("Pill retention backstop (V5 K19)", .serialized)
@MainActor
struct PillRetentionK19Tests {
    static let t0 = Date(timeIntervalSince1970: 90_000)

    final class Clock { var now = PillRetentionK19Tests.t0 }

    @Test func onlyTimedOutcomeRowsAreOwned() {
        #expect(PillRetention.applies(to: .landed(LandedPillInfo(text: "hi", verified: true))))
        #expect(PillRetention.applies(to: .cancelled))
        #expect(PillRetention.applies(to: .undoAvailable))
        // N22 — the ⚠ Done rows (D06 unconfirmed, partial) are timed too now.
        #expect(PillRetention.applies(to: .landed(LandedPillInfo(text: "hi", verified: false))))
        #expect(PillRetention.applies(to: .landedPartial(text: "hi")))
        #expect(!PillRetention.applies(to: .landing))
        #expect(!PillRetention.applies(to: .finishing(elapsedWarning: false)))
        #expect(!PillRetention.applies(to: .listening(level: 0)))
    }

    @Test func deadlineIsReleasePlusSlack() throws {
        let landed = PillState.landed(LandedPillInfo(text: "hi", verified: true))
        let d = try #require(PillRetention.deadline(for: landed, shownAt: Self.t0, release: nil))
        #expect(d == Self.t0.addingTimeInterval(PillDwell.inserted + PillRetention.slack))
        // A finite flight hold pushes the release, and the deadline with it.
        let later = Self.t0.addingTimeInterval(2)
        #expect(PillRetention.deadline(for: landed, shownAt: Self.t0, release: later) == later.addingTimeInterval(PillRetention.slack))
        #expect(PillRetention.deadline(for: .held(HeldPillInfo(text: "x", destination: "Mail", reason: "focus")), shownAt: Self.t0, release: nil) == nil)
    }

    @Test func aLandedRowNothingRetractedComesDownAtItsDeadline() {
        let clock = Clock()
        let model = PillViewModel()
        model.now = { clock.now }
        var events: [TurnDiagnosticsEvent] = []
        PillDiagnostics.observer = { events.append($0) }
        defer { PillDiagnostics.observer = nil }
        model.apply(.starting)
        // Shown through the generic path (no delivery timer is armed here — the K19 shape).
        model.present(.landed(LandedPillInfo(text: "hello", verified: true)))
        #expect(model.state.isVisible)
        #expect(model.retentionDeadline != nil)
        // Before the deadline the backstop does nothing.
        clock.now = Self.t0.addingTimeInterval(PillDwell.inserted + 0.5)
        #expect(!model.enforceRetention())
        #expect(model.state.isVisible)
        // ~27 s later (the reported symptom) it is long gone; at the deadline it retracts.
        clock.now = Self.t0.addingTimeInterval(PillDwell.inserted + PillRetention.slack + 0.01)
        #expect(model.enforceRetention())
        #expect(!model.state.isVisible)
        #expect(events.contains(.orderOut(window: "pill", reason: "retentionBackstop:inserted")))
    }

    /// N22 — an unconfirmed row is the Done face with a ⚠: it clears on its own after the notice
    /// dwell, and the backstop owns it like any other timed row.
    @Test func anUnconfirmedRowClearsOnItsOwn() {
        let clock = Clock()
        let model = PillViewModel()
        model.now = { clock.now }
        model.apply(.starting)
        model.present(.landed(LandedPillInfo(text: "hello", verified: false)))
        #expect(model.retentionDeadline != nil)
        clock.now = Self.t0.addingTimeInterval(60)
        #expect(model.enforceRetention())
        #expect(!model.state.isVisible)
    }

    @Test func aNewRowReplacesTheDeadline() {
        let clock = Clock()
        let model = PillViewModel()
        model.now = { clock.now }
        model.apply(.starting)
        model.present(.landed(LandedPillInfo(text: "hello", verified: true)))
        model.apply(.starting)
        #expect(model.retentionDeadline == nil)
        clock.now = Self.t0.addingTimeInterval(30)
        #expect(!model.enforceRetention())
        #expect(model.state == .starting)
    }
}
