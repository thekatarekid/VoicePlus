import Foundation
import Shared
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

    static let latched = StageContext(extra: [WakeVerbPreRoute.modeKey: WakeVerbPreRoute.latchedValue])

    static func spans(_ text: String) -> [TranscriptSpan] {
        text.split(separator: " ").enumerated().map { i, w in
            TranscriptSpan(text: String(w), confidence: 0.9, audioRange: Double(i) * 0.3...Double(i) * 0.3 + 0.3, provenance: [.asr])
        }
    }

    static func words(_ spans: [TranscriptSpan]) -> String {
        spans.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
    }

    final class Sink: @unchecked Sendable { var payloads: [String] = []; var accept = true }

    @Test("latched 'note …' with a sink: stored, claimed once, route none, nothing stripped by the stage")
    func noteClaimed() async throws {
        let sink = Sink()
        let pre = WakeVerbPreRoute()
        pre.noteSink = { p in sink.payloads.append(p.payload); return sink.accept }
        let d = try #require(pre.preRoute("take a note buy oat milk", context: Self.latched))
        #expect(d.route == .none && sink.payloads == ["buy oat milk"])
        #expect(pre.consumeNoteClaim() && !pre.consumeNoteClaim())
        // Not latched: never a note, no claim.
        #expect(pre.preRoute("note buy milk", context: StageContext()) == nil && !pre.consumeNoteClaim())
    }

    @Test("no sink / sink declines: a note phrase is not a wake verb — typed verbatim, never stripped")
    func noSinkVerbatim() async throws {
        let pre = WakeVerbPreRoute()
        #expect(pre.preRoute("note that the meeting moved", context: Self.latched) == nil)
        #expect(!pre.consumeNoteClaim())
        let out = try await WakeVerbStage(preRoute: pre).process(Self.spans("note that the meeting moved"), context: Self.latched)
        #expect(Self.words(out) == "note that the meeting moved")
        let sink = Sink(); sink.accept = false
        pre.noteSink = { _ in sink.accept }
        #expect(pre.preRoute("note buy milk", context: Self.latched) == nil && !pre.consumeNoteClaim())
        // type … still strips.
        _ = pre.preRoute("type hello there", context: Self.latched)
        let typed = try await WakeVerbStage(preRoute: pre).process(Self.spans("type hello there"), context: Self.latched)
        #expect(Self.words(typed) == "hello there")
    }
}
