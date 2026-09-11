import Foundation
import Testing
import Shared
import Engine
import Pipeline
@testable import VoicePlusApp

/// R5.3 — Settings › Voice: the three-way refinement mode, what it persists, and the rule that a
/// mode may never claim a second pass that cannot run (V3 §9.7).
@Suite("Voice tab refinement mode (R5.3)")
@MainActor
struct VoiceRefinementSettingsTests {

    static let ready = RefinementReadiness(flagEnabled: true, systemReason: nil, weightsPresent: true)

    // MARK: The three-way setting

    @Test func theDefaultIsAutoWhenNobodyHasChosen() {
        let store = InMemorySettingsStore()
        #expect(RefinementSettings.mode(store) == .auto)
        #expect(RefinementSettings.mode(nil) == .auto, "no store at all still resolves to a mode")
        #expect(VoiceSettingsViewModel(store: store, readiness: Self.ready).mode == .auto)
    }

    @Test func allThreeModesAreOffered() {
        #expect(RefinementMode.allCases == [.auto, .always, .never])
    }

    @Test func choosingAModePersistsItUnderOneKey() {
        let store = InMemorySettingsStore()
        let model = VoiceSettingsViewModel(store: store, readiness: Self.ready)
        // `.auto` last on purpose: it is the resolved default, so it is only *written* when it is a
        // change from something else — which is the round trip that matters.
        for mode in [RefinementMode.always, .never, .auto] {
            model.mode = mode
            #expect(store.string(RefinementSettings.modeKey) == mode.rawValue)
            #expect(RefinementSettings.mode(store) == mode)
        }
    }

    /// The point of persistence: a new window, a new view model, the same choice.
    @Test func theChoiceSurvivesAFreshViewModel() {
        let store = InMemorySettingsStore()
        let first = VoiceSettingsViewModel(store: store, readiness: Self.ready)
        first.mode = .always
        let second = VoiceSettingsViewModel(store: store, readiness: Self.ready)
        #expect(second.mode == .always)

        second.mode = .never
        #expect(VoiceSettingsViewModel(store: store, readiness: Self.ready).mode == .never)
    }

    @Test func aStoreHoldingNonsenseFallsBackToAutoRatherThanCrashing() {
        let store = InMemorySettingsStore()
        store.set("sometimes", for: RefinementSettings.modeKey)
        #expect(RefinementSettings.mode(store) == .auto)
        #expect(VoiceSettingsViewModel(store: store, readiness: Self.ready).mode == .auto)
    }

    @Test func writingTheSameModeTwiceIsNotAWrite() {
        let store = InMemorySettingsStore()
        let model = VoiceSettingsViewModel(store: store, readiness: Self.ready)
        model.mode = .never
        store.set(nil, for: RefinementSettings.modeKey)   // clear the record of the first write
        model.mode = .never                                // same value: nothing to persist
        #expect(store.string(RefinementSettings.modeKey) == nil)
    }

    // MARK: The mode reaches the gate

