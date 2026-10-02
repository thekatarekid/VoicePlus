import Foundation
import Testing
import Shared
@testable import Pipeline

// N25 — 2-3 named presets per surface kind; default is neutral; selection resolved lazily from
// the run's surface kind; presets pin style edits, skip cleanup, or replace an auto persona.

private func spans(_ words: [String]) -> [TranscriptSpan] {
    words.enumerated().map { i, w in
        TranscriptSpan(text: w, confidence: 0.9, audioRange: Double(i)...Double(i) + 0.9, provenance: [.asr])
    }
}

private func context(kind: SurfaceKind?, selection: [String: String] = [:], bundle: String = "com.example.app") -> StageContext {
    var c = StageContext(appBundleID: bundle)
    if let kind { c.extra[FieldContext.Keys.surfaceKind] = kind.id }
    if !selection.isEmpty { c.extra[SurfacePresets.selectionKey] = SurfacePresets.encode(selection) }
    return c
}

@Suite struct SurfacePresetsN25Tests {
    static let typingKinds: [SurfaceKind] = [.terminal, .spreadsheetCell, .chatComposer, .urlBar, .searchField, .emailBody,
                                             .formField(label: "email"), .formField(label: "text"), .markdownEditor, .codeEditor, .prose]

    @Test func everyTypingKindHasTwoOrThreeNamedPresetsWithANeutralDefault() {
        for kind in Self.typingKinds {
            let p = SurfacePresets.presets(for: kind)
            #expect((2...3).contains(p.count), "\(kind.id)")
            #expect(Set(p.map(\.id)).count == p.count, "\(kind.id) ids unique")
            #expect(p.allSatisfy { !$0.title.isEmpty && !$0.detail.isEmpty })
            #expect(p.first?.isNeutral == true, "\(kind.id) default must change nothing")
        }
        #expect(Set(SurfacePresets.groups) == Set(Self.typingKinds.compactMap(SurfacePresets.group(for:))))
    }

    @Test func secureAndCanvasHaveNone() {
        #expect(SurfacePresets.presets(for: .secure).isEmpty)
        #expect(SurfacePresets.presets(for: .canvas).isEmpty)
        #expect(SurfacePresets.active(in: context(kind: .secure, selection: ["prose": "exact"])) == nil)
    }

    @Test func formFieldLabelsShareOneGroup() {
        #expect(SurfacePresets.group(for: .formField(label: "phone")) == "formField")
        #expect(SurfacePresets.active(in: context(kind: .formField(label: "phone"), selection: ["formField": "exact"]))?.id == "exact")
    }

    @Test func activeResolvesSelectionForTheRunsKindElseDefault() {
        #expect(SurfacePresets.active(in: context(kind: .chatComposer, selection: ["chatComposer": "casual"]))?.id == "casual")
        #expect(SurfacePresets.active(in: context(kind: .chatComposer, selection: ["prose": "exact"]))?.id == "natural")
        #expect(SurfacePresets.active(in: context(kind: .chatComposer, selection: ["chatComposer": "bogus"]))?.id == "natural")
        #expect(SurfacePresets.active(in: context(kind: nil, selection: ["prose": "exact"])) == nil)
    }

    @Test func encodeDecodeRoundTrip() {
        let sel = ["prose": "polished", "chatComposer": "casual"]
        #expect(SurfacePresets.decode(SurfacePresets.encode(sel)) == sel)
        #expect(SurfacePresets.decode("garbage;=x;y=") == [:])
    }

    @Test func casualChatPresetLowercasesAndDropsPeriod() async throws {
        let ctx = context(kind: .chatComposer, selection: ["chatComposer": "casual"], bundle: "com.tinyspeck.slackmacgap")
        let out = try await StyleStage().process(spans(["Sounds", "good."]), context: ctx)
        #expect(out.renderedText == "sounds good")
    }

    @Test func polishedProsePresetCapitalizesAndAddsPeriod() async throws {
        var p = StyleProfile.coldStart(appBundleID: "x", category: .chat)
        p.capitalizationRate = 0; p.terminalPeriodRate = 0
        var ctx = context(kind: .prose, selection: ["prose": "polished"])
        ctx.extra[StyleStage.profileJSONKey] = try p.encodedJSON()
        let out = try await StyleStage().process(spans(["sounds", "good"]), context: ctx)
        #expect(out.renderedText == "Sounds good.")
    }

    @Test func defaultPresetLeavesLearnedStyleAlone() async throws {
        var p = StyleProfile.coldStart(appBundleID: "x", category: .chat)
        p.capitalizationRate = 0; p.terminalPeriodRate = 0
        var ctx = context(kind: .prose)
        ctx.extra[StyleStage.profileJSONKey] = try p.encodedJSON()
        let out = try await StyleStage().process(spans(["Sounds", "good."]), context: ctx)
        #expect(out.renderedText == "sounds good")
    }

    @Test func exactPresetSkipsCleanupWithReasonPreset() async throws {
        let gen = ScriptedCleanup { _ in "X" }
        let log = OutcomeLog()
        let stage = CleanupStage(generator: gen, mode: { .always }, outputGuard: { CleanupGuard(entityGuard: nil) },
                                 observer: { log.add($0) })
        let out = try await stage.process(spans(["meet", "at", "five"]), context: context(kind: .prose, selection: ["prose": "exact"]))
        #expect(out.renderedText == "meet at five")
        #expect(gen.prompts.isEmpty)
        #expect(log.all == [.skipped("preset")])
    }

    @Test func presetInstructionReplacesOnlyAnAutoDraftedPersona() throws {
        let manager = PersonaManager(store: InMemoryPersonaStore())
        let ctx = context(kind: .emailBody, selection: ["emailBody": "concise"], bundle: "com.apple.mail")
        let auto = try #require(try manager.resolve(context: ctx))
        #expect(auto.promptText.hasPrefix("Concise, direct email voice"))
        // nothing persisted: the stored persona is still the auto draft
        #expect(try manager.persona(for: "com.apple.mail").text.hasPrefix("Concise") == false)
        _ = try manager.setText("my own words", for: "com.apple.mail")
        #expect(try manager.resolve(context: ctx)?.promptText == "my own words")
    }
}
