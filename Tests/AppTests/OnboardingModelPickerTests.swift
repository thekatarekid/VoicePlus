import Engine
import Foundation
import Testing
@testable import VoicePlusApp

/// The 1.7.0 model picker: three options, each with its own **explicit** Download button, and a
/// Continue that stays shut until the chosen model is really on this Mac.
///
/// Two reported bugs, both of them about consent and honesty rather than plumbing:
///
/// 1. Continue was live at 3 % of a 900 MB download, so the user walked onto the dictation screen
///    with no model and met a dead app.
/// 2. Selecting a radio button *started* the download. A selection control that silently spends
///    several hundred megabytes is a surprising side effect of what looks like a pure choice.
@Suite("Onboarding model picker — explicit downloads, gated Continue")
@MainActor
struct OnboardingModelPickerTests {
    typealias M = OnboardingStateMachine

    /// Walks a fresh view model to the model-choice step (no permissions granted, so two skips).
    private func pickerViewModel(installed: Set<ModelTier> = [],
                                 hold: (@Sendable () async -> Void)? = nil)
        -> (OnboardingViewModel, OnboardingMockModelManager) {
        var deps = OnboardingDependencies.mock()
        let models = OnboardingMockModelManager(installed: installed)
        models.hold = hold
        deps.models = models
        let vm = OnboardingViewModel(dependencies: deps)
        vm.send(.skip); vm.send(.skip)
        #expect(vm.step == .modelChoice)
        return (vm, models)
    }

    // MARK: Selecting is not downloading

    @Test func selectingAnOptionStartsNoDownload() async throws {
        let (vm, models) = pickerViewModel()
        vm.send(.choose(.best))
        vm.send(.choose(.balanced))
        vm.send(.choose(.fast))
        // Give any (wrongly) spawned task a chance to record itself before we assert it doesn't exist.
        try await Task.sleep(for: .milliseconds(50))
        #expect(models.downloads.isEmpty, "a radio button must never spend the user's bandwidth")
        #expect(vm.machine.downloadState(for: .fast) == .notStarted)
        #expect(!vm.machine.canContinueFromModelChoice)
        vm.teardown()
    }

    @Test func onlyTheExplicitDownloadButtonFetches() async throws {
        let (vm, models) = pickerViewModel()
        vm.send(.choose(.balanced))
        try await Task.sleep(for: .milliseconds(20))
        #expect(models.downloads.isEmpty)
        vm.send(.download(.balanced))
        try await waitUntil { models.downloads == [.balanced] }
        try await waitUntil { vm.machine.downloadState(for: .balanced) == .installed }
        // Downloading an option also selects it — nobody fetches 500 MB they did not want.
        #expect(models.selectedTier == .balanced)
        vm.teardown()
    }

    /// The pure state machine says the same thing without any of the plumbing.
    @Test func chooseEmitsSelectionOnlyAndDownloadEmitsTheFetch() {
        var m = M()
        m.handle(.skip); m.handle(.skip)
        #expect(m.handle(.choose(.best)) == [.selectModel(.best)])
        #expect(m.handle(.download(.best)) == [.selectModel(.best), .startDownload(.best)])
    }

    // MARK: Continue is gated on real presence

    @Test func continueIsShutUntilTheChosenModelIsOnDisk() async throws {
        let gate = PickerGate()
        let (vm, _) = pickerViewModel(hold: { await gate.wait() })
        vm.send(.download(.balanced))
        try await waitUntil { vm.machine.download.isInFlight }

        #expect(!vm.machine.canContinueFromModelChoice, "3 % is not a working model")
        let reason = try #require(vm.machine.continueBlockedReason)
        #expect(reason.contains("Balanced"), "a disabled button must say which model it is waiting for")
        #expect(reason.lowercased().contains("download"))
        vm.send(.next)
        #expect(vm.step == .modelChoice, "Continue must not fire while the model is still arriving")

        gate.open()
        try await waitUntil { vm.machine.canContinueFromModelChoice }
        #expect(vm.machine.continueBlockedReason == nil)
        vm.send(.next)
        #expect(vm.step == .firstDictation)
        vm.teardown()
    }

