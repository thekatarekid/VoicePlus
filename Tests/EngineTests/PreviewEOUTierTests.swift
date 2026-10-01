import FluidAudio
import Foundation
import Shared
import Testing
@testable import Engine

/// V5 C5 — EOU 320 ms tier. No CoreML here: models are fake folders and the loader is injected.
/// Untested: real 320 ms inference and its preview WER (the V1 gate, needs the ~230 MB download → T1).
@Suite("Preview EOU tier 320 ms (C5)")
struct PreviewEOUTierTests {
    @Test("catalog: 320 ms variant lives in the repo's 320ms/ folder and FluidAudio can fetch it")
    func catalogEntry() throws {
        let d = ModelCatalog.descriptor(.parakeetEOU320)
        #expect(d.kind == .streamingEOU)
        #expect(d.hfRepo == "FluidInference/parakeet-realtime-eou-120m-coreml")
        #expect(d.hfSubdirectory == "320ms")
        #expect(d.requiredPaths == ModelCatalog.descriptor(.parakeetEOU160).requiredPaths)
        #expect(d.role == .onDemand)
        #expect(Repo(rawValue: d.hfRepo + "/" + d.hfSubdirectory) == .parakeetEou320)
        #expect(ModelCatalog.descriptor(.parakeetEOU160).folderName != d.folderName)
        #expect(ModelID.parakeetEOU320.residencyTier == .always)
    }

    @Test("resolve: 320 when present; keeps 160 when only that is installed; nil when neither")
    func resolution() {
        #expect(PreviewEOUTier.resolve { $0 == .parakeetEOU160 } == .parakeetEOU160)
        #expect(PreviewEOUTier.resolve { $0 == .parakeetEOU320 || $0 == .parakeetEOU160 } == .parakeetEOU320)
        #expect(PreviewEOUTier.resolve { $0 == .parakeetEOU320 } == .parakeetEOU320)
        #expect(PreviewEOUTier.resolve { _ in false } == nil)
        // The first-run stack is unchanged until the V1 gate: existing installs never re-download.
        #expect(ModelStack.models.contains(PreviewEOUTier.stackVariant))
        #expect(!ModelStack.models.contains(.parakeetEOU320))
    }

    @Test("chunk size follows the model id")
    func chunkSizes() {
        #expect(PreviewEOUTier.chunkSize(for: .parakeetEOU320) == .ms320)
        #expect(PreviewEOUTier.chunkSize(for: .parakeetEOU160) == .ms160)
    }

    @Test("warm start loads one EOU variant, not both")
    func dedupe() {
        let preferred: [ModelID] = [.parakeetEOU160, .parakeetTDTv3, .parakeetTDTCTC110m]
        #expect(PreviewEOUTier.dedupe(preferred) { _ in true } == [.parakeetEOU320, .parakeetTDTv3, .parakeetTDTCTC110m])
        #expect(PreviewEOUTier.dedupe(preferred) { $0 != .parakeetEOU320 } == preferred)
        #expect(PreviewEOUTier.dedupe([.parakeetEOU320, .parakeetEOU160]) { _ in false } == [])
        #expect(PreviewEOUTier.dedupe([.parakeetTDTv3]) { _ in true } == [.parakeetTDTv3])
    }

    @Test("ModelManager: the 320 ms copy on disk is the one resolved and warmed")
    func managerResolvesAndWarms() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voiceplus-c5-\(UUID().uuidString)")
        try Self.makeModel(.parakeetEOU160, root: root)
        let loaded = Loaded()
        let manager = ModelManager(root: root, fetchers: [:], externalCaches: [:],
                                   loader: { id, _, _ in loaded.add(id); throw ModelManagerError.unsupported(id) },
                                   maintenance: .skip, residency: nil)
        #expect(await PreviewEOUTier.resolve(in: manager) == .parakeetEOU160, "migration: 160 kept when it is all there is")
        try Self.makeModel(.parakeetEOU320, root: root)
        #expect(await PreviewEOUTier.resolve(in: manager) == .parakeetEOU320)
        _ = await manager.warmStart()
        #expect(loaded.ids.contains(.parakeetEOU320))
        #expect(!loaded.ids.contains(.parakeetEOU160), "both EOU variants were warmed")
        try? FileManager.default.removeItem(at: root)
    }

    final class Loaded: @unchecked Sendable {
        private let lock = NSLock(); private var list: [ModelID] = []
        func add(_ id: ModelID) { lock.lock(); list.append(id); lock.unlock() }
        var ids: [ModelID] { lock.lock(); defer { lock.unlock() }; return list }
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
}
