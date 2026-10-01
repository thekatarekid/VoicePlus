import Engine
import Foundation
import Pipeline
import Testing
@testable import VoicePlusApp

/// V5 LANG1 — the Languages step (after Try dictation), its settings and its consumers.
@Suite struct LanguageOnboardingTests {
    typealias M = OnboardingStateMachine

    /// A machine standing on Try dictation with everything before it resolved.
    static func atFirstDictation(languagesConfirmed: Bool = false) -> M {
        var m = M(initialStatuses: [.microphone: .granted, .accessibility: .granted], languagesConfirmed: languagesConfirmed)
        m.handle(.modelPresenceChanged(true))
        m.resume(at: .firstDictation)
        precondition(m.step == .firstDictation)
        return m
    }

    static let prefs = LanguagePreferences(languages: ["en", "hi"], scriptByLanguage: ["hi": .mixed], spelling: .enIN)

    @Test func stepOrderPutsLanguagesBetweenTryAndVoice() {
        #expect(M.Step.allCases == [.welcome, .microphone, .accessibility, .model, .firstDictation, .languages, .voice, .done])
        #expect(M.stepCount == 8)
    }

    @Test func continueFromTryLandsOnLanguagesAndAsksForThePrefill() {
        var m = Self.atFirstDictation()
        #expect(m.handle(.next) == [.prefillLanguages])
        #expect(m.step == .languages)
        m.handle(.languagesPrefilled(Self.prefs))
        #expect(m.languageChoice == Self.prefs)
        // A second prefill never overwrites what is on screen.
        m.handle(.languagesPrefilled(LanguagePreferences()))
        #expect(m.languageChoice == Self.prefs)
    }

    @Test func continueSavesTheChoiceAndGoesToVoice() {
        var m = Self.atFirstDictation()
        m.handle(.next)
        m.handle(.languagesPrefilled(LanguagePreferences(languages: ["en"])))
        m.handle(.setLanguages(Self.prefs))
        m.handle(.setLanguages(LanguagePreferences(languages: [])))   // refused: never zero languages
        #expect(m.languageChoice == Self.prefs)
        #expect(m.handle(.next) == [.saveLanguages(Self.prefs)])
        #expect(m.step == .voice)
        #expect(m.languagesConfirmed)
        #expect(!m.skippedSteps.contains(.languages))
    }

    @Test func skipSavesNothing() {
        var m = Self.atFirstDictation()
        m.handle(.next)
        #expect(m.handle(.skip) == [])
        #expect(m.step == .voice)
        #expect(m.skippedSteps.contains(.languages))
    }

    @Test func skippingTryGoesToLanguages() {
        var m = Self.atFirstDictation()
        m.handle(.skip)
        #expect(m.step == .languages)
    }

    @Test func backWalksThroughLanguagesWithoutFallingThrough() {
        var m = Self.atFirstDictation(languagesConfirmed: true)
        m.handle(.next)
        #expect(m.step == .voice, "answered already: the forward path passes through")
        m.handle(.back)
        #expect(m.step == .languages, "Back lands on the step, not past it")
        m.handle(.back)
        #expect(m.step == .firstDictation)
    }

    @Test func resumeOpensOnLanguagesEvenWhenAnswered() {
        var m = M(initialStatuses: [.microphone: .granted], languagesConfirmed: true)
        #expect(m.resume(at: .languages) == [.prefillLanguages], "the saved answer is loaded onto the step")
        #expect(m.step == .languages, "answered, but resuming lands on the step rather than past it")
        var fresh = M(initialStatuses: [.microphone: .granted])
        #expect(fresh.resume(at: .languages) == [.prefillLanguages])
    }

    @Test func resumeStoreRoundTripsTheNewStep() {
        let store = InMemorySettingsStore()
        OnboardingResume(store: store).save(.languages)
        #expect(OnboardingResume(store: store).step == .languages)
    }

    // MARK: Settings round-trip

    @Test func preferencesRoundTripThroughSettings() {
        let store = InMemorySettingsStore()
        #expect(LanguagePreferences.load(store) == nil)
        Self.prefs.save(to: store)
        #expect(store.string(SettingsKeys.languages) == "en,hi")
        #expect(store.string(SettingsKeys.scriptByLanguage) == "hi=mixed")
        #expect(store.string(SettingsKeys.spellingVariant) == "en-IN")
        #expect(LanguagePreferences.load(store) == Self.prefs)
    }

