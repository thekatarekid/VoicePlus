import Engine
import Foundation
import Testing
@testable import VoicePlusApp

/// R6.1 — there is no model picker any more. R6.2 (DESIGN §11.1) went further: the install is not
/// a *step* either. It used to be its own screen (`modelInstall`, née `modelChoice`) with Continue
/// held shut until the stack landed — exactly the "blocking progress screen" DESIGN §11 forbids.
/// The install now starts the instant onboarding opens and runs in the background for the rest of
/// the walk; every step is free to say how far along it is (`modelInstallStatusLine`), and none of
/// them may ever refuse to continue because of it.
///
/// What is on disk is kept. Nothing is re-downloaded and no manifest is rewritten — see
/// `ModelStackInstallTests` in `EngineTests` for the on-disk half of that promise.
@Suite("Onboarding model install — one stack, no picker, never a wall")
@MainActor
struct OnboardingModelInstallTests {
    typealias M = OnboardingStateMachine

    /// A fresh view model. The install starts itself the moment it is constructed — no step, no
    /// walk, needs to be reached first.
    private func installViewModel(installed: Set<ModelID> = [],
                                  hold: (@Sendable () async -> Void)? = nil)
        -> (OnboardingViewModel, OnboardingMockModelManager) {
        var deps = OnboardingDependencies.mock()
        let models = OnboardingMockModelManager(installed: installed)
        models.hold = hold
        deps.models = models
        let vm = OnboardingViewModel(dependencies: deps)
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
        // Nothing to choose, nothing to press: one event starts the one install.
        #expect(m.handle(.installModels) == [.checkModelPresence, .startDownload, .checkRecognizerReadiness])
        #expect(ModelStack.models == [.parakeetTDTv3, .parakeetEOU160])
        #expect(m.installRequested)
        // A second ask while it is running fetches nothing a second time — it still re-checks
        // presence and readiness (cheap, and always safe), but never starts a second download.
        #expect(m.handle(.installModels) == [.checkModelPresence, .checkRecognizerReadiness])
        #expect(m.handle(.installModels) == [.checkModelPresence, .checkRecognizerReadiness])
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
        #expect(vm.machine.stackInstalled)
        #expect(vm.machine.modelInstallStatusLine == nil, "nothing left to say once it's here")
        vm.teardown()
    }

    /// The install starts on its own — the user is not asked to press anything for the one thing
    /// the app cannot work without.
    @Test func theInstallStartsWithoutBeingAsked() async throws {
        let gate = InstallGate()
        let (vm, _) = installViewModel(hold: { await gate.wait() })
        try await waitUntil { vm.machine.download.isInFlight }
        #expect(vm.downloadLine?.contains("Parakeet") == true, "the bar names the real model")
        gate.open()
        try await waitUntil { vm.machine.stackInstalled }
        vm.teardown()
    }

    // MARK: What is on disk is kept

    @Test func anExistingInstallIsNotDownloadedAgain() async throws {
        let (vm, models) = installViewModel(installed: Set(ModelStack.models))
        #expect(vm.machine.stackInstalled, "what is already here needs no download")
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

    // MARK: Never a blocking progress screen (DESIGN §11.1)

    /// The whole point of R6.2's rewrite: an install that is nowhere near done must never be a
    /// reason Continue refuses to fire, on Welcome or anywhere else.
    @Test func continueIsNeverShutByAnUnfinishedInstall() async throws {
        let gate = InstallGate()
        let (vm, _) = installViewModel(hold: { await gate.wait() })
        try await waitUntil { vm.machine.download.isInFlight }

        #expect(!vm.machine.stackInstalled, "3% is not a working model")
        #expect(vm.machine.modelInstallStatusLine?.contains("installing") == true)
        vm.send(.next)   // Welcome → Microphone; the install is nowhere near done
        #expect(vm.step == .microphone, "an unfinished install must never refuse Continue")

        gate.open()
        try await waitUntil { vm.machine.stackInstalled }
        #expect(vm.machine.modelInstallStatusLine == nil)
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
        #expect(!vm.machine.stackInstalled)
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
        try await waitUntil { if case .failed = vm.machine.download { return true }; return false }
        #expect(!vm.machine.stackInstalled)
        #expect(vm.machine.modelInstallStatusLine?.contains("didn't finish installing") == true)

        models.failDownload = false
        vm.send(.installModels)
        try await waitUntil { models.isStackInstalled }
        #expect(vm.machine.download == .installed)
        vm.teardown()
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
