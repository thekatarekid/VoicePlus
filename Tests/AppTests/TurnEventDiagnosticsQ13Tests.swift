import Foundation
import Injection
import Shared
import Testing
@testable import VoicePlusApp

/// V5 Q13 follow-up — the turn controller records landing (verdict, app, method, settle ms) and
/// every dwell pause / resume (reason + pointer + pill frame) into the Q13 store. No text in any event.
@Suite("V5 Q13 — landing + pause events", .serialized)
struct TurnEventDiagnosticsQ13Tests {
    final class Sink: @unchecked Sendable {
        let lock = NSLock()
        var events: [(TurnDiagnosticsEvent, String)] = []
        func of(_ turn: String) -> [TurnDiagnosticsEvent] { lock.withLock { events.filter { $0.1 == turn }.map(\.0) } }
    }

    private func install() -> Sink {
        let sink = Sink()
        TurnEventDiagnostics.pointer = { DiagnosticsPoint(x: 7, y: 9) }
        TurnEventDiagnostics.frame = { DiagnosticsRect(x: 1, y: 2, width: 300, height: 40) }
        TurnEventDiagnostics.observer = { e, t in sink.lock.withLock { sink.events.append((e, t)) } }
        return sink
    }

    @Test func landingAndPausesAreRecordedForTheTurn() async throws {
        let sink = install()
        defer { TurnEventDiagnostics.observer = nil; TurnEventDiagnostics.frame = { nil } }
        let h = TurnControllerTests.Harness()
        let id = try #require(await h.holdToPreview(TurnControllerTests.words("hello there")))
        h.controller.finalRendered(id)
        h.controller.pauseDwell(.hover)
        h.controller.pauseDwell(.hover) // already paused for this reason: not logged twice
        h.controller.resumeDwell(.hover)
        h.clock.advance(1)
        #expect(await h.wait { h.events.landed.count == 1 })
        let events = sink.of(id.description)
        #expect(events.count == 3)
        #expect(events.first == .pause(reason: "hover", pointer: .init(x: 7, y: 9), frame: .init(x: 1, y: 2, width: 300, height: 40)))
        #expect(events.dropFirst().first == .resume(reason: "hover", pointer: .init(x: 7, y: 9), frame: .init(x: 1, y: 2, width: 300, height: 40)))
        guard case let .landing(verdict, app, method, settle)? = events.last else {
            Issue.record("no landing event"); return
        }
        #expect(verdict == "confirmed")
        #expect(app == "com.apple.TextEdit")
        #expect(method == "ax")
        #expect((settle ?? -1) >= 0)
    }

    @Test func landingEventMapsEveryDelivery() {
        func v(_ d: DeliveryOutcome?, _ l: LandingVerdict? = nil) -> String? {
            if case let .landing(verdict, _, _, _) = TurnEventDiagnostics.landingEvent(delivery: d, verdict: l, appBundleID: nil, settleMs: -3) {
                return verdict
            }
            return nil
        }
        #expect(v(.delivered(verified: true, method: "ax")) == "confirmed")
        #expect(v(.delivered(verified: false, method: "paste"), .unreadable) == "unreadable")
        #expect(v(.delivered(verified: false, method: "paste")) == "unverified")
        #expect(v(.partial(method: "keystroke")) == "partial")
        #expect(v(.held(reason: "destination changed")) == "held: destination changed")
        #expect(v(.failed(reason: "no destination")) == "failed: no destination")
        #expect(v(nil) == "none")
        if case let .landing(_, _, _, settle) = TurnEventDiagnostics.landingEvent(delivery: nil, verdict: nil, appBundleID: nil, settleMs: -3) {
            #expect(settle == 0)
        }
    }
}
