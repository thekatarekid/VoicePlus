import Foundation
import Injection
import Pipeline
import Shared
import Testing
@testable import VoicePlusApp

/// H12 (old H9) — every selection edit is logged and recorded: route, command id, selection length,
/// outcome, model used. Never text. Mock AX field and scripted provider; no model is loaded.
@Suite("H12 — edit outcomes recorded, never text")
struct TransformEditOutcomeH12Tests {
    typealias H = TransformSelectionEditLanderTests.H
    static func make(_ value: String, _ sel: Range<Int>, script: [(String, String)] = []) -> H {
        TransformSelectionEditLanderTests.make(value, sel, script: script)
    }
    static func land(_ h: H, _ text: String) async -> LandingResult { await TransformSelectionEditLanderTests.land(h, text) }

    @Test("a D command: transform route, its catalogue id, the selection length, applied, catalog")
    func deterministic() async throws {
        let h = Self.make("ship it now", 0..<7)
        let r = await Self.land(h, "make this all caps")
        let e = try #require(r.edit)
        #expect(e == EditOutcomeRecord(route: "transform", commandID: "case.upper", selectionLength: 7, outcome: "applied", model: "catalog"))
        #expect(h.landing.lastRecord == nil, "the lander took the record")
    }

    @Test("a free-form edit run by the (mock) model records model; the log line carries no text")
    func model() async throws {
        let h = Self.make("hey there", 0..<9, script: [("make it sound like a pirate", "Ahoy there")])
        let r = await Self.land(h, "make it sound like a pirate")
        let e = try #require(r.edit)
        #expect(e.route == "transform" && e.commandID == "freeform" && e.outcome == "applied" && e.model == "model")
        #expect(e.selectionLength == 9)
        for text in ["hey", "there", "Ahoy", "pirate"] { #expect(!e.logLine.contains(text)) }
    }

    @Test("copy, undo with nothing to undo, replace: each recorded with its own route")
    func otherRoutes() async throws {
        let h = Self.make("hello world", 0..<5)
        #expect(try #require(await Self.land(h, "copy this").edit) ==
                EditOutcomeRecord(route: "copy", commandID: "copy", selectionLength: 5, outcome: "copied", model: nil))
        #expect(try #require(await Self.land(h, "undo that").edit).outcome == "nothingToUndo")
        let replace = try #require(await Self.land(h, "replace with goodbye").edit)
        #expect(replace.route == "replace" && replace.commandID == "replace.with" && replace.outcome == "replacing")
    }

    @Test("no selection: no edit record (dictation)")
    func noSelection() async {
        let h = Self.make("hello ", 6..<6)
        let r = await Self.land(h, "capitalize this")
        #expect(r.edit == nil)
    }

    @Test("password field: nothing recorded")
    func secure() async {
        let h = Self.make("x", 0..<0)
        var field = MockSystemAccess.Field.secure()
        field.value = "abc"; field.selection = 0..<3
        h.system.field = field
        let r = await Self.land(h, "uppercase this")
        #expect(r.edit == nil)
    }

    @Test("failures map to plain outcome words (held, cancelled, needsModel, failed)")
    func failures() {
        func outcome(_ o: TransformReplaceOutcome) -> String? {
            EditOutcomeRecord.make(.transformed(.failed(o)), selection: "abc", instruction: "make this formal", surface: nil)?.outcome
        }
        #expect(outcome(.mismatch(actual: nil)) == "held")
        #expect(outcome(.unavailable(reason: "cancelled")) == "cancelled")
        #expect(outcome(.unavailable(reason: TransformLanding.needsModelReason)) == "needsModel")
        #expect(outcome(.unavailable(reason: "injector failed")) == "failed")
        let needs = EditOutcomeRecord.make(.transformed(.failed(.unavailable(reason: TransformLanding.needsModelReason))),
                                           selection: "abc", instruction: "make this formal", surface: nil)
        #expect(needs?.commandID == EditCommandCatalog.classify("make this formal").id)
        #expect(EditOutcomeRecord.make(.notHandled, selection: "abc", instruction: "x", surface: nil) == nil)
    }

    @Test("extras_json carries the edit fields and no text")
    func extrasJSON() throws {
        var extras = TurnRecordExtras()
        extras.edit = EditOutcomeRecord(route: "transform", commandID: "tone.formal", selectionLength: 42, outcome: "applied", model: "model")
        let json = try #require(String(data: JSONEncoder().encode(extras), encoding: .utf8))
        for key in ["route", "commandID", "selectionLength", "outcome", "model", "tone.formal", "42"] { #expect(json.contains(key)) }
        let back = try JSONDecoder().decode(TurnRecordExtras.self, from: Data(json.utf8))
        #expect(back.edit == extras.edit)
        #expect(!extras.isEmpty)
        // An older row (no edit key) still decodes.
        let old = try JSONDecoder().decode(TurnRecordExtras.self, from: Data(#"{"surfaceKind":"chat"}"#.utf8))
        #expect(old.edit == nil)
    }
}
