import Engine
import Foundation
import Testing
@testable import VoicePlusApp

/// R6.1 — there is no model picker any more.
///
/// Until this task onboarding showed three options (`fast` = TDT-CTC 110M, `balanced` = TDT v3,
/// `best` = TDT v3 + EOU), each with its own Download button, its own progress bar and its own
/// "Installed" badge. Two of the three described *fallbacks* as products, the only correct answer
/// was always the third, and the screen's whole job was to get the user to pick it. So: one stack
/// (`ModelStack.models`), installed on first run, using the same progress, estimate and
/// failure/retry reporting the picker's rows used.
///
/// What is on disk is kept. Nothing is re-downloaded and no manifest is rewritten — see
/// `ModelStackInstallTests` in `EngineTests` for the on-disk half of that promise.
@Suite("Onboarding model install — one stack, no picker")
@MainActor
struct OnboardingModelInstallTests {
    typealias M = OnboardingStateMachine

    /// Walks a fresh view model to the install step (no permissions granted, so two skips).
    private func installViewModel(installed: Set<ModelID> = [],
                                  hold: (@Sendable () async -> Void)? = nil)
        -> (OnboardingViewModel, OnboardingMockModelManager) {
        var deps = OnboardingDependencies.mock()
        let models = OnboardingMockModelManager(installed: installed)
        models.hold = hold
        deps.models = models
        let vm = OnboardingViewModel(dependencies: deps)
        vm.send(.skip); vm.send(.skip)
        #expect(vm.step == .modelInstall)
        return (vm, models)
    }

    // MARK: There is no picker

