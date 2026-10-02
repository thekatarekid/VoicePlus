import Foundation
import Testing
import Shared
@testable import Pipeline
@testable import VoicePlusApp

// N25 — per-app preset overrides over a user default over the built-in default.

@Suite struct SurfacePresetRulesN25Tests {
    @Test func appOverrideBeatsDefaultBeatsBuiltIn() {
        var book = AppRuleBook()
        #expect(book.resolved(for: "com.tinyspeck.slackmacgap").preset(for: .chatComposer) == Inherited("natural", usesDefault: true))
        let ok337 = book.setPreset("polished", group: "chatComposer"); #expect(ok337)
        #expect(book.resolved(for: "com.tinyspeck.slackmacgap").preset(for: .chatComposer) == Inherited("polished", usesDefault: true))
        let ok887 = book.setPreset("casual", group: "chatComposer", bundleID: "com.tinyspeck.slackmacgap"); #expect(ok887)
        let slack = book.resolved(for: "com.tinyspeck.slackmacgap")
        #expect(slack.preset(for: .chatComposer) == Inherited("casual", usesDefault: false))
        #expect(book.resolved(for: "com.hnc.Discord").preset(for: .chatComposer)?.value == "polished")
        #expect(slack.preset(for: .secure) == nil)
    }

    @Test func unknownPresetIdIsRefusedAndStaleIdsIgnored() {
        var book = AppRuleBook()
        let ok73 = book.setPreset("casual", group: "prose"); #expect(!ok73)
        book.rules["a.b"] = AppRule(bundleID: "a.b", presets: ["prose": "gone"])
        #expect(book.resolved(for: "a.b").preset(for: .prose)?.value == "natural")
    }

    @Test func applyWritesSelectionAndTheStageResolvesIt() {
        var book = AppRuleBook()
        _ = book.setPreset("exact", group: "prose", bundleID: "com.apple.TextEdit")
        var ctx = book.resolved(for: "com.apple.TextEdit").apply(to: StageContext(appBundleID: "com.apple.TextEdit"))
        ctx.extra[FieldContext.Keys.surfaceKind] = SurfaceKind.prose.id
        #expect(SurfacePresets.active(in: ctx)?.id == "exact")
        #expect(SurfacePresets.active(in: ctx)?.allowsCleanup == false)
    }

    @Test func presetsPersistAndOldJSONStillReads() throws {
        let d = UserDefaults(suiteName: "n25.\(UUID().uuidString)")!
        let store = UserDefaultsAppRuleStore(defaults: d)
        var book = AppRuleBook()
        _ = book.setPreset("concise", group: "emailBody")
        _ = book.setPreset("casual", group: "chatComposer", bundleID: "com.tinyspeck.slackmacgap")
        try store.save(book)
        let back = try store.load()
        #expect(back.defaults.presets == ["emailBody": "concise"])
        #expect(back.rules["com.tinyspeck.slackmacgap"]?.presets == ["chatComposer": "casual"])
        // pre-N25 JSON (no presets field) still decodes
        d.set(#"{"version":1,"defaults":{"style":"natural","contextualReading":true},"rules":[{"bundleID":"x.y","style":"verbatim"}]}"#,
              forKey: UserDefaultsAppRuleStore.rulesKey)
        let old = try store.load()
        #expect(old.defaults.presets.isEmpty)
        #expect(old.rules["x.y"]?.presets.isEmpty == true)
    }
}
