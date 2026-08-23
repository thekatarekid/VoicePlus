import Foundation
import CoreGraphics
import Testing
@testable import Actions

@Suite("P3.6 reverse elicitation state machine")
struct ReverseElicitationTests {
    let cands = [ElicitationCandidate(id: "l", label: "Save button", ring: CGRect(x: 0, y: 0, width: 100, height: 50), displayID: 1),
                 ElicitationCandidate(id: "r", label: "Cancel button", ring: CGRect(x: 200, y: 0, width: 100, height: 50), displayID: 1)]

    @Test func askThenPointResolves() {
        var m = ReverseElicitation(timeout: 4)
        guard case .prompting(let p) = m.handle(.ask(phrase: "that", candidates: cands, now: 10)) else { Issue.record("no prompt"); return }
        #expect(p.question == "which one?" && p.deadline == 14 && p.candidates.count == 2)
        m.handle(.point(GlobalPoint(x: 150, y: 25, displayID: 2), now: 11))   // wrong display: ignored
        #expect({ if case .prompting = m.state { return true }; return false }())
        m.handle(.point(GlobalPoint(x: 210, y: 60, displayID: 1), now: 12))   // within slack of right ring
        #expect({ if case .resolved(let c, _) = m.state { return c.id == "r" }; return false }())
    }

    @Test func speechAnswersByLabelOrdinalOrPosition() {
        for (speech, id) in [("the save one", "l"), ("the second", "r"), ("the left one", "l"), ("the one on the right", "r")] {
            var m = ReverseElicitation(); m.handle(.ask(phrase: "this", candidates: cands, now: 0))
            m.handle(.speech(speech, now: 1))
            #expect({ if case .resolved(let c, _) = m.state { return c.id == id }; return false }(), "\(speech)")
        }
        var m = ReverseElicitation(); m.handle(.ask(phrase: "this", candidates: cands, now: 0))
        m.handle(.speech("the button", now: 1))   // matches both equally → still prompting
        #expect({ if case .prompting = m.state { return true }; return false }())
    }

    @Test func timeoutFallsBackToClarifyingText() {
        var m = ReverseElicitation(timeout: 2)
        m.handle(.ask(phrase: "that", candidates: cands, now: 0))
        m.handle(.tick(now: 1.9))
        #expect({ if case .prompting = m.state { return true }; return false }())
        m.handle(.tick(now: 2.1))
        guard case .timedOut(let text, _) = m.state else { Issue.record("expected timeout"); return }
        #expect(text == "Which one did you mean by “that”: “Save button” or “Cancel button”?")
        // Late answers after timeout are ignored; cancel always wins.
        m.handle(.speech("the first", now: 3))
        #expect({ if case .timedOut = m.state { return true }; return false }())
        m.handle(.cancel)
        #expect(m.state == .cancelled)
    }

    @Test func singleCandidateResolvesImmediatelyAndNoneIsIdle() {
        var m = ReverseElicitation()
        m.handle(.ask(phrase: "this", candidates: [cands[0]], now: 0))
        #expect({ if case .resolved(let c, _) = m.state { return c.id == "l" }; return false }())
        m.handle(.ask(phrase: "this", candidates: [], now: 0))
        #expect(m.state == .idle)
    }

    @Test func candidatesFromDeixisBinding() {
        let e = ElementReference(id: "x", role: "AXButton", label: "OK", frame: CGRect(x: 10, y: 10, width: 20, height: 20), displayID: 2)
        let c = ElicitationCandidate.from(.element(e), id: "0")
        #expect(c.label == "OK" && c.displayID == 2 && c.ring == CGRect(x: 4, y: 4, width: 32, height: 32))
    }
}
