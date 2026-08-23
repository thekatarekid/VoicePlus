import Foundation
import Testing
import Shared
@testable import Pipeline

@Suite("P2.1 transform routing — Bet 5 selection is the deterministic signal")
struct TransformRoutingTests {
    let gk = GatekeeperStage()
    let sel = SelectionSnapshot(text: "hello world", range: 0..<11, bundleID: "com.apple.mail")

    func decide(_ text: String, selection: SelectionSnapshot?) -> TransformRouteDecision {
        TransformRouter.decide(gatekeeper: gk.decide(spans(text), context: StageContext()), selection: selection)
    }

    @Test("transform phrasing with no selection is dictation, never a rewrite")
    func noSelectionIsDictate() {
        for t in ["make this shorter", "summarize this", "translate this to Hindi", "what does this say", "rewrite this as an email"] {
            let d = decide(t, selection: nil)
            #expect(d.route == .dictate, Comment(rawValue: t))
            #expect(d.reason == .noSelection)
            #expect(d.selection == nil)
        }
    }

    @Test("with a selection, any text-key utterance is a transform")
    func selectionIsTransform() {
        for t in ["make this shorter", "more formal", "two lines please", "the deploy is scheduled for Thursday", "bold it", "call out the churn number"] {
            let d = decide(t, selection: sel)
            #expect(d.route == .transform, Comment(rawValue: t))
            #expect(d.selection == sel)
        }
    }

    @Test("question phrasing with a selection routes to question; never replaces")
    func selectionQuestion() {
        let d = decide("what does this say", selection: sel)
        #expect(d.route == .question)
        #expect(d.reason == .selectionQuestion)
    }

    @Test("repair commands keep their route without a selection (Bet 3 still works)")
    func repairWithoutSelection() {
        #expect(decide("scratch that", selection: nil).route == .repairCommand)
        #expect(decide("no Kothari", selection: nil).route == .repairCommand)
    }

    @Test("whitespace-only selection is no selection")
    func whitespaceSelection() {
        let blank = SelectionSnapshot(text: "   \n", range: 4..<8)
        #expect(decide("make this shorter", selection: blank).route == .dictate)
        #expect(!blank.isMeaningful)
    }

    @Test("empty / filler-only utterance stays .none even with a selection")
    func emptyUtterance() {
        #expect(decide("um uh", selection: sel).route == .none)
    }

    @Test("decision is deterministic: same inputs, same output, 200×")
    func deterministic() {
        let first = decide("tighten this up", selection: sel)
        for _ in 0..<200 {
            let d = decide("tighten this up", selection: sel)
            #expect(d.route == first.route && d.reason == first.reason && d.selection == first.selection && d.gatekeeper.route == first.gatekeeper.route)
        }
    }

    @Test("snapshot.from slices UTF-16 ranges and surrounding context")
    func snapshotContext() throws {
        let value = String(repeating: "a", count: 500) + "SELECTED" + String(repeating: "b", count: 500)
        let s = try #require(SelectionSnapshot.from(value: value, selectedRange: 500..<508))
        #expect(s.text == "SELECTED")
        #expect(s.before.count == SelectionSnapshot.contextWindow && s.after.count == SelectionSnapshot.contextWindow)
        #expect(s.wordCount == 1)
        #expect(SelectionSnapshot.from(value: "abc", selectedRange: 2..<9) == nil)
        #expect(SelectionSnapshot.from(value: "abc", selectedRange: 1..<1) == nil)
        let emoji = try #require(SelectionSnapshot.from(value: "x 😀y z", selectedRange: 2..<5))
        #expect(emoji.text == "😀y")
    }

    @Test("mock detector drives the router; live AX detector never throws")
    func detectors() {
        let mock = MockSelectionDetector(sel)
        #expect(TransformRouter.decide(gatekeeper: gk.decide(spans("make it formal"), context: StageContext()), detector: mock).route == .transform)
        mock.selection = nil
        #expect(TransformRouter.decide(gatekeeper: gk.decide(spans("make it formal"), context: StageContext()), detector: mock).route == .dictate)
        #if canImport(AppKit)
        // Headless test runner: AX is untrusted or no focused text element → nil, no crash.
        _ = AXSelectionDetector().currentSelection()
        #endif
    }

    @Test("instruction kind inference")
    func kinds() {
        let cases: [(String, TransformKind)] = [
            ("make this shorter", .shorten), ("make it more formal", .tone), ("turn this into a list", .restructure),
            ("translate this to Hindi", .translateFormat), ("fix the grammar", .fix), ("expand on this", .expand),
            ("make this two lines", .restructure), ("convert to markdown table", .translateFormat), ("bold it", .restructure), ("make it a headline", .shorten), ("format as a date", .translateFormat),
        ]
        for (t, k) in cases { #expect(TransformKind.infer(from: t) == k, Comment(rawValue: t)) }
    }
}
