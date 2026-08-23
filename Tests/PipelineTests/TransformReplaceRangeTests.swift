import Foundation
import Testing
import Shared
@testable import Pipeline

/// Re-run of the P1.8 T5 replace-range matrix against the transform engine, with the mock injector.
@Suite("P2.2 replace-range re-run + chained turns")
struct TransformReplaceRangeTests {
    let ctx = StageContext(register: .email)

    func session(_ value: String, selection: Range<Int>, script: [String: String]) -> (TransformSession, MockReplaceInjector, ScriptedTransformProvider) {
        let provider = ScriptedTransformProvider(); provider.script = script
        let injector = MockReplaceInjector(value: value, selection: selection)
        let s = TransformSession(executor: TransformExecutor(providers: provider), sink: injector, selection: injector.snapshot)
        return (s, injector, provider)
    }

    @Test("rewrite lands in place; text outside the selection is untouched")
    func inPlace() async throws {
        let (s, inj, _) = session("Hi team, hey can u send the report asap Thanks.", selection: 9..<39,
                                  script: ["make it formal|hey can u send the report asap": "could you please send the report today"])
        let step = try await s.run(instruction: spans("make it formal"), context: ctx)
        guard case .applied(let result, let outcome) = step else { Issue.record("expected applied, got \(step)"); return }
        #expect(outcome == .replaced(verified: true))
        #expect(inj.value == "Hi team, could you please send the report today Thanks.")
        #expect(inj.selection == 9..<(9 + result.output.utf16.count))
        #expect(s.selection?.text == result.output)
    }

    @Test("user edited the region before the rewrite landed → mismatch, document untouched")
    func mismatchLeavesDocument() async throws {
        let (s, inj, _) = session("alpha beta gamma", selection: 6..<10, script: ["make it formal|beta": "BETA"])
        inj.value = "alpha bets gamma"
        let step = try await s.run(instruction: spans("make it formal"), context: ctx)
        #expect(step == .failed(.mismatch(actual: "bets")))
        #expect(inj.value == "alpha bets gamma")
        #expect(s.turns.isEmpty)
    }

    @Test("element not writable → unavailable, nothing typed")
    func unavailable() async throws {
        let (s, inj, _) = session("alpha beta gamma", selection: 6..<10, script: ["make it formal|beta": "BETA"])
        inj.available = false
        let step = try await s.run(instruction: spans("make it formal"), context: ctx)
        #expect(step == .failed(.unavailable(reason: "AX not settable")))
        #expect(inj.value == "alpha beta gamma")
    }

    @Test("range outside the document → mismatch(nil)")
    func rangeOutOfBounds() {
        let inj = MockReplaceInjector(value: "short")
        #expect(inj.replace(TransformReplaceRequest(range: 2..<40, expected: "x", replacement: "y")) == .mismatch(actual: nil))
    }

    @Test("identity rewrite is reported as noChange and does not touch the document")
    func noChange() async throws {
        let (s, inj, _) = session("alpha beta gamma", selection: 6..<10, script: ["keep it|beta": "beta"])
        let step = try await s.run(instruction: spans("keep it"), context: ctx)
        guard case .noChange = step else { Issue.record("expected noChange"); return }
        #expect(inj.journal.isEmpty)
    }

    @Test("chained turns reuse the selection without re-selecting (P2.3 acceptance flow)")
    func chainedTurns() async throws {
        let one = "Revenue is up 12% and churn dropped to 4% this quarter."
        let two = "Revenue is up 12%.\nChurn dropped to 4% this quarter."
        let three = "Revenue is up 12%.\nChurn: 4% this quarter (down)."
        let four = "Revenue is up 12%.\n**Churn: 4% this quarter (down).**"
        let (s, inj, provider) = session("Summary: \(one) End.", selection: 9..<(9 + one.utf16.count), script: [
            "make this two lines|\(one)": two, "call out the churn number|\(two)": three, "bold it|\(three)": four,
        ])
        for instr in ["make this two lines", "call out the churn number", "bold it"] {
            #expect(s.begin(with: nil) != nil)   // no fresh selection: the warm one is reused
            let step = try await s.run(instruction: spans(instr), context: ctx)
            guard case .applied = step else { Issue.record("\(instr): \(step)"); return }
        }
        #expect(inj.value == "Summary: \(four) End.")
        #expect(s.turns.count == 3 && s.isWarm)
        // History of prior instructions is handed to the model on each chained turn.
        #expect(provider.calls[2].prompt.contains("- make this two lines") && provider.calls[2].prompt.contains("- call out the churn number"))
        #expect(!provider.calls[0].prompt.contains("PREVIOUS INSTRUCTIONS"))
        // Undo walks back one turn at a time, verifying the region each time.
        #expect(s.undoLast() == .replaced(verified: true))
        #expect(inj.value == "Summary: \(three) End." && s.turns.count == 2)
        #expect(s.undoLast()?.succeeded == true && s.undoLast()?.succeeded == true)
        #expect(inj.value == "Summary: \(one) End." && s.undoLast() == nil)
    }

    @Test("warm window expires; a fresh selection resets the chain")
    func warmWindow() async throws {
        let (s, _, _) = session("alpha beta gamma", selection: 6..<10, script: ["make it formal|beta": "BETA"])
        s.warmWindow = 0.05
        _ = try await s.run(instruction: spans("make it formal"), context: ctx, now: Date(timeIntervalSinceNow: -1))
        #expect(!s.isWarm)
        #expect(s.begin(with: nil) == nil)
        let fresh = SelectionSnapshot(text: "gamma", range: 11..<16)
        #expect(s.begin(with: fresh) == fresh)
        #expect(s.selection == fresh && s.turns.isEmpty)
    }

    @Test("undo after the user edited the rewritten region leaves the document alone")
    func undoMismatch() async throws {
        let (s, inj, _) = session("alpha beta gamma", selection: 6..<10, script: ["make it formal|beta": "BETA"])
        _ = try await s.run(instruction: spans("make it formal"), context: ctx)
        inj.value = "alpha BE TA gamma"
        #expect(s.undoLast() == .mismatch(actual: "BE T"))
        #expect(inj.value == "alpha BE TA gamma" && s.turns.count == 1)
    }

    @Test("multi-byte (emoji / Devanagari) ranges stay UTF-16 consistent across turns")
    func unicode() async throws {
        let hindi = "सुप्रभात"
        let (s, inj, _) = session("😀 Good morning 😀", selection: 3..<15, script: ["translate this to Hindi|Good morning": hindi])
        _ = try await s.run(instruction: spans("translate this to Hindi"), context: ctx)
        #expect(inj.value == "😀 \(hindi) 😀")
        #expect(s.selection?.range == 3..<(3 + hindi.utf16.count))
    }

    @Test("session without a selection refuses to run")
    func noSelection() async {
        let s = TransformSession(executor: TransformExecutor(), sink: MockReplaceInjector(value: "x"))
        await #expect(throws: TransformError.emptySelection) { try await s.run(instruction: spans("make it formal"), context: ctx) }
    }
}
