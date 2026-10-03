import Foundation
import Injection
import Pipeline
import Shared
import Testing
@testable import VoicePlusApp

/// H6 + H9 — selection = edit mode through the real lander (mock AX field, scripted rewriter; no
/// model, no live app). H6: the edit parser owns the utterance before repair routing; explicit
/// replace verbs replace the selection through the normal injector. H9: the result stays selected
/// and follow-ups chain only after an applied edit.
@Suite("H6/H9 — selection edits through the lander")
struct TransformSelectionEditLanderTests {
    typealias Box<T> = TransformPreviewGateTests.Box<T>

    struct H {
        let lander: UtteranceLander
        let landing: TransformLanding
        let system: MockSystemAccess
        let provider: ScriptedRewriter
        let events: Box<[TransformPillReducer.Event]>
        let clock: Box<Date>
    }

    static func make(_ value: String, _ selection: Range<Int>, script: [(String, String)] = []) -> H {
        let (lander, landing, system, provider) = TransformLandingTests.harness(value: value, selection: selection, script: script)
        let h = H(lander: lander, landing: landing, system: system, provider: provider, events: Box([]),
                  clock: Box(Date(timeIntervalSince1970: 80_000)))
        landing.onEvent = { [events = h.events] in events.value.append($0) }
        landing.clock = { [clock = h.clock] in clock.value }
        landing.sleep = { _ in }
        return h
    }

    static func land(_ h: H, _ text: String) async -> LandingResult {
        await h.lander.land(TransformLandingTests.spans(text), startedAt: h.clock.value, focus: h.system.frontmost)
    }

    // MARK: H6 — edit parser before repair routing

    @Test("selection + a repair-looking command is an edit of the selection, not typed, not a repair")
    func repairPhraseOverSelectionEdits() async {
        let h = Self.make("hello world", 0..<11, script: [("uppercase", "HELLO WORLD")])
        let r = await Self.land(h, "uppercase this")
        guard case .transformed(.applied)? = r.transform else { Issue.record("expected applied, got \(String(describing: r.transform))"); return }
        #expect(h.system.field.value == "HELLO WORLD")
        #expect(r.injection == nil)
    }

    @Test("selection + \"capitalize this\" → edit")
    func capitalizeThisEdits() async {
        let h = Self.make("hello world", 0..<11, script: [("capitalize", "Hello World")])
        let r = await Self.land(h, "capitalize this")
        guard case .transformed(.applied)? = r.transform else { Issue.record("expected applied, got \(String(describing: r.transform))"); return }
        #expect(h.system.field.value == "Hello World")
    }

    @Test("selection + \"replace with hello\" → the selection becomes \"hello\" via the normal injector")
    func replaceWithTypesOverSelection() async {
        let h = Self.make("see you tomorrow", 4..<16)
        let r = await Self.land(h, "replace with hello")
        guard case .replaceSelection? = r.transform else { Issue.record("expected replaceSelection, got \(String(describing: r.transform))"); return }
        #expect(r.route == .dictate)
        #expect(r.injection?.succeeded == true)
        let v = h.system.field.value.lowercased()
        #expect(v.hasPrefix("see hello"), Comment(rawValue: h.system.field.value))
        #expect(!v.contains("tomorrow") && !v.contains("replace"))
        #expect(h.provider.calls == 0, "a replace never asks a model")
    }

    @Test("\"change this to …\" and \"overwrite …\" replace too")
    func otherReplaceVerbs() async {
        let h = Self.make("draft text", 0..<10)
        _ = await Self.land(h, "change this to final copy")
        #expect(h.system.field.value.lowercased().hasPrefix("final copy"), Comment(rawValue: h.system.field.value))
        let h2 = Self.make("draft text", 0..<10)
        _ = await Self.land(h2, "overwrite with all good")
        #expect(h2.system.field.value.lowercased().hasPrefix("all good"), Comment(rawValue: h2.system.field.value))
    }

    @Test("\"replace\" alone asks for the text; the next utterance within 8 s replaces")
    func bareReplaceThenText() async {
        let h = Self.make("old words here", 0..<14)
        let r1 = await Self.land(h, "replace")
        #expect(r1.transform == .awaitingReplacement && r1.injection == nil)
        #expect(h.system.field.value == "old words here", "nothing typed yet")
        #expect(h.events.value.contains(.prompt(SelectionReplaceCommand.promptLine)))
        h.clock.value += 3
        let r2 = await Self.land(h, "make it shorter")   // even edit-looking words are the new text now
        guard case .replaceSelection? = r2.transform else { Issue.record("expected replaceSelection, got \(String(describing: r2.transform))"); return }
        #expect(h.system.field.value.lowercased().hasPrefix("make it shorter"), Comment(rawValue: h.system.field.value))
        #expect(h.provider.calls == 0)
    }

