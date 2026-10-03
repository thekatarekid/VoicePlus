import Foundation
import Testing
import Shared
@testable import Pipeline

/// H6 (Q4) — with text selected, speech is an edit command; the edit parser owns the utterance
/// before repair routing, and only explicit replace verbs replace the selection.
@Suite("H6 — selection = edit mode")
struct TransformSelectionEditTests {
    let gk = GatekeeperStage()
    let sel = SelectionSnapshot(text: "hello world", range: 0..<11, bundleID: "com.apple.mail")

    func decide(_ text: String, selection: SelectionSnapshot?) -> TransformRouteDecision {
        TransformRouter.decide(gatekeeper: gk.decide(spans(text), context: StageContext()), selection: selection)
    }

    // MARK: Router matrix

    @Test("selection: repair-looking phrases are edits of the selection, not repairs")
    func selectionOwnsRepairPhrases() {
        for t in ["capitalize this", "uppercase", "uppercase this", "lowercase it", "capital letters please",
                  "scratch that", "delete that", "replace with hello", "change this to hello", "no make it shorter",
                  "undo that", "put it back"] {
            let d = decide(t, selection: sel)
            #expect(d.route == .transform, Comment(rawValue: t))
            #expect(d.reason == .selectionTransform, Comment(rawValue: t))
            #expect(d.selection == sel, Comment(rawValue: t))
        }
    }

    @Test("no selection: dictation and repair routing unchanged")
    func noSelectionUnchanged() {
        #expect(decide("scratch that", selection: nil).route == .repairCommand)
        #expect(decide("no Kothari", selection: nil).route == .repairCommand)
        #expect(decide("uppercase that", selection: nil).route == .repairCommand)
        #expect(decide("capitalize this", selection: nil).route == .dictate)
        #expect(decide("replace with hello", selection: nil).route == .repairCommand)   // Bet 3 replace-x-with-y
        #expect(decide("the deploy is on Thursday", selection: nil).route == .dictate)
    }

    @Test("questions over a selection still answer, never replace")
    func questionStillAnswers() {
        #expect(decide("what does this mean", selection: sel).route == .question)
    }

    // MARK: Substring rule removed (RouteRules :38)

    @Test("repair phrases match whole or leading only — never as a substring of dictation")
    func noSubstringRepair() {
        for t in ["please write it in capital letters", "the uppercase key is stuck", "my answer was wrong",
                  "they told me to scratch that idea", "use lowercase for the ids"] {
            let hit = RouteRules.evaluate(GatekeeperTokenizer.words(t))
            #expect(hit?.route != .repairCommand, Comment(rawValue: t))
        }
        for t in ["scratch that", "uppercase that", "capital k", "wrong", "delete that please"] {
            #expect(RouteRules.evaluate(GatekeeperTokenizer.words(t))?.route == .repairCommand, Comment(rawValue: t))
        }
    }

    // MARK: Replace verbs

    func replacement(_ text: String) -> String? {
        guard case .replace(let rest)? = SelectionReplaceCommand.parse(spans(text)) else { return nil }
        return rest.renderedText
    }

    @Test("explicit replace verbs carry the new text")
    func replaceVerbs() {
        #expect(replacement("replace with hello") == "hello")
        #expect(replacement("Replace this with good morning team") == "good morning team")
        #expect(replacement("replace this text with see you Friday.") == "see you Friday.")
        #expect(replacement("replace it with ok") == "ok")
        #expect(replacement("replace the selection with done") == "done")
        #expect(replacement("overwrite with new words") == "new words")
        #expect(replacement("overwrite this with new words") == "new words")
        #expect(replacement("overwrite new words") == "new words")
        #expect(replacement("change this to hello there") == "hello there")
        #expect(replacement("change it to 42") == "42")
        #expect(replacement("please replace with hello") == "hello")
        #expect(replacement("replace with, hello") == "hello")
    }

    @Test("the verb alone asks for the text")
    func bareVerbAwaits() {
        for t in ["replace", "replace this", "replace this text", "replace it", "overwrite", "overwrite this", "Replace."] {
            #expect(SelectionReplaceCommand.parse(spans(t)) == .awaitingText, Comment(rawValue: t))
        }
    }

    @Test("not a replace-the-selection command")
    func notReplace() {
        for t in ["replace Friday with Monday", "change Friday to Monday", "change this", "make this shorter",
                  "capitalize this", "swap these", "replacement parts are here", "hello"] {
            #expect(SelectionReplaceCommand.parse(spans(t)) == nil, Comment(rawValue: t))
        }
    }

    @Test("the replacement keeps its spans' confidence, audio range and provenance")
    func replacementKeepsSpanMetadata() {
        let input = [
            TranscriptSpan(text: "replace with", confidence: 0.9, audioRange: 0...0.6, provenance: [.asr]),
            TranscriptSpan(text: "Kothari", confidence: 0.4, audioRange: 0.6...1.1, provenance: [.asr]),
            TranscriptSpan(text: "and sons", confidence: 0.8, audioRange: 1.1...1.6, provenance: [.asr]),
        ]
        guard case .replace(let rest)? = SelectionReplaceCommand.parse(input) else { Issue.record("expected replace"); return }
        #expect(rest == [input[1], input[2]], "whole spans after the verb are untouched")

        let mixed = [TranscriptSpan(text: "change this to Monday", confidence: 0.7, audioRange: 0...1, provenance: [.asr])]
        guard case .replace(let r2)? = SelectionReplaceCommand.parse(mixed) else { Issue.record("expected replace"); return }
        #expect(r2.count == 1 && r2[0].text == "Monday" && r2[0].confidence == 0.7 && r2[0].audioRange == 0...1)
        #expect(r2[0].provenance == [.asr, .transform])
    }

    // MARK: Session identity (H9)

    @Test("a fresh read of the edited result is the same session; another selection starts a new one")
    func sessionKeepsTurnsOnTheResult() async throws {
        let sink = MockReplaceInjector(value: "hello world")
        let provider = ScriptedTransformProvider()
        provider.script["shorter|hello world"] = "hello"
        let session = TransformSession(executor: TransformExecutor(providers: provider), sink: sink)
        _ = session.begin(with: sel)
        _ = try await session.run(instruction: spans("shorter"), context: StageContext())
        #expect(session.turns.count == 1 && session.selection?.range == 0..<5)
        // The field's selection is now the result (context strings differ: a fresh read).
        let fresh = SelectionSnapshot(text: "hello", range: 0..<5, before: "", after: " and more", bundleID: "com.apple.mail")
        _ = session.begin(with: fresh)
        #expect(session.turns.count == 1, "same target: turns kept for undo")
        _ = session.begin(with: SelectionSnapshot(text: "other", range: 20..<25, bundleID: "com.apple.mail"))
        #expect(session.turns.isEmpty)
    }
}
