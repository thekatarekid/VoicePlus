import Foundation
import Testing
@testable import Engine

@Suite("Full installer read-only model resources")
struct BundledModelResourcesTests {
    @Test func defaultStackHasCanonicalBundlePaths() {
        let root = URL(fileURLWithPath: "/Applications/VoicePlus.app/Contents/Resources")
        let paths = BundledModelResources.candidates(resources: root)
        // N6: the full installer also carries the CTC boosting model.
        let expected = Set(ModelStack.models).union([.parakeetCTC110m])
        #expect(Set(paths.keys) == expected)
        for id in expected {
            #expect(paths[id] == ModelCatalog.folder(for: id, in: root.appendingPathComponent("Models")))
        }
        #expect(BundledModelResources.candidates(resources: nil).isEmpty)
    }

    @Test func emptyUserCacheBorrowsBundleAndRepairDoesNotMutateIt() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("spool-bundled-models-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let resources = root.appendingPathComponent("VoicePlus.app/Contents/Resources")
        let paths = BundledModelResources.candidates(resources: resources)
        for id in ModelStack.models {
            let descriptor = ModelCatalog.descriptor(id), folder = try #require(paths[id])
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            for path in descriptor.requiredPaths {
                let url = folder.appendingPathComponent(path)
                if path.hasSuffix(".mlmodelc") {
                    try fm.createDirectory(at: url.appendingPathComponent("weights"), withIntermediateDirectories: true)
                    try Data(repeating: 1, count: 64).write(to: url.appendingPathComponent("coremldata.bin"))
                    try Data(repeating: 2, count: 512).write(to: url.appendingPathComponent("weights/weight.bin"))
                } else { try Data(path.utf8).write(to: url) }
            }
            try ModelManifest.build(modelID: id, hfRepo: descriptor.hfRepo, folder: folder).save(to: folder)
        }
        let manager = ModelManager(root: root.appendingPathComponent("fresh-user/Models"), fetchers: [:],
                                   externalCaches: paths.mapValues { [$0] }, maintenance: .run)
        for id in ModelStack.models {
            let folder = try #require(paths[id])
            #expect(try await manager.ensureAvailable(id) == folder, "No downloader registered or needed")
            #expect(await manager.verify(id).isEmpty)
            _ = await manager.repair(id)
            #expect(await manager.locate(id) == folder)
            #expect(try #require(ModelManifest.load(from: folder)).verify(in: folder).isEmpty)
        }
    }
}