    /// The acceptance criterion, stated in the only way a compiled language can state an absence:
    /// the state is singular. There is one `downloadState`, one `stackInstalled` flag, one install
    /// event — no option to select, and nothing keyed by option. `ModelTier` (`fast / balanced /
    /// best`), `chosenTier`, `installedTiers`, `explicitlyDownloadedTiers`, `downloadStates` and
    /// `SideEffect.selectModel` are all gone; this file would not compile if any of them survived.
    @Test func onboardingStateHasNoTierPicker() {
        var m = M()
        m.handle(.skip); m.handle(.skip)
        #expect(m.step == .modelInstall)
        // One stack, named by the catalog, in install order.
        #expect(ModelStack.models == [.parakeetTDTv3, .parakeetEOU160])
        // Entering the step asks for the one install by itself — nothing to choose, nothing to press.
        #expect(m.installRequested)
        // A second ask while it is running starts nothing: no way to queue a second download.
        #expect(m.handle(.installModels) == [])
        #expect(m.handle(.installModels) == [])
        // And the effects of entering the step are exactly: read the disk, install, name the recogniser.
        var fresh = M()
        fresh.handle(.skip)
        #expect(fresh.handle(.skip) == [.stopMicMonitoring, .checkModelPresence, .startDownload,
                                        .checkRecognizerReadiness])
    }

    /// Settings offers one local option too — the routing picker used to list "Local · Fast",
    /// "Local · Balanced" and "Local · Best", which was the tier picker wearing another hat.
    @Test func settingsOffersOneLocalOptionNotThree() {
        let vm = ModelsSettingsViewModel(store: InMemorySettingsStore(),
                                         models: OnboardingMockModelManager())
        let stage = RoutableStage.all.first { $0.acceptsLocal }!
        let locals = vm.options(for: stage).filter { $0 == .local }
        #expect(locals.count == 1)
        #expect(ProviderChoice.local.title == "Local (on this Mac)")
        // A value written by a build that still had tiers still reads back as "local".
        #expect(ProviderChoice(rawValue: "local:balanced") == .local)
        #expect(ProviderChoice(rawValue: "local") == .local)
    }

    /// The fallbacks stay in the catalog — the engine walks down to them — but Settings › Models
    /// never names them, because they are not something anybody can choose.
    @Test func settingsHidesTheFallbackModels() {
        let vm = ModelsSettingsViewModel(store: InMemorySettingsStore(),
                                         models: OnboardingMockModelManager.installed())
        #expect(vm.visibleModelIDs == ModelStack.models)
        #expect(!vm.visibleModelIDs.contains(.parakeetTDTCTC110m))
        #expect(!vm.visibleModelIDs.contains(.whisperSmall))
        #expect(vm.speechModelSummary.contains("Parakeet TDT 0.6B v3"))
        #expect(!vm.speechModelSummary.contains("Whisper"))
    }

    // MARK: A fresh install fetches exactly the one stack

    @Test func freshStateInstallsExactlyTheOneStack() async throws {
        let (vm, models) = installViewModel()
        try await waitUntil { models.isStackInstalled }
        #expect(models.fetched == [ModelStack.models],
                "one install, of the two models in the stack, and nothing else")
        #expect(models.downloadCalls == 1)
        try await waitUntil { vm.machine.canContinueFromModelInstall }
        vm.send(.next)
        #expect(vm.step == .firstDictation)
        vm.teardown()
    }

    /// The install starts on its own — the user is not asked to press anything for the one thing
    /// the app cannot work without.
    @Test func theStepStartsTheInstallWithoutBeingAsked() async throws {
        let gate = InstallGate()
        let (vm, _) = installViewModel(hold: { await gate.wait() })
        try await waitUntil { vm.machine.download.isInFlight }
        #expect(vm.downloadLine?.contains("Parakeet") == true, "the bar names the real model")
        gate.open()
        try await waitUntil { vm.machine.canContinueFromModelInstall }
        vm.teardown()
    }

    // MARK: What is on disk is kept

    @Test func anExistingInstallIsNotDownloadedAgain() async throws {
        let (vm, models) = installViewModel(installed: Set(ModelStack.models))
        #expect(vm.machine.canContinueFromModelInstall, "what is already here needs no download")
        #expect(models.remainingStackBytes == 0)
        try await Task.sleep(for: .milliseconds(50))
        #expect(models.fetched.flatMap { $0 }.isEmpty, "not one byte re-fetched")
        #expect(vm.machine.download == .installed)
        vm.teardown()
    }

    /// Half a stack on disk (the shape of an install from before R6.1, which had TDT v3 from
    /// "Balanced" but no EOU model): only the missing half is fetched, and only its bytes are
    /// quoted.
    @Test func onlyTheMissingHalfIsFetched() async throws {
        let (vm, models) = installViewModel(installed: [.parakeetTDTv3])
        let eou = ModelCatalog.descriptor(.parakeetEOU160).approxBytes
        #expect(models.remainingStackBytes == eou,
                "the Parakeet TDT v3 already on disk must not be counted again")
        #expect(vm.remainingLabel == ByteText.short(eou))
        #expect(vm.isPartialDownload)
        try await waitUntil { models.isStackInstalled }
        #expect(models.fetched == [[.parakeetEOU160]])
        vm.teardown()
    }

    // MARK: Continue is gated on real presence

    @Test func continueIsShutUntilTheStackIsOnDisk() async throws {
        let gate = InstallGate()
        let (vm, _) = installViewModel(hold: { await gate.wait() })
        try await waitUntil { vm.machine.download.isInFlight }

        #expect(!vm.machine.canContinueFromModelInstall, "3 % is not a working model")
        let reason = try #require(vm.machine.continueBlockedReason)
        #expect(reason.contains("speech model"))
        #expect(reason.lowercased().contains("download"))
        vm.send(.next)
        #expect(vm.step == .modelInstall, "Continue must not fire while the model is still arriving")

        gate.open()
        try await waitUntil { vm.machine.canContinueFromModelInstall }
        #expect(vm.machine.continueBlockedReason == nil)
        vm.send(.next)
        #expect(vm.step == .firstDictation)
        vm.teardown()
    }

    // MARK: Cancel and retry

    @Test func cancelStopsTheInstallAndInstallsNothing() async throws {
        let gate = InstallGate()
        let (vm, models) = installViewModel(hold: { await gate.wait() })
        try await waitUntil { vm.machine.download.isInFlight }
        vm.send(.cancelDownload)
        #expect(vm.machine.download == .notStarted, "Cancel puts the screen back to Install")
        #expect(!vm.machine.installRequested, "and the screen must not still claim to be starting")
        gate.open()
        try await Task.sleep(for: .milliseconds(50))
        #expect(!models.isStackInstalled, "a cancelled download installs nothing")
        #expect(!vm.machine.canContinueFromModelInstall)
        // Install again: the same event, and it really does start a fetch this time.
        vm.send(.installModels)
        try await waitUntil { models.isStackInstalled }
        vm.teardown()
    }

    @Test func aFailedInstallSaysSoAndCanBeRetried() async throws {
        var deps = OnboardingDependencies.mock()
        let models = OnboardingMockModelManager()
        models.failDownload = true
        deps.models = models
        let vm = OnboardingViewModel(dependencies: deps)
        vm.send(.skip); vm.send(.skip)
        try await waitUntil { if case .failed = vm.machine.download { return true }; return false }
        #expect(!vm.machine.canContinueFromModelInstall)
        #expect(vm.machine.continueBlockedReason?.contains("didn't download") == true)

        models.failDownload = false
        vm.send(.installModels)
        try await waitUntil { models.isStackInstalled }
        #expect(vm.machine.download == .installed)
        vm.teardown()
    }

    // MARK: Skip stays available, and honest

    @Test func skipIsAllowedButSaysWhatItCosts() {
        var m = M()
        m.handle(.skip); m.handle(.skip)
        #expect(m.skipConsequence?.contains("dictation won't work") == true)
        m.handle(.skip)
        #expect(m.step == .firstDictation, "skipping remains a legitimate choice")
        #expect(m.skippedModelInstallWithoutModel, "the later screens must be able to say why nothing works")
    }

    @Test func skipWithTheStackPresentRaisesNoAlarm() {
        var m = M()
        m.handle(.skip); m.handle(.skip)
        m.handle(.modelPresenceChanged(true))
        #expect(m.skipConsequence == nil, "a warning that is always on is a warning nobody reads")
        m.handle(.skip)
        #expect(!m.skippedModelInstallWithoutModel)
    }
}

/// Holds a mock install open until the test lets it finish.
private final class InstallGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    func open() { lock.withLock { opened = true } }
    var isOpen: Bool { lock.withLock { opened } }
    func wait() async { while !isOpen { try? await Task.sleep(for: .milliseconds(5)) } }
}
