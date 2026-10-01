import Testing
@testable import Pipeline

/// V5 N2 — the `noteVerbs` family of `WakeVerbGrammar`.
@Suite("Wake verb: note … (V5 N2)")
struct WakeVerbNoteTests {
    let grammar = WakeVerbGrammar()

    @Test("note / take a note / jot down route as .note with the payload in original casing")
    func noteVerbs() throws {
        let a = try #require(grammar.parse("Note: call Priya about the launch"))
        #expect(a.kind == .note && a.verbTokenCount == 1 && a.payload == "call Priya about the launch")
        let b = try #require(grammar.parse("take a note buy oat milk"))
        #expect(b.kind == .note && b.verbTokenCount == 3 && b.payload == "buy oat milk")
        let c = try #require(grammar.parse("Jot down, Friday standup moved"))
        #expect(c.kind == .note && c.payload == "Friday standup moved")
        let d = try #require(grammar.parse("note to self renew passport"))
        #expect(d.kind == .note && d.verbTokenCount == 3 && d.payload == "renew passport")
    }

    @Test("a bare verb with no payload is not a note; 'notes …' is still the Notes app")
    func notANote() throws {
        #expect(grammar.parse("note") == nil)
        #expect(grammar.parse("take a note") == nil)
        let app = try #require(grammar.parse("notes add milk"))
        #expect(app.kind == .app && app.appName == "notes")
        #expect(grammar.parse("nothing to note here") == nil)
    }

    @Test("type / send / app parses are unchanged")
    func othersUnchanged() throws {
        #expect(grammar.parse("type hello")?.kind == .type)
        #expect(grammar.parse("send it")?.kind == .send)
        #expect(grammar.parse("in slack hi team")?.kind == .app)
        #expect(WakeVerbGrammar.noteVerbs.contains("note"))
        #expect(WakeVerbGrammar.typeVerbs.isDisjoint(with: WakeVerbGrammar.noteVerbs))
    }
}
