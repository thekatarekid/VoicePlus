import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// S5b — the flicker. `RealEngine.stop()` sends `.landed` and `.idle` back to back, and an error is
/// followed by the next turn's reset; before `PillPresenter` both reached the panel in the same
/// run-loop pass, so the pill slid in and straight back out ("a broken animation … appeared and
/// disappeared quickly") and an error notice could not be read, let alone screenshotted.
@Suite("Pill dwell / presenter (S5b)")
struct PillPresenterTests {
    let t0 = Date(timeIntervalSince1970: 1_000)

    @Test func landedThenIdleInTheSameInstantIsNotAFlicker() {
        var p = PillPresenter()
        #expect(p.request(.landing, now: t0) == .show(.landing))
        // The retraction arrives with zero time in between — it must be held, not drawn.
        let held = p.request(.hidden, now: t0)
        #expect(held == .hold(until: t0.addingTimeInterval(PillDwell.acknowledgement)))
        #expect(p.displayed == .landing)
        // Flushing early changes nothing; flushing after the dwell retracts.
        #expect(p.flush(now: t0.addingTimeInterval(0.2)) == .hold(until: t0.addingTimeInterval(PillDwell.acknowledgement)))
        #expect(p.displayed == .landing)
        #expect(p.flush(now: t0.addingTimeInterval(PillDwell.acknowledgement)) == .show(.hidden))
        #expect(p.displayed == .hidden)
    }

    @Test func errorCannotBeDismissedBeforeItIsLegible() {
        var p = PillPresenter()
        #expect(p.request(.error(message: "boom"), now: t0) == .show(.error(message: "boom")))
        for offset in [0.0, 0.5, 1.0, 3.9] {
            let now = t0.addingTimeInterval(offset)
            _ = p.request(.hidden, now: now)
            _ = p.flush(now: now)
            #expect(p.displayed == .error(message: "boom"), "error vanished after \(offset)s")
            #expect(p.isDwelling(now: now))
        }
        let after = t0.addingTimeInterval(PillDwell.notice)
        #expect(p.flush(now: after) == .show(.hidden))
    }

    @Test func repeatedRetractionRequestsDoNotExtendOrShortenTheWindow() {
        var p = PillPresenter()
        _ = p.request(.error(message: "boom"), now: t0)
        for offset in stride(from: 0.0, to: 3.5, by: 0.25) {
            _ = p.request(.hidden, now: t0.addingTimeInterval(offset))
        }
        #expect(p.displayed == .error(message: "boom"))
        #expect(p.flush(now: t0.addingTimeInterval(PillDwell.notice)) == .show(.hidden))
    }

    @Test func aVisibleStateNeverWaitsBehindAnOlderOne() {
        // A new turn must take over instantly — a stale notice in front of a live utterance would
        // be a worse bug than the flicker it replaced.
        var p = PillPresenter()
        _ = p.request(.error(message: "boom"), now: t0)
        #expect(p.request(.listening(level: 0.4), now: t0.addingTimeInterval(0.1)) == .show(.listening(level: 0.4)))
        #expect(p.pending == nil)
        // …and the fast state that follows it retracts with no delay at all.
        #expect(p.request(.hidden, now: t0.addingTimeInterval(0.2)) == .show(.hidden))
    }

    @Test func statesWithoutADwellRetractImmediately() {
        for state in [PillState.idle, .listening(level: 0.2), .preview(text: "hi"),
                      .transform(.init(editingWords: 1, stage: .editing))] {
            var p = PillPresenter()
            _ = p.request(state, now: t0)
            #expect(p.request(.hidden, now: t0) == .show(.hidden), "\(state.caseName) should not linger")
        }
    }

    @Test func noticesAreTheStatesTheUserMustRead() {
        #expect(PillDwell.isNotice(.error(message: "x")))
        #expect(PillDwell.isNotice(.unavailable(reason: "x")))
        #expect(PillDwell.isNotice(.warning(.unknownGood)))
        #expect(!PillDwell.isNotice(.landing))
        #expect(!PillDwell.isNotice(.preview(text: "x")))
        #expect(PillDwell.minimum(for: .hidden) == 0)
        #expect(PillDwell.notice >= 3, "an error the user cannot read is worse than no error")
    }

    @Test func viewModelRoutesEveryWriteThroughTheGate() {
        let model = PillViewModel()
        var clock = Date(timeIntervalSince1970: 2_000)
        model.now = { clock }
        model.apply(.error("no model"))
        #expect(model.state == .error(message: "no model"))
        // The engine's very next event is `.idle` → `.hidden`; the notice must survive it.
        model.apply(.idle)
        #expect(model.state == .error(message: "no model"))
        model.hide()
        #expect(model.state == .error(message: "no model"))
        clock = clock.addingTimeInterval(PillDwell.notice + 0.1)
        model.flushPillHold()
        #expect(model.state == .hidden)
    }

    @Test func viewModelStillShowsANewTurnImmediately() {
        let model = PillViewModel()
        let clock = Date(timeIntervalSince1970: 3_000)
        model.now = { clock }
        model.apply(.error("boom"))
        model.apply(.prewarming)
        #expect(model.state == .idle)
    }
}

@Suite("Presence click routing")
struct PresenceClickTests {
    /// The owner's call after living with 1.7.9: "It was ok to open menu on left clicking the notch.
    /// No need to make it right click." A click is a click, in every state.
    @Test func everyPrimaryClickOpensTheMenu() {
        for state: PresenceState in [.off, .ready, .listening(level: 0.5), .processing, .muted, .paused,
                                     .blocked(.relaunchNeeded), .blocked(.microphoneDenied),
                                     .blocked(.hotkeyUnavailable), .blocked(.modelMissing),
                                     .blocked(.modelDownloading(0.4))] {
            #expect(PresenceClickRouter.action(for: state) == .menu, "\(state.caseName)")
        }
    }

    /// The right-click / ⌃-click escape hatch did not go anywhere — it just is not the only way in.
    @Test func secondaryClickStillOpensTheSameMenu() {
        for state: PresenceState in [.ready, .muted, .paused, .blocked(.relaunchNeeded), .blocked(.modelMissing)] {
            #expect(PresenceClickRouter.action(for: state, secondary: true) == .menu, "\(state.caseName)")
        }
    }
}