    @Test("a bare \"replace\" expires after the warm window: the next utterance is an edit again")
    func bareReplaceExpires() async {
        let h = Self.make("old words here", 0..<14, script: [("shorter", "old words")])
        _ = await Self.land(h, "replace")
        h.clock.value += 9
        let r = await Self.land(h, "make it shorter")
        guard case .transformed(.applied)? = r.transform else { Issue.record("expected an edit, got \(String(describing: r.transform))"); return }
        #expect(h.system.field.value == "old words")
    }

    @Test("replace over a password field types nothing")
    func replaceRefusedInSecureField() async {
        let h = Self.make("x", 0..<0)
        var field = MockSystemAccess.Field.secure()
        field.value = "abc"; field.selection = 0..<3
        h.system.field = field
        let r = await Self.land(h, "replace with hunter two")
        #expect(r.injection?.succeeded != true)
        #expect(h.system.field.value == "abc")
    }

    @Test("no selection: dictation unchanged, even for edit and replace phrasing")
    func noSelectionDictates() async {
        let h = Self.make("hello ", 6..<6)
        let r = await Self.land(h, "capitalize this")
        #expect(r.transform == nil && r.injection?.succeeded == true)
        #expect(h.system.field.value.lowercased().contains("capitalize this"))
    }

    // MARK: H9 — the result stays selected; chaining only after an applied edit

    @Test("edit → the field's selection is the new text's range; a follow-up edits the result")
    func resultStaysSelectedAndChains() async {
        let h = Self.make("We should probably meet at some point next week", 0..<47,
                          script: [("shorter", "Let's meet next week"), ("formal", "Shall we meet next week?")])
        _ = await Self.land(h, "make this shorter")
        #expect(h.system.field.value == "Let's meet next week")
        #expect(h.system.field.selection == 0..<20, "the new text, not the old 0..<47 range")
        h.clock.value += 2
        let r2 = await Self.land(h, "make it formal")
        guard case .transformed(.applied)? = r2.transform else { Issue.record("expected chained edit, got \(String(describing: r2.transform))"); return }
        #expect(h.system.field.value == "Shall we meet next week?")
        #expect(h.system.field.selection == 0..<24)
        #expect(h.landing.session.turns.count == 2, "the chain keeps both turns for undo")
        // Undo (the notch's ↩) restores the previous result and keeps it selected.
        #expect(h.landing.undo()?.succeeded == true)
        #expect(h.system.field.value == "Let's meet next week" && h.system.field.selection == 0..<20)
    }

    @Test("edit in the middle of a field selects exactly the replacement")
    func resultRangeMidField() async {
        let text = "Intro. we gonna ship it friday. Outro."
        let h = Self.make(text, 7..<31, script: [("formal", "We will ship it on Friday.")])
        _ = await Self.land(h, "make this formal")
        #expect(h.system.field.value == "Intro. We will ship it on Friday. Outro.")
        #expect(h.system.field.selection == 7..<33)
    }

    @Test("no change → not warm; with the caret moved the next hold dictates")
    func noChangeThenDictates() async {
        let h = Self.make("hello world", 0..<11, script: [("polish", "hello world")])
        let r1 = await Self.land(h, "polish this")
        guard case .transformed(.noChange)? = r1.transform else { Issue.record("expected noChange, got \(String(describing: r1.transform))"); return }
        #expect(!h.landing.isWarm)
        h.system.field.selection = 11..<11
        h.clock.value += 2
        let r2 = await Self.land(h, "and more")
        #expect(r2.transform == nil && r2.injection?.succeeded == true)
        #expect(h.system.field.value.lowercased().contains("and more"))
    }

    @Test("after an applied edit, moving the caret away ends the chain: dictation")
    func caretMovedEndsChain() async {
        let h = Self.make("a b c", 0..<5, script: [("shout", "A B C")])
        _ = await Self.land(h, "shout this")
        #expect(h.landing.isWarm)
        h.system.field.selection = 5..<5
        h.clock.value += 1
        let r = await Self.land(h, "thanks")
        #expect(r.transform == nil && r.injection?.succeeded == true)
    }
}