    @Test func theModeIsTheGateTheStoreHandsOut() {
        let store = InMemorySettingsStore()
        RefinementSettings.setMode(.always, store: store)
        #expect(RefinementSettings.gate(store).mode == .always)
        RefinementSettings.setMode(.never, store: store)
        #expect(RefinementSettings.gate(store).mode == .never)
        #expect(RefinementSettings.gate(store).settings == .default,
                "thresholds come from the settings struct, not from the tab")
    }

    @Test func autoGivesTheGateTheDecisionAndNeverTakesItAway() {
        let store = InMemorySettingsStore()
        let model = VoiceSettingsViewModel(store: store, readiness: Self.ready)
        let uncertain = RefinementGateSignals(hypothesis: "send the deck to prea", confidence: 0.3,
                                              promptTerms: 20, segmentSeconds: 4)
        let confident = RefinementGateSignals(hypothesis: "send the deck to Priya", confidence: 0.95,
                                              promptTerms: 20, segmentSeconds: 4)
        model.mode = .auto
        #expect(model.gate().decide(uncertain).shouldRefine)
        #expect(model.gate().decide(confident).shouldRefine == false)

        model.mode = .always
        #expect(model.gate().decide(confident).reason == .modeAlways)

        model.mode = .never
        #expect(model.gate().decide(uncertain).reason == .modeNever)
    }

    // MARK: Availability — V3 §9.7

    @Test func anUnavailableSecondPassIsSaidPlainlyAndNotOffered() {
        let store = InMemorySettingsStore()
        let cases: [(RefinementReadiness, String)] = [
            (RefinementReadiness(flagEnabled: false, systemReason: nil, weightsPresent: true), "flag"),
            (RefinementReadiness(flagEnabled: true, systemReason: nil, weightsPresent: false), "1.2 GB"),
            (RefinementReadiness(flagEnabled: true, systemReason: "it needs macOS 15 or later",
                                 weightsPresent: true), "macOS 15"),
        ]
        for (readiness, expected) in cases {
            let model = VoiceSettingsViewModel(store: store, readiness: readiness)
            #expect(model.isAvailable == false)
            #expect(model.note.contains(expected), "the note did not name the missing piece: \(model.note)")
            // Even "Always" refines nothing when there is nothing to refine with.
            model.mode = .always
            let decision = model.gate().decide(RefinementGateSignals(hypothesis: "anything", confidence: 0.1))
            #expect(decision.shouldRefine == false)
            #expect(decision.reason == .modeNever)
        }
    }

    @Test func aReadyMacSaysSoWithoutQualification() {
        let model = VoiceSettingsViewModel(store: InMemorySettingsStore(), readiness: Self.ready)
        #expect(model.isAvailable)
        #expect(model.note.contains("Ready"))
    }

    /// The choice is still recorded while the feature is unavailable — the user's intent outlives a
    /// missing download — but it changes nothing until the pass can run.
    @Test func theChoiceIsRememberedEvenWhileTheFeatureCannotRun() {
        let store = InMemorySettingsStore()
        let unavailable = RefinementReadiness(flagEnabled: false, systemReason: nil, weightsPresent: false)
        let model = VoiceSettingsViewModel(store: store, readiness: unavailable)
        model.mode = .always
        #expect(RefinementSettings.mode(store) == .always)
        #expect(VoiceSettingsViewModel(store: store, readiness: Self.ready).gate().mode == .always)
    }

    // MARK: The flag behind all of it

    /// Task R5.3 item 3: confirm the flag exists and is off. It is resolved by id — `qwenRefinement`
    /// is not in `FeatureFlag.all`, so an unknown-id lookup returns its effective default, which is
    /// off. Registering it as a listed flag means editing `Shared/Types/FeatureFlag.swift`, which
    /// belongs to whoever sets the default from R5.4's table.
    @Test func theQwenRefinementFlagIsOffByDefault() {
        let flags = FeatureFlagService.inMemory()
        #expect(ModelStack.refinementFlagID == "qwenRefinement")
        #expect(flags.isEnabled(id: ModelStack.refinementFlagID) == false)
        #expect(RefinementReadiness.resolve(flags: flags).flagEnabled == false)
        #expect(RefinementReadiness.resolve(flags: nil).flagEnabled == false,
                "no flag service means no refinement, never an assumed yes")

        // And when it is turned on explicitly, that is the only thing that changes.
        let on = FeatureFlagService.inMemory([ModelStack.refinementFlagID: true])
        #expect(on.isEnabled(id: ModelStack.refinementFlagID))
        #expect(RefinementReadiness.resolve(flags: on).flagEnabled)
    }

    /// The default readiness on this machine, whatever it is, must be describable without claiming
    /// anything false: the flag is off, so the note talks about the flag.
    @Test func theStockInstallSaysTheFlagIsWhatIsHoldingItBack() {
        let readiness = RefinementReadiness.resolve(flags: FeatureFlagService.inMemory())
        #expect(readiness.isAvailable == false)
        if readiness.systemReason == nil {
            #expect(readiness.note.contains("qwenRefinement"))
        }
    }
}
