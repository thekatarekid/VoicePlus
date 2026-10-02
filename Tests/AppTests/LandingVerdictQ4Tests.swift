import Foundation
import Injection
import Shared
import Testing
@testable import VoicePlusApp

/// V5 Q4 — a field whose readback cannot run lands as a neutral "Inserted in <app>" (no ✓) that clears
/// after the normal landed dwell; only a readback that ran and showed nothing is the sticky D06 warning.
@Suite("Q4 · neutral landing for unreadable fields")
struct LandingVerdictQ4Tests {
    static let t0 = Date(timeIntervalSince1970: 2_000)
    static func context(_ destination: String? = "Slack") -> PillTurnContext {
        PillTurnContext(keyLabel: "fn / 🌐", destination: destination, startedAt: t0, now: t0.addingTimeInterval(3),
                        liveText: "hello there", captureOpen: false)
    }

    @Test func readbackVerdictMapsToLandingVerdict() {
        #expect(LandingVerdict(readback: .confirmed) == .confirmed)
        #expect(LandingVerdict(readback: .unconfirmed) == .unconfirmed)
        #expect(LandingVerdict(readback: .unavailable) == .unreadable)
        #expect(LandingVerdict.allCases.filter(\.isSticky) == [.unconfirmed])
    }

    @Test func verdictToCopyMapping() {
        let c = Self.context()
        let verified = PillContent.make(.landed(LandedPillInfo(text: "hi", verdict: .confirmed)), context: c)
        #expect(verified.status == "✓ Inserted in Slack" && !verified.notice && verified.designKey == "inserted")

        let unreadable = PillContent.make(.landed(LandedPillInfo(text: "hi", verdict: .unreadable)), context: c)
        #expect(unreadable.status == "Inserted in Slack")
        #expect(!unreadable.status.contains("✓") && !unreadable.status.contains("⚠"))
        #expect(!unreadable.notice && unreadable.buttons.isEmpty && unreadable.designKey == "inserted")

        let unconfirmed = PillContent.make(.landed(LandedPillInfo(text: "hi", verdict: .unconfirmed)), context: c)
        #expect(unconfirmed.status == "⚠ Couldn’t confirm insertion" && unconfirmed.notice)
        #expect(unconfirmed.designKey == "unconfirmed" && !unconfirmed.buttons.isEmpty)

        let noDestination = PillContent.make(.landed(LandedPillInfo(text: "hi", verdict: .unreadable)),
                                             context: Self.context(nil))
        #expect(noDestination.status == "Inserted")
    }

    @Test func onlyUnconfirmedIsSticky() {
        for verdict in LandingVerdict.allCases {
            let state = PillState.landed(LandedPillInfo(text: "hi", verdict: verdict))
            let rule = PillDwell.rule(for: state)
            if verdict == .unconfirmed {
                // N22 — the ⚠ Done row clears on its own too, after the longer notice dwell.
                #expect(rule == .minimum(PillDwell.transientNotice))
                #expect(!PillDwell.staysUntilAction(state))
            } else {
                #expect(rule == .minimum(PillDwell.inserted), "\(verdict)")
                #expect(!PillDwell.staysUntilAction(state))
            }
            #expect(state.designStateKey == (verdict == .unconfirmed ? "unconfirmed" : "inserted"))
        }
        // A verified row is never marked unreadable, whatever the caller passes.
        #expect(LandedPillInfo(text: "x", verified: true, unreadable: true).verdict == .confirmed)
    }

    @Test func unreadableAutoClearsAfterTheLandedDwell() {
        var presenter = PillPresenter()
        let t = Self.t0
        _ = presenter.request(.landed(LandedPillInfo(text: "hi", verdict: .unreadable)), now: t)
        // A retraction inside the dwell is held for the remainder; after it, it goes through.
        guard case .hold(let until) = presenter.request(.hidden, now: t.addingTimeInterval(0.1)) else {
            Issue.record("expected the retraction to wait for the landed dwell"); return
        }
        #expect(until <= t.addingTimeInterval(PillDwell.inserted + 0.01) && until != .distantFuture)
        #expect(presenter.flush(now: t.addingTimeInterval(PillDwell.inserted + 0.05)) == .show(.hidden))

        var sticky = PillPresenter()
        _ = sticky.request(.landed(LandedPillInfo(text: "hi", verdict: .unconfirmed)), now: t)
        // N22 — held for the notice dwell, then it goes.
        #expect(sticky.request(.hidden, now: t.addingTimeInterval(1)) == .hold(until: t.addingTimeInterval(PillDwell.transientNotice)))
        #expect(sticky.request(.hidden, now: t.addingTimeInterval(5)) == .show(.hidden))
    }

