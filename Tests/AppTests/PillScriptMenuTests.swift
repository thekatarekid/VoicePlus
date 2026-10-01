import Foundation
import Pipeline
import Shared
import Testing
@testable import VoicePlusApp

/// V5 LANG2 — the notch script dropdown: per-turn pick, remembered per app.
@Suite struct PillScriptMenuTests {
    final class Front: @unchecked Sendable { var id: String? = "com.apple.Notes" }

    static func model(_ store: SettingsStore, front: Front) -> ScriptChoiceModel {
        ScriptChoiceModel(settings: store, frontmostBundleID: { front.id })
    }

    @Test func notOfferedWithoutAScriptChoice() {
        let store = InMemorySettingsStore()
        let m = Self.model(store, front: Front())
        #expect(!m.isOffered)
        #expect(m.resolve(bundleID: "com.apple.Notes") == nil, "no LANG answer: the script stage stays inert")
        LanguagePreferences(languages: ["en", "hi"]).save(to: store)
        #expect(m.isOffered)
        #expect(m.resolve(bundleID: "com.apple.Notes") == .roman, "LANG1 default for Hindi is Roman")
        #expect(m.options == [.roman, .devanagari, .mixed])
    }

    @Test func aPickAppliesToTheTurnAndIsRememberedForTheApp() {
        let store = InMemorySettingsStore()
        LanguagePreferences(languages: ["en", "hi"], scriptByLanguage: ["hi": .roman]).save(to: store)
        let front = Front()
        let m = Self.model(store, front: front)
        m.choose(.devanagari)
        #expect(m.consume(bundleID: "com.apple.Notes") == .devanagari)
        // Next turn in the same app: remembered.
        #expect(m.resolve(bundleID: "com.apple.Notes") == .devanagari)
        // Another app: the LANG1 default.
        #expect(m.resolve(bundleID: "com.tinyspeck.slackmacgap") == .roman)
        #expect(AppScriptMemory(store: store).all == ["com.apple.Notes": .devanagari])
    }

    @Test func theTurnPickWinsOverTheLandingAppAndIsSpentAfterOneTurn() {
        let store = InMemorySettingsStore()
        LanguagePreferences(languages: ["hi"]).save(to: store)
        let front = Front()
        let m = Self.model(store, front: front)
        m.choose(.mixed)
        #expect(m.consume(bundleID: "com.other.app") == .mixed)
        #expect(m.consume(bundleID: "com.other.app") == .roman)
    }

    @Test func augmentWritesTheScriptKey() {
        let store = InMemorySettingsStore()
        LanguagePreferences(languages: ["en", "hi"], scriptByLanguage: ["hi": .mixed]).save(to: store)
        let m = Self.model(store, front: Front())
        let ctx = m.augment(StageContext(appBundleID: "com.apple.Notes"))
        #expect(ctx.extra[ScriptOutputStage.Keys.script] == "mixed")
        let english = InMemorySettingsStore()
        LanguagePreferences(languages: ["en"]).save(to: english)
        #expect(Self.model(english, front: Front()).augment(StageContext()).extra[ScriptOutputStage.Keys.script] == nil)
    }

    @Test func memoryRejectsUnstorableBundleIDs() {
        let store = InMemorySettingsStore()
        AppScriptMemory(store: store).remember(.devanagari, for: "a=b")
        AppScriptMemory(store: store).remember(.devanagari, for: nil)
        #expect(AppScriptMemory(store: store).all.isEmpty)
    }

    @Test func runtimeChainsTheScriptOntoTheLandersContext() {
        let store = InMemorySettingsStore()
        LanguagePreferences(languages: ["hi"], scriptByLanguage: ["hi": .devanagari]).save(to: store)
        let runtime = LanguageRuntime(settings: store, environment: [:], scriptChoice: Self.model(store, front: Front()))
        var baseRan = false
        let chain = runtime.augmenter(after: { _, ctx in baseRan = true; return ctx })
        let ctx = chain([], StageContext(appBundleID: "x"))
        #expect(baseRan)
        #expect(ctx.extra[ScriptOutputStage.Keys.script] == "devanagari")
    }
}
