import Engine
import Foundation
import Pipeline
import Providers
import Shared
import Testing
@testable import VoicePlusApp

/// V5 LANG1 follow-up — cleanup model switch, per-language P-series, per-app language memory,
/// Settings › Languages.
@Suite struct LanguageFollowUpTests {
    static let hinglish = LanguagePreferences(languages: ["en", "hi"], scriptByLanguage: ["hi": .roman], spelling: .enIN)

    // MARK: Fakes

    final class FakeShared: TextGenerator, @unchecked Sendable {
        let id: ProviderID = "fake.shared"
        let displayName = "fake shared"
        let capabilities: ProviderCapabilities = [.pipeline]
        let costClass: CostClass = .free
        let privacyClass: PrivacyClass = .onDevice
        var available = true
        private let lock = NSLock()
        private var _calls: [(system: String, stage: StageID)] = []
        var calls: [(system: String, stage: StageID)] { lock.withLock { _calls } }
        func isAvailable() async -> Bool { available }
        func generate(prompt: String, system: String, stage: StageID) async throws -> (text: String, bytesOut: Int, bytesIn: Int, host: String) {
            lock.withLock { _calls.append((system, stage)) }
            return ("multilingual: " + prompt, 0, 0, "on-device")
        }
    }

    final class FakeEnglish: CleanupGenerating, @unchecked Sendable {
        let promptStyle: CleanupPromptStyle = .speakoFlow
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.withLock { _count } }
        func cleanup(_ prompt: CleanupPrompt, context: StageContext) async throws -> String {
            lock.withLock { _count += 1 }
            return "english: " + prompt.user
        }
    }

    static func generator(choice: CleanupModelChoice?, ready: Bool = true, store: SettingsStore = InMemorySettingsStore(),
                          shared: FakeShared = FakeShared(), english: FakeEnglish = FakeEnglish())
        -> (LanguageAwareCleanupGenerator, RoutingTable) {
        let table = RoutingTable(providers: [], logger: InMemoryNetworkLogger())
        table.register(MultilingualCleanupProvider(shared: { shared }))
        let g = LanguageAwareCleanupGenerator(english: english, table: table, settings: store,
                                              turnChoice: { choice }, multilingualReady: { ready })
        return (g, table)
    }

    // MARK: Cleanup model switch

    @Test func cleanupModelFollowsTheLanguages() {
        #expect(LanguagePreferences(languages: ["en"]).cleanupModel() == .english)
        #expect(Self.hinglish.cleanupModel() == .multilingual)
        #expect(LanguagePreferences(languages: ["fr"]).cleanupModel() == .multilingual)
        #expect(Self.hinglish.cleanupModel(turnLanguage: "en") == .english)
        #expect(Self.hinglish.cleanupModel(turnLanguage: "hi") == .multilingual)
    }

    @Test func nonEnglishTurnGoesToTheSharedModelWithALanguageLine() async throws {
        let shared = FakeShared(), english = FakeEnglish()
        let (g, _) = Self.generator(choice: .multilingual, shared: shared, english: english)
        #expect(g.promptStyle == .delimited)
        var ctx = StageContext()
        ctx.extra[LanguageTurnKeys.languages] = "hi,en"
        let out = try await g.cleanup(CleanupPrompt(system: "RULES", user: "kya scene hai", style: .delimited), context: ctx)
        #expect(out == "multilingual: kya scene hai")
        #expect(english.count == 0)
        let call = try #require(shared.calls.first)
        #expect(call.stage == .style)   // CU8's name for Hinglish/style cleanup
        #expect(call.system.hasPrefix("RULES"))
        #expect(call.system.contains("Hindi and English"))
        #expect(call.system.contains("Romanised Hindi is Hindi"))
    }

    @Test func englishTurnUnansweredPinnedOrMissingModelKeepTheEnglishPath() async throws {
        for (choice, ready) in [(CleanupModelChoice.english, true), (nil, true), (.multilingual, false)] {
            let english = FakeEnglish()
            let (g, _) = Self.generator(choice: choice, ready: ready, english: english)
            #expect(g.promptStyle == .speakoFlow)
            let out = try await g.cleanup(CleanupPrompt(system: "S", user: "hello", style: .speakoFlow), context: StageContext())
            #expect(out == "english: hello")
            #expect(english.count == 1)
        }
        // A provider pinned for cleanup wins: the English generator handles pins.
        let store = InMemorySettingsStore()
        store.set("provider:ollama", for: SettingsKeys.routingPrefix + StageID.cleanup.rawValue)
        let (pinned, _) = Self.generator(choice: .multilingual, store: store)
        #expect(pinned.route() == .english)
    }

    @Test func turnContextOverridesTheRuntimeChoice() {
        let (g, _) = Self.generator(choice: .multilingual)
        var ctx = StageContext()
        ctx.extra[LanguageTurnKeys.cleanupModel] = CleanupModelChoice.english.rawValue
        #expect(g.route(context: ctx) == .english)
    }

    @Test func multilingualRouteIsNeverInAnAutoChain() async {
        let (_, table) = Self.generator(choice: .multilingual)
        #expect(!table.chain(for: .style).contains { $0.id == MultilingualCleanupProvider.providerID })
        #expect(!table.chain(for: .cleanup).contains { $0.id == MultilingualCleanupProvider.providerID })
        let provider = MultilingualCleanupProvider(shared: { FakeShared() })
        await #expect(throws: ProviderError.self) {
            _ = try await provider.complete(stage: .style, spans: [], context: StageContext())
        }
    }

    @Test func languageLineNamesTheLanguages() {
        #expect(LanguageAwareCleanupGenerator.languageLine(nil) == "")
        #expect(LanguageAwareCleanupGenerator.languageLine("fr").contains("uses French."))
        #expect(LanguageAwareCleanupGenerator.languageLine("de,fr,es").contains("German, French and Spanish"))
    }

    // MARK: Per-app language memory

    @Test func memoryLearnsFromAgreeingTurnsAndPinsWin() {
        let store = InMemorySettingsStore()
        let m = AppLanguageMemory(store: store)
        let app = "net.whatsapp.WhatsApp"
        m.record("hi", for: app); m.record("en", for: app); m.record("hi", for: app)
        #expect(m.learnedLanguage(for: app) == nil)          // 2 of 3
        m.record("hi", for: app)
        #expect(m.learnedLanguage(for: app) == "hi")         // 3 of 4
        #expect(m.language(for: app, chosen: ["en", "hi"]) == "hi")
        #expect(m.language(for: app, chosen: ["en"]) == nil)            // one language: nothing to remember
        #expect(m.language(for: app, chosen: ["en", "fr"]) == nil)      // not chosen any more
        for _ in 0..<5 { m.record("en", for: app) }
        #expect(m.history[app]?.count == AppLanguageMemory.historyLength)
        #expect(m.learnedLanguage(for: app) == "en")
        m.pin("hi", for: app)
        #expect(m.language(for: app, chosen: ["en", "hi"]) == "hi")
        m.pin(nil, for: app)
        #expect(m.pinnedLanguage(for: app) == nil)
        m.forget(app)
        #expect(m.apps.isEmpty)
        m.record("hi", for: "bad,id")
        #expect(m.apps.isEmpty)
    }

    @Test func classifierPicksTheChosenLanguage() {
        #expect(TurnLanguageClassifier.classify("kal meeting mein milte hain yaar", chosen: ["en", "hi"]) == "hi")
        #expect(TurnLanguageClassifier.classify("please send the report by Friday", chosen: ["en", "hi"]) == "en")
        #expect(TurnLanguageClassifier.classify("ok thanks", chosen: ["en", "hi"]) == nil)       // too short
        #expect(TurnLanguageClassifier.classify("please send the report", chosen: ["en"]) == nil)  // one language
        #expect(TurnLanguageClassifier.classify("Bonjour, je voudrais réserver une table pour ce soir", chosen: ["en", "fr"]) == "fr")
        #expect(TurnLanguageClassifier.classify("I would like to book a table for tonight please", chosen: ["en", "fr"]) == "en")
    }

    @Test func narrowingKeepsEnglishBesideHindi() {
        #expect(Self.hinglish.narrowed(to: "hi").languages == ["hi", "en"])
        #expect(Self.hinglish.narrowed(to: "en").languages == ["en"])
        #expect(Self.hinglish.narrowed(to: "fr") == Self.hinglish)
        #expect(LanguagePreferences(languages: ["hi", "fr"]).narrowed(to: "hi").languages == ["hi"])
    }

    @Test func runtimeWritesTheTurnsLanguagesAndLearns() {
        let store = InMemorySettingsStore()
        Self.hinglish.save(to: store)
        let runtime = LanguageRuntime(settings: store, environment: [:])
        let app = "com.apple.mail"
        let span = { (t: String) in TranscriptSpan(text: t, confidence: 1, audioRange: 0...1, provenance: [.asr]) }

        let ctx = runtime.languageContext([span("please send the report by Friday")], StageContext(appBundleID: app))
        #expect(ctx.extra[LanguageTurnKeys.cleanupModel] == "english")
        #expect(ctx.extra[LanguageTurnKeys.languages] == "en")
        #expect(ctx.extra[ITNStage.Keys.locale] == ITNLocale.enIN.rawValue)
        #expect(runtime.turnCleanupChoice == .english)
        #expect(AppLanguageMemory(store: store).history[app] == ["en"])

        let hi = runtime.languageContext([span("kal meeting mein milte hain yaar")], StageContext(appBundleID: app))
        #expect(hi.extra[LanguageTurnKeys.cleanupModel] == "multilingual")
        #expect(hi.extra[ITNStage.Keys.locale] == ITNLocale.hiEn.rawValue)
        #expect(runtime.turnCleanupChoice == .multilingual)

        // A short turn says nothing itself: the app's remembered language decides.
        AppLanguageMemory(store: store).pin("en", for: app)
        let short = runtime.languageContext([span("ok")], StageContext(appBundleID: app))
        #expect(short.extra[LanguageTurnKeys.appLanguage] == "en")
        #expect(short.extra[LanguageTurnKeys.cleanupModel] == "english")
        // VOICEPLUS_ITN_LOCALE pins ITN: no per-turn locale.
        let pinned = LanguageRuntime(settings: store, environment: ["VOICEPLUS_ITN_LOCALE": "en"])
        #expect(pinned.languageContext([span("ok")], StageContext(appBundleID: app)).extra[ITNStage.Keys.locale] == nil)
    }

    @Test func runtimeIsInertWhenUnanswered() {
        let runtime = LanguageRuntime(settings: InMemorySettingsStore(), environment: [:])
        let ctx = runtime.languageContext([], StageContext(appBundleID: "x"))
        #expect(ctx.extra.isEmpty)
        #expect(runtime.turnCleanupChoice == nil)
    }

    @Test func asrRouteFollowsTheFrontmostAppsLanguage() {
        let store = InMemorySettingsStore()
        Self.hinglish.save(to: store)
        var front = "com.apple.mail"
        let routing = LanguageASRRouting(settings: { store }, root: FileManager.default.temporaryDirectory,
                                         frontmostBundleID: { front })
        #expect(routing.plan == Self.hinglish.asrRoutePlan)            // nothing remembered yet
        AppLanguageMemory(store: store).pin("en", for: "com.apple.mail")
        #expect(routing.plan == .parakeetOnly)
        front = "net.whatsapp.WhatsApp"
        #expect(routing.plan == Self.hinglish.asrRoutePlan)
    }

    // MARK: P-series per language

    @Test func dictionaryPlanFollowsLanguagesAndSpelling() {
        let unanswered = LanguageDictionaryPlan(nil)
        #expect(unanswered.scowl == .us && unanswered.englishLists && !unanswered.hindiSafeCasing && !unanswered.transliteration)
        let gb = LanguageDictionaryPlan(LanguagePreferences(languages: ["en"], spelling: .enGB))
        #expect(gb.scowl == .gbs)
        #expect(gb.scowl.downloadURL.absoluteString.contains("spelling=GBs"))
        #expect(gb.scowl.fileName != ScowlVariant.us.fileName)
        let hi = LanguageDictionaryPlan(LanguagePreferences(languages: ["hi"], scriptByLanguage: ["hi": .devanagari]))
        #expect(hi.hindiSafeCasing && hi.transliteration && !hi.englishLists)
        #expect(!LanguageDictionaryPlan(Self.hinglish).transliteration)   // Roman: no P6
    }

    @Test func hindiSafeCasingDropsRomanisedHindiKeys() {
        let lexicon = CasingLexicon(["GitHub", "Kahan", "iPhone"])
        let safe = LanguageDictionaryPlan.hindiSafe(lexicon)
        #expect(safe.canonicalForm(of: "github") == "GitHub")
        #expect(safe.canonicalForm(of: "iphone") == "iPhone")
        #expect(safe.canonicalForm(of: "kahan") == nil)
    }

    @Test func dictionaryPlanAppliesOnlyWhatItOwns() {
        let dictionaries = PublicDictionaries()
        dictionaries.setCasing(CasingLexicon(["GitHub", "Kahan"]))
        LanguageDictionaryPlan(LanguagePreferences(languages: ["en"])).apply(to: dictionaries)
        #expect(dictionaries.casing.canonicalForm(of: "kahan") == "Kahan")   // not ours: untouched
        LanguageDictionaryPlan(Self.hinglish).apply(to: dictionaries)
        #expect(dictionaries.casing.canonicalForm(of: "kahan") == nil)
    }

    // MARK: Settings › Languages

    @Test func settingsPageIsReachable() {
        #expect(SettingsSubpage.allCases.contains(.languages))
        #expect(SettingsSubpage.languages.title == "Languages")
        #expect(SettingsSubpage.languages.pageTitle == "Languages")
        #expect(SettingsSubpage.languages.pageSubtitle == LanguagesCopy.subtitle)
        #expect(SettingsReachability.allItems.contains { $0.subpage == .languages && $0.marker == "LanguagesSettingsPage(" })
        #expect(OnboardingCopy.languagesLater.contains("Settings › Languages"))
    }

    @MainActor @Test func settingsModelEditsAndSaves() {
        let store = InMemorySettingsStore()
        let model = LanguagesSettingsModel(store: store,
                                           environment: FixedLanguageEnvironment(preferredLanguages: ["en-GB"]),
                                           appName: { "App \($0)" }, multilingualReady: { false })
        #expect(!model.answered)
        #expect(model.prefs.languages == ["en"] && model.prefs.spelling == .enGB)
        #expect(LanguagePreferences.load(store) == nil)        // showing the prefill saves nothing

        model.remove("en")
        #expect(model.notice == LanguagesCopy.lastLanguage)
        #expect(LanguagePreferences.load(store) == nil)

        model.add("hi")
        #expect(model.answered)
        #expect(LanguagePreferences.load(store)?.languages == ["en", "hi"])
        model.hindiScript = .devanagari
        #expect(LanguagePreferences.load(store)?.script(for: "hi") == .devanagari)
        model.spelling = .enIN
        #expect(LanguagePreferences.load(store)?.spelling == .enIN)
        #expect(model.speechLines.count == 2)
        #expect(model.cleanupLine.contains("Settings › Computer use"))
        #expect(model.canDownloadList == !ScowlVariant.gbs.isInstalled)

        AppLanguageMemory(store: store).record("hi", for: "net.whatsapp.WhatsApp")
        model.reloadApps()
        #expect(model.apps.map(\.name) == ["App net.whatsapp.WhatsApp"])
        #expect(model.appOptions == ["", "en", "hi"])
        model.setLanguage("hi", for: "net.whatsapp.WhatsApp")
        #expect(model.apps.first?.pinned == "hi")
        model.setLanguage("", for: "net.whatsapp.WhatsApp")
        #expect(model.apps.first?.pinned == nil)
        model.forget("net.whatsapp.WhatsApp")
        #expect(model.apps.isEmpty)

        model.remove("hi")
        #expect(LanguagePreferences.load(store)?.languages == ["en"])
        #expect(LanguagePreferences.load(store)?.scriptByLanguage["hi"] == nil)
    }
}
