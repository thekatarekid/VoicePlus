import Foundation
import Injection
import Pipeline
import Shared
import Testing
@testable import VoicePlusApp

/// H7 — catalogue commands through the real lander (mock AX field, no model): deterministic edits
/// write instantly, delete/cut/copy/undo act on the selection, an unknown phrase goes to the model.
@Suite("H7 — edit-command catalogue through the lander")
struct TransformEditCommandsH7Tests {
    typealias H = TransformSelectionEditLanderTests.H
    static func make(_ value: String, _ sel: Range<Int>, script: [(String, String)] = []) -> H {
        TransformSelectionEditLanderTests.make(value, sel, script: script)
    }
    static func land(_ h: H, _ text: String) async -> LandingResult { await TransformSelectionEditLanderTests.land(h, text) }

    @Test("a D command edits with no model call; the result stays selected")
    func deterministicNoModel() async {
        let h = Self.make("ship it now", 0..<7)
        let r = await Self.land(h, "make this all caps")
        guard case .transformed(.applied(let result, _))? = r.transform else { Issue.record("got \(String(describing: r.transform))"); return }
        #expect(result.source == .catalog && result.commandID == "case.upper")
        #expect(h.system.field.value == "SHIP IT now")
        #expect(h.system.field.selection == 0..<7)
        #expect(h.provider.calls == 0)
    }

    @Test("find and replace inside the selection")
    func findReplace() async {
        let h = Self.make("meet on Tuesday at noon", 0..<23)
        _ = await Self.land(h, "change Tuesday to Friday")
        #expect(h.system.field.value == "meet on Friday at noon")
    }

    @Test("delete removes the selection; nothing typed")
    func delete() async {
        let h = Self.make("keep this drop", 9..<14)
        let r = await Self.land(h, "delete this")
        guard case .transformed(.applied)? = r.transform else { Issue.record("got \(String(describing: r.transform))"); return }
        #expect(h.system.field.value == "keep this")
        #expect(r.injection == nil)
    }

    @Test("copy writes the clipboard (verified) and leaves the text")
    func copy() async {
        let h = Self.make("hello world", 0..<5)
        let r = await Self.land(h, "copy this")
        #expect(r.transform == .copied(verified: true))
        #expect(h.system.field.value == "hello world")
        let data = h.system.readPasteboard().items.first?.types["public.utf8-plain-text"]
        #expect(data.flatMap { String(data: $0, encoding: .utf8) } == "hello")
        #expect(h.events.value.last == .notice(TransformLanding.copiedLine))
    }

    @Test("cut copies, then deletes")
    func cut() async {
        let h = Self.make("a b c", 2..<4)
        _ = await Self.land(h, "cut this")
        #expect(h.system.field.value == "a c")
        let data = h.system.readPasteboard().items.first?.types["public.utf8-plain-text"]
        #expect(data.flatMap { String(data: $0, encoding: .utf8) } == "b ")
    }

    @Test("undo that over the edited result puts the original back; with nothing to undo it says so")
    func undo() async {
        let h = Self.make("hello", 0..<5)
        let r0 = await Self.land(h, "undo that")
        #expect(r0.transform == .undid(nil))
        #expect(h.events.value.last == .notice(TransformLanding.nothingToUndoLine))

        _ = await Self.land(h, "uppercase")
        #expect(h.system.field.value == "HELLO")
        let r = await Self.land(h, "undo that")
        guard case .undid(let o?)? = r.transform, o.succeeded else { Issue.record("got \(String(describing: r.transform))"); return }
        #expect(h.system.field.value == "hello")
    }

    @Test("an unknown phrase goes to the model (scripted provider), not the catalogue")
    func unknownToModel() async {
        let h = Self.make("hey there", 0..<9, script: [("make it sound like a pirate", "Ahoy there")])
        let r = await Self.land(h, "make it sound like a pirate")
        guard case .transformed(.applied(let result, _))? = r.transform else { Issue.record("got \(String(describing: r.transform))"); return }
        #expect(result.source == .provider && result.commandID == "freeform")
        #expect(h.system.field.value == "Ahoy there")
    }
}