    @Test func routerReadsTheLedgerAndFallsBackToTheWarning() {
        let ledger = LandingVerdictLedger()
        let delivered = DeliveryOutcome.delivered(verified: false, method: "keystroke")
        // No entry: conservative sticky D06.
        guard case .landed(let none) = PillDeliveryRouter.state(for: delivered, text: "a b", verdicts: ledger) else {
            Issue.record("expected landed"); return
        }
        #expect(none.verdict == .unconfirmed)
        ledger.record(.unreadable, text: "a b", utteranceID: "u1")
        guard case .landed(let unreadable) = PillDeliveryRouter.state(for: delivered, text: "a b", verdicts: ledger) else {
            Issue.record("expected landed"); return
        }
        #expect(unreadable.verdict == .unreadable)
        ledger.record(.unconfirmed, text: "a b")
        guard case .landed(let newest) = PillDeliveryRouter.state(for: delivered, text: "a b", verdicts: ledger) else {
            Issue.record("expected landed"); return
        }
        #expect(newest.verdict == .unconfirmed)
        // A verified delivery is verified whatever the ledger says.
        ledger.record(.unreadable, text: "a b")
        guard case .landed(let ok) = PillDeliveryRouter.state(for: .delivered(verified: true, method: "ax"), text: "a b",
                                                             verdicts: ledger) else {
            Issue.record("expected landed"); return
        }
        #expect(ok.verdict == .confirmed)
    }

    @Test func ledgerIsBoundedAndExpires() {
        var now = Self.t0
        let ledger = LandingVerdictLedger(capacity: 2, lifetime: 10, clock: { now })
        ledger.record(.unreadable, text: "one", utteranceID: "1")
        ledger.record(.unreadable, text: "two")
        ledger.record(.unconfirmed, text: "three")
        #expect(ledger.verdict(forText: "one") == nil)            // evicted
        #expect(ledger.verdict(utteranceID: "1") == nil)
        #expect(ledger.verdict(forText: "two") == .unreadable)
        now = now.addingTimeInterval(11)
        #expect(ledger.verdict(forText: "two") == nil)            // stale
    }
}

/// V5 Q4/Q5 verify — the view model holds an unreadable landing's source through the ribbon's flight,
/// exactly as it does a verified one (the presenter already arms the hold; the retraction must honour it).
@Suite("Q4/Q5 · unreadable landing holds through the flight")
@MainActor
struct LandingVerdictFlightHoldTests {
    @Test func unreadableDeliveryKeepsTheSourceThroughFlightThenClears() {
        let t0 = Date(timeIntervalSince1970: 4_000)
        let text = "unreadable flight \(UUID().uuidString)"
        LandingVerdictLedger.shared.record(.unreadable, text: text)
        let model = PillViewModel()
        var clock = t0
        model.now = { clock }
        model.deliveryReduceMotion = { false }
        model.present(.inserting(text: text))
        clock = t0.addingTimeInterval(0.14)
        model.present(delivery: .delivered(verified: false, method: "ax"), text: text)
        let acknowledged = model.state
        #expect(acknowledged == .landed(LandedPillInfo(text: text, verdict: .unreadable)))
        clock = t0.addingTimeInterval(0.84)                  // the 650 ms landed timer fires mid-flight
        model.retractDelivery()
        #expect(model.state == acknowledged)
        clock = t0.addingTimeInterval(SpoolFlight.duration + PillDwell.inserted + 0.001)
        model.retractDelivery()
        #expect(model.state == .hidden)                      // never sticky
    }
}
