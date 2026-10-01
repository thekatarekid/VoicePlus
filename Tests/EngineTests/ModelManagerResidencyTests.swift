import Dispatch
import Foundation
import Shared
import Testing
@testable import Engine

/// V5 HW1/HW3 — the engine's models are loaded through `ModelResidency`, and the kernel's
/// memory-pressure flags map onto its levels. CoreML itself is not exercised (no models in CI):
/// the injected loader stands in for it.
@Suite("ModelManager through ModelResidency (HW1/HW3)")
struct ModelManagerResidencyTests {
    private static func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceplus-hw1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func makeModel(_ id: ModelID, root: URL) throws {
        let d = ModelCatalog.descriptor(id)
        let folder = ModelCatalog.folder(for: id, in: root)
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for path in d.requiredPaths {
            let url = folder.appendingPathComponent(path)
            if path.hasSuffix(".mlmodelc") {
                try fm.createDirectory(at: url.appendingPathComponent("weights"), withIntermediateDirectories: true)
                try Data(repeating: 1, count: 64).write(to: url.appendingPathComponent("coremldata.bin"))
                try Data(repeating: 2, count: 4096).write(to: url.appendingPathComponent("weights/weight.bin"))
            } else {
                try Data(path.utf8).write(to: url)
            }
        }
        try ModelManifest.build(modelID: d.id, hfRepo: d.hfRepo, folder: folder).save(to: folder)
    }

    final class Count: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    @Test func dictationModelsAreAlwaysTier() {
        #expect(ModelID.parakeetTDTv3.residencyTier == .always)
        #expect(ModelID.parakeetEOU160.residencyTier == .always)
        #expect(ModelID.parakeetTDTCTC110m.residencyTier == .always)
        #expect(ModelID.whisperSmall.residencyTier == .onDemand)
        #expect(ModelID.parakeetTDTv3.residencyKey(scope: "s") == "asr.parakeet-tdt-0.6b-v3-coreml#s")
    }

    @Test func loadRegistersAndGoesThroughResidency() async throws {
        let root = try Self.tempDir()
        try Self.makeModel(.parakeetTDTv3, root: root)
        let residency = ModelResidency(budgetBytes: 4 * ResidencyBudget.gib)
        let calls = Count()
        let manager = ModelManager(root: root, fetchers: [:], externalCaches: [:],
                                   loader: { _, _, _ in
                                       calls.bump()
                                       throw ModelManagerError.unsupported(.whisperSmall)   // no CoreML in CI
                                   },
                                   maintenance: .skip, residency: residency)
        let key = ModelID.parakeetTDTv3.residencyKey(scope: manager.residencyScope)

        // The loader's own error reaches the caller unchanged, and the failed load frees its bytes.
        await #expect(throws: ModelManagerError.unsupported(.whisperSmall)) { try await manager.load(.parakeetTDTv3) }
        #expect(calls.value == 1)
        #expect(await residency.isRegistered(key))
        let snap = await residency.snapshot()
        #expect(snap.usedBytes == 0)
        #expect(snap.entries.first { $0.key == key }?.tier == .always)
        #expect(snap.entries.first { $0.key == key }?.estimatedBytes == ModelCatalog.descriptor(.parakeetTDTv3).approxBytes)
    }

    @Test func missingModelStillReportsNotPresent() async throws {
        let root = try Self.tempDir()
        let residency = ModelResidency(budgetBytes: ResidencyBudget.gib)
        let manager = ModelManager(root: root, fetchers: [:], externalCaches: [:], maintenance: .skip, residency: residency)
        await #expect(throws: ModelManagerError.notPresent(.parakeetEOU160)) { try await manager.load(.parakeetEOU160) }
        #expect(await residency.snapshot().residentKeys.isEmpty)
    }

    @Test func noResidencyBypassesIt() async throws {
        let root = try Self.tempDir()
        let manager = ModelManager(root: root, fetchers: [:], externalCaches: [:], maintenance: .skip, residency: nil)
        #expect(manager.residency == nil)
        await #expect(throws: ModelManagerError.notPresent(.parakeetTDTv3)) { try await manager.load(.parakeetTDTv3) }
    }

    @Test func defaultManagerUsesSharedResidency() {
        let manager = ModelManager(root: FileManager.default.temporaryDirectory, fetchers: [:], externalCaches: [:], maintenance: .skip)
        #expect(manager.residency === ModelResidency.shared)
        #expect(MemoryPressureMonitor.shared.isRunning)
    }

    // MARK: HW3

    @Test func pressureFlagsMapToLevels() {
        #expect(MemoryPressureMonitor.level(for: .normal) == .normal)
        #expect(MemoryPressureMonitor.level(for: .warning) == .warning)
        #expect(MemoryPressureMonitor.level(for: .critical) == .critical)
        #expect(MemoryPressureMonitor.level(for: [.warning, .critical]) == .critical)
    }

    @Test func monitorStartsAndStopsIdempotently() {
        let m = MemoryPressureMonitor(residency: ModelResidency(budgetBytes: ResidencyBudget.gib))
        #expect(!m.isRunning)
        m.start(); m.start()
        #expect(m.isRunning)
        m.stop()
        #expect(!m.isRunning)
    }
}