    /// A model that is already on disk needs no download at all: pick it and Continue is live.
    @Test func anInstalledOptionIsSelectableInstantly() async throws {
        let (vm, models) = pickerViewModel(installed: [.fast])
        #expect(vm.machine.downloadState(for: .fast) == .installed)
        vm.send(.choose(.fast))
        #expect(vm.machine.canContinueFromModelChoice)
        try await Task.sleep(for: .milliseconds(20))
        #expect(models.downloads.isEmpty, "what is already here is not fetched again")
        vm.teardown()
    }

    // MARK: Overlapping models

    /// "Best" is "Balanced" plus a small end-of-utterance model. With Balanced on disk the picker
    /// must offer the *difference*, not a second 900 MB.
    @Test func overlappingTiersReportPerModelPresence() async throws {
        let (vm, models) = pickerViewModel(installed: [.balanced])
        #expect(vm.machine.installedTiers == [.balanced])
        #expect(vm.machine.downloadState(for: .best) == .notStarted, "Best is not complete yet")

        let eou = ModelCatalog.descriptor(.parakeetEOU160).approxBytes
        #expect(models.remainingBytes(for: .best) == eou,
                "the shared Parakeet TDT v3 is already here and must not be counted again")
        #expect(models.remainingBytes(for: .balanced) == 0)
        #expect(vm.isPartialDownload(.best))
        #expect(vm.downloadButtonTitle(for: .best) == "Download \(ByteText.short(eou))")
        #expect(vm.downloadButtonTitle(for: .best) != "Download \(ModelTier.best.sizeLabel)")

        vm.send(.download(.best))
        try await waitUntil { vm.machine.installedTiers.contains(.best) }
        #expect(vm.machine.installedTiers.contains(.balanced), "finishing Best cannot un-install Balanced")
        #expect(models.remainingBytes(for: .best) == 0)
        vm.teardown()
    }

    // MARK: Per-option state

    @Test func eachOptionKeepsItsOwnStateAndCanBeCancelled() async throws {
        let gate = PickerGate()
        let (vm, models) = pickerViewModel(hold: { await gate.wait() })
        vm.send(.download(.best))
        try await waitUntil { vm.machine.downloadState(for: .best).isInFlight }
        #expect(vm.machine.downloadState(for: .fast) == .notStarted, "one row's progress is not another's")
        #expect(vm.downloadLine(for: .fast) == nil)
        #expect(vm.downloadLine(for: .best)?.contains("Parakeet") == true)

        vm.send(.cancelDownload(.best))
        #expect(vm.machine.downloadState(for: .best) == .notStarted, "Cancel puts the row back to Download")
        gate.open()
        try await Task.sleep(for: .milliseconds(50))
        #expect(!models.installed.contains(.best), "a cancelled download installs nothing")
        #expect(!vm.machine.canContinueFromModelChoice)
        vm.teardown()
    }

    // MARK: Skip stays available, and honest

    @Test func skipIsAllowedButSaysWhatItCosts() {
        var m = M()
        m.handle(.skip); m.handle(.skip)
        #expect(m.skipConsequence?.contains("dictation won't work") == true)
        m.handle(.skip)
        #expect(m.step == .firstDictation, "skipping remains a legitimate choice")
        #expect(m.skippedModelChoiceWithoutModel, "the later screens must be able to say why nothing works")
    }

    @Test func skipWithAModelPresentRaisesNoAlarm() {
        var m = M()
        m.handle(.skip); m.handle(.skip)
        m.handle(.modelPresenceChanged([.fast]))
        #expect(m.skipConsequence == nil, "a warning that is always on is a warning nobody reads")
        m.handle(.skip)
        #expect(!m.skippedModelChoiceWithoutModel)
    }
}

/// Holds a mock download open until the test lets it finish.
private final class PickerGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    func open() { lock.withLock { opened = true } }
    var isOpen: Bool { lock.withLock { opened } }
    func wait() async { while !isOpen { try? await Task.sleep(for: .milliseconds(5)) } }
}