    @Test func scriptDefaultsToRomanAndOnlyHindiHasAChoice() {
        let p = LanguagePreferences(languages: ["en", "hi", "fr"], scriptByLanguage: ["fr": .devanagari])
        #expect(p.script(for: "hi") == .roman)
        #expect(p.script(for: "fr") == .roman)
        #expect(LanguagePreferences.option(for: "hi").hasScriptChoice)
        #expect(!LanguagePreferences.option(for: "en").hasScriptChoice)
        #expect(LanguagePreferences.catalogue.allSatisfy { !$0.name.unicodeScalars.contains { $0.properties.isEmojiPresentation } })
    }

    @Test func prefillReadsPreferredLanguagesAndInputSources() {
        let p = LanguagePreferences.prefill(preferredLanguages: ["en-IN", "en-GB"], inputSourceLanguages: ["hi", "en"])
        #expect(p.languages == ["en", "hi"])
        #expect(p.spelling == .enIN)
        #expect(LanguagePreferences.prefill(preferredLanguages: ["en-GB"], inputSourceLanguages: []).spelling == .enGB)
        #expect(LanguagePreferences.prefill(preferredLanguages: [], inputSourceLanguages: []).languages == ["en"])
    }

    @Test @MainActor func viewModelShowsTheSavedAnswerOnReturn() {
        let deps = OnboardingDependencies.mock()
        Self.prefs.save(to: deps.settingsStore)
        OnboardingResume(store: deps.settingsStore).save(.languages)
        let vm = OnboardingViewModel(dependencies: deps)
        #expect(vm.machine.languageChoice == Self.prefs)
        vm.teardown()
    }

    @Test @MainActor func viewModelPrefillsAndPersists() {
        var deps = OnboardingDependencies.mock()
        deps.languageEnvironment = FixedLanguageEnvironment(preferredLanguages: ["en-IN"], inputSourceLanguages: ["hi"])
        let store = deps.settingsStore
        OnboardingResume(store: store).save(.languages)
        let vm = OnboardingViewModel(dependencies: deps)
        #expect(vm.step == .languages)
        #expect(vm.machine.languageChoice?.languages == ["en", "hi"])
        vm.send(.next)
        #expect(LanguagePreferences.load(store)?.languages == ["en", "hi"])
        #expect(LanguagePreferences.load(store)?.spelling == .enIN)
        vm.teardown()
    }

    // MARK: Consumers

    @Test func consumersReadTheAnswers() {
        let en = LanguagePreferences(languages: ["en"], spelling: .enUS)
        #expect(en.detectorConstraint == [.english])
        #expect(en.qwenHint == .named("en"))
        #expect(en.itnLocale == .en)
        #expect(en.defaultTurnScript == nil)
        #expect(en.isEnglishOnly)
        #expect(en.asrRoutes == [.parakeetV3])

        #expect(Self.prefs.detectorConstraint == [.english, .hindi])
        #expect(Self.prefs.qwenHint == .automatic)
        #expect(Self.prefs.itnLocale == .hiEn)
        #expect(Self.prefs.defaultTurnScript == .mixed)
        #expect(Self.prefs.asrRoutes == [.parakeetV3, .hinglish])
        #expect(LanguagePreferences(languages: ["ja"]).asrRoutes == [.multilingual])
    }

    @Test func runtimeAppliesTheITNLocaleUnlessPinned() {
        // Pure: `ITNStage.defaultLocale` is process-wide and other suites set it in parallel.
        let prefs = LanguagePreferences(languages: ["en"], spelling: .enIN)
        #expect(LanguageRuntime.itnLocale(prefs, environment: [:]) == .enIN)
        #expect(LanguageRuntime.itnLocale(prefs, environment: ["VOICEPLUS_ITN_LOCALE": "en_US"]) == nil)
        #expect(LanguageRuntime.itnLocale(nil, environment: [:]) == nil)
    }

    @Test func runtimeConstrainsTheDetector() {
        let store = InMemorySettingsStore()
        LanguagePreferences(languages: ["en"]).save(to: store)
        let runtime = LanguageRuntime(settings: store, environment: [:])
        var seen: Set<SpokenLanguage>??
        runtime.onConstraintChange = { seen = .some($0) }
        runtime.apply()
        #expect(runtime.currentConstraint == [.english])
        #expect(seen == .some([.english]))
    }
}
