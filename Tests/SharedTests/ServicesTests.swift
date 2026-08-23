import Foundation
import Testing
@testable import Shared

@Suite struct ServicesTests {
    @Test func featureFlagDefaultsAndOverrides() throws {
        let service = FeatureFlagService.inMemory()
        #expect(service.isEnabled(.voiceRepair))
        #expect(!service.isEnabled(.cloudASR))
        #expect(service.override(for: .voiceRepair) == nil)

        try service.setOverride(false, for: .voiceRepair)
        #expect(!service.isEnabled(.voiceRepair))
        #expect(service.override(for: .voiceRepair) == false)
        #expect(service.snapshot()["voiceRepair"] == false)
        #expect(service.snapshot().count == FeatureFlag.all.count)

        try service.setOverride(nil, for: .voiceRepair)
        #expect(service.isEnabled(.voiceRepair))
        #expect(!service.isEnabled(id: "unknownFlag"))
    }

    @Test func jsonFileStorePersistsAcrossInstances() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("voiceplus-flags-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = JSONFileFlagStore(url: dir.appendingPathComponent("feature_flags.json"))

        let first = FeatureFlagService(store: store)
        try first.setOverride(true, for: .cloudASR)

        let second = FeatureFlagService(store: store)
        #expect(second.isEnabled(.cloudASR))
        try second.resetAll()
        #expect(!FeatureFlagService(store: store).isEnabled(.cloudASR))
    }

    @Test func logRingBufferCapturesAndCaps() {
        let buffer = LogBuffer(capacity: 3)
        let log = Log(category: "test", buffer: buffer)
        log.debug("one")
        log.info("two")
        log.warning("three")
        log.error("four")
        #expect(buffer.snapshot().map(\.message) == ["two", "three", "four"])
        #expect(buffer.snapshot(minimumLevel: .warning).map(\.message) == ["three", "four"])
        #expect(buffer.snapshot(category: "other").isEmpty)
        buffer.clear()
        #expect(buffer.snapshot().isEmpty)
    }

    @Test func appPathsLiveUnderApplicationSupport() {
        #expect(AppPaths.supportDirectory().path.hasSuffix("Application Support/VoicePlus"))
        #expect(AppPaths.databaseURL().lastPathComponent == "voiceplus.sqlite")
        #expect(AppPaths.fixturesDirectory() != nil)
    }
}
