import Engine
import Foundation
import Testing
@testable import VoicePlusApp

/// Reported: "I only downloaded the best 900 MB model. It downloaded the Balanced itself."
///
/// It did not. "Best" *is* "Balanced" plus an end-of-utterance model, so completing Best completes
/// Balanced with nothing extra fetched. The bug was that the screen never said so — the overlap was
/// invisible before the download and looked like an unrequested one afterwards.
@Suite("Onboarding model picker — how the tiers overlap, said out loud")
@MainActor
struct OnboardingTierCompositionTests {
    private func pickerViewModel(installed: Set<ModelTier> = []) -> (OnboardingViewModel, OnboardingMockModelManager) {
        var deps = OnboardingDependencies.mock()
        let models = OnboardingMockModelManager(installed: installed)
        deps.models = models
        let vm = OnboardingViewModel(dependencies: deps)
        vm.send(.skip); vm.send(.skip)
        #expect(vm.step == .modelChoice)
        return (vm, models)
    }

    // MARK: The numbers on screen

    /// Every advertised total is the sum of that tier's catalog entries — no hardcoded figure that
    /// can drift, and 500 + 400 really is the 900 MB "Best" prints.
    @Test func displayedSizesAreTheRealPerModelTotals() {
        let tdt = ModelCatalog.descriptor(.parakeetTDTv3).approxBytes
        let eou = ModelCatalog.descriptor(.parakeetEOU160).approxBytes
        let tiny = ModelCatalog.descriptor(.parakeetTDTCTC110m).approxBytes

        #expect(ModelTier.fast.approximateBytes == tiny)
        #expect(ModelTier.balanced.approximateBytes == tdt)
        #expect(ModelTier.best.approximateBytes == tdt + eou)
        #expect(ModelTier.fast.sizeLabel == "110 MB")
        #expect(ModelTier.balanced.sizeLabel == "500 MB")
        #expect(ModelTier.best.sizeLabel == "900 MB")
        #expect(ModelTierComposition.incrementalBytes(for: .best) == eou)
        #expect(ModelTierComposition.incrementalBytes(for: .fast) == tiny, "Fast shares nothing")
    }

    /// Containment is read from the catalog, not asserted by a comment.
    @Test func bestContainsBalancedAndNothingElseDoes() {
        #expect(ModelTierComposition.includes(.balanced, in: .best))
        #expect(!ModelTierComposition.includes(.fast, in: .best))
        #expect(!ModelTierComposition.includes(.best, in: .balanced))
        #expect(!ModelTierComposition.includes(.best, in: .best), "a tier does not include itself")
        #expect(ModelTierComposition.includedTiers(in: .best) == [.balanced])
        #expect(ModelTierComposition.includedTiers(in: .fast).isEmpty)
    }

    // MARK: Said before the download

    @Test func theOverlapIsStatedUpFrontNotOnlyAfterwards() throws {
        let line = try #require(ModelTierComposition.compositionLine(for: .best))
        #expect(line.contains("Balanced"))
        #expect(line.contains("500 MB"), "the shared part is named with its size")
        #expect(line.contains("400 MB"), "and so is what Best actually adds")
        #expect(ModelTierComposition.compositionLine(for: .fast) == nil)
        #expect(ModelTierComposition.compositionLine(for: .balanced) == nil)
    }

    // MARK: Said afterwards, as a consequence of the user's own choice

    @Test func installingBestMarksBalancedAsIncludedNotAsItsOwnDownload() async throws {
        let (vm, models) = pickerViewModel()
        vm.send(.download(.best))
        try await waitUntil { vm.machine.installedTiers.contains(.best) }

        #expect(vm.machine.installedTiers.contains(.balanced))
        #expect(vm.machine.explicitlyDownloadedTiers == [.best], "the user pressed exactly one button")
        #expect(vm.installedBadge(for: .balanced) == "Included with Best")
        #expect(vm.installedBadge(for: .best) == "Installed")
        #expect(models.downloads == [.best], "one download, the one that was asked for")
        vm.teardown()
    }

    /// A tier the user fetched on its own keeps the plain badge, even once a superset lands too —
    /// crediting Best for a download the user made themselves would be its own small lie.
    @Test func aTierTheUserDownloadedHimselfIsNotCreditedToAnother() async throws {
        let (vm, _) = pickerViewModel()
        vm.send(.download(.balanced))
        try await waitUntil { vm.machine.installedTiers.contains(.balanced) }
        vm.send(.download(.best))
        try await waitUntil { vm.machine.installedTiers.contains(.best) }

        #expect(vm.installedBadge(for: .balanced) == "Installed")
        #expect(vm.installedBadge(for: .best) == "Installed")
        vm.teardown()
    }

    /// After a relaunch nobody remembers who pressed what, and the shared row must still explain
    /// itself rather than reappear as a mystery download.
    @Test func aPreInstalledSharedTierStillExplainsItself() {
        let (vm, _) = pickerViewModel(installed: [.best])
        #expect(vm.machine.explicitlyDownloadedTiers.isEmpty)
        #expect(vm.installedBadge(for: .balanced) == "Included with Best")
        #expect(vm.installedBadge(for: .best) == "Installed", "the superset is nobody else's leftover")
        #expect(vm.installedBadge(for: .fast) == "Installed")
        vm.teardown()
    }

    // MARK: Switching costs nothing

    @Test func selectingBalancedAfterBestIsInstantAndDownloadsNothing() async throws {
        let (vm, models) = pickerViewModel()
        vm.send(.download(.best))
        try await waitUntil { vm.machine.installedTiers.contains(.best) }

        #expect(vm.isReadyToUseWithoutDownload(.balanced))
        vm.send(.choose(.balanced))
        try await Task.sleep(for: .milliseconds(20))

        #expect(models.selectedTier == .balanced)
        #expect(models.downloads == [.best], "switching to a model already on disk fetches nothing")
        #expect(vm.machine.canContinueFromModelChoice, "and Continue is live at once")
        #expect(models.remainingBytes(for: .balanced) == 0)

        // …and back again, still free.
        vm.send(.choose(.best))
        try await Task.sleep(for: .milliseconds(20))
        #expect(models.downloads == [.best])
        #expect(vm.machine.canContinueFromModelChoice)
        vm.teardown()
    }
}
