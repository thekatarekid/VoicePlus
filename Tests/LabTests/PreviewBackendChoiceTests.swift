import Foundation
import Testing
import Shared
@testable import Lab

/// R1.5 — both preview candidates are runnable from Lab, and the default run is unchanged.
@Suite("Preview backend choices")
struct PreviewBackendChoiceTests {

    @Test func bothCandidatesAreOffered() {
        let choices = LabConfigChoice.previewBackendChoices()
        #expect(choices.count == 2)
        #expect(choices.map { $0.config.name } == ["preview EOU 120M", "preview polling final"])
        #expect(choices[0].config.flags[FeatureFlag.previewBackend.id] == false)
        #expect(choices[1].config.flags[FeatureFlag.previewBackend.id] == true)
        #expect(choices.allSatisfy { !$0.selected })      // offered, not selected
        #expect(choices.allSatisfy { $0.config.transcriber == "perfect" })
    }

    @Test @MainActor func defaultChoicesIncludeThemWithoutChangingTheDefaultRun() {
        let defaults = LabPanelViewModel.defaultChoices()
        #expect(defaults.map { $0.config.name }.contains("preview EOU 120M"))
        #expect(defaults.map { $0.config.name }.contains("preview polling final"))
        // The comparison that runs when nobody touches anything is still biasing on vs off.
        #expect(defaults.filter { $0.selected }.map { $0.config.name } == ["biasing on", "biasing off"])
    }

    @Test func candidatesCanBeSelectedAndRun() async throws {
        var choices = LabConfigChoice.previewBackendChoices(selected: true)
        #expect(choices.allSatisfy { $0.selected })
        choices[0].config.suites = ["clean"]
        let vm = await LabPanelViewModel(choices: [choices[0]], runner: LabRunner(clock: { 0 }, hardware: "test", thermal: { .nominal }))
        await vm.run()
        let phase = await vm.phase
        #expect(phase == .finished)
        let reports = await vm.reports
        #expect(reports.count == 1)
        #expect(reports.first?.config.flags[FeatureFlag.previewBackend.id] == false)
    }

    /// `lab compare --flag previewBackend` needs no CLI change: the flag is a known flag.
    @Test func flagIsKnownToTheFlagService() {
        let service = FeatureFlagService.inMemory()
        #expect(service.knownFlags.contains { $0.id == "previewBackend" })
        #expect(service.isEnabled(id: "previewBackend") == false)
        #expect(service.snapshot()["previewBackend"] == false)
    }
}
