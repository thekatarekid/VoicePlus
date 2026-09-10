import Foundation
import Testing
import Shared
@testable import Engine

/// R6.1 — one stack, and an existing install is left exactly as it is.
///
/// The picker is gone, so "install the models" is now something the app does on its own, without
/// being asked. That makes the no-re-download promise load-bearing: a user with 461 MB of Parakeet
/// TDT v3 already on disk must not have it fetched again, and the `voiceplus-manifest.json` that
/// records what was downloaded must not be rewritten — it is the only thing `ModelManager.verify`
/// can check a truncated file against, and a rewrite would launder the very corruption it exists
/// to catch.
@Suite("ModelStack — one stack, existing installs kept (R6.1)")
struct ModelStackInstallTests {
    private static func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceplus-stack-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Records every fetch it is asked for, and writes a model folder shaped like a real one.
    final class RecordingFetcher: ModelFetcher, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [ModelID] = []
        var fetched: [ModelID] { lock.withLock { storage } }

        func fetch(_ descriptor: ModelDescriptor, into folder: URL, progress: ModelProgressHandler?) async throws {
            lock.withLock { storage.append(descriptor.id) }
            try ModelStackInstallTests.writeModel(descriptor, at: folder)
        }
    }

    /// A model folder that passes `ModelIntegrity`: `.mlmodelc` bundles with their `coremldata.bin`,
    /// plain files for everything else.
    static func writeModel(_ d: ModelDescriptor, at folder: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for path in d.requiredPaths {
            let url = folder.appendingPathComponent(path)
            if path.hasSuffix(".mlmodelc") {
                try fm.createDirectory(at: url.appendingPathComponent("weights"), withIntermediateDirectories: true)
                try Data(repeating: 1, count: 64).write(to: url.appendingPathComponent("coremldata.bin"))
                try Data(repeating: 2, count: 512).write(to: url.appendingPathComponent("weights/weight.bin"))
            } else {
                try Data(path.utf8).write(to: url)
            }
        }
    }

    private static func manager(root: URL, fetcher: RecordingFetcher) -> ModelManager {
        ModelManager(root: root,
                     fetchers: [.finalTDT: fetcher, .streamingEOU: fetcher, .whisper: fetcher],
                     externalCaches: [:], maintenance: .skip)
    }

    // MARK: The stack itself

    @Test("the stack is TDT v3 + EOU, and nothing else")
    func theStackIsTwoModels() {
        #expect(ModelStack.models == [.parakeetTDTv3, .parakeetEOU160])
        #expect(ModelStack.approximateBytes == 900_000_000)
        // The two entries that used to be tiers of their own are fallbacks now: still in the
        // catalog (the recognizer walks down to them), never offered in the UI.
        #expect(ModelCatalog.descriptor(.parakeetTDTCTC110m).role == .fallback)
        #expect(ModelCatalog.descriptor(.whisperSmall).role == .fallback)
        #expect(ModelStack.models.allSatisfy { ModelCatalog.descriptor($0).role == .stack })
    }

    /// Qwen only ever shows up with refinement on. Until the `qwenRefinement` flag exists, the
    /// catalog holds no `.refinement` entry, so both answers are the stack — and adding one with
    /// `role: .refinement` is all that is needed to make the second answer longer.
    @Test("Settings › Models lists the stack, never a fallback")
    func userVisibleHidesFallbacks() {
        let off = ModelCatalog.userVisible(qwenRefinementEnabled: false)
        let on = ModelCatalog.userVisible(qwenRefinementEnabled: true)
        #expect(off == ModelStack.models)
        #expect(!on.contains(.parakeetTDTCTC110m))
        #expect(!on.contains(.whisperSmall))
        #expect(Set(off).isSubset(of: Set(on)))
        let refinement = ModelID.allCases.filter { ModelCatalog.descriptor($0).role == .refinement }
        #expect(on.filter { ModelCatalog.descriptor($0).role == .refinement } == refinement,
                "every refinement entry the catalog holds appears once refinement is on")
    }

    // MARK: A fresh root installs exactly the stack

    @Test("a fresh install fetches the two stack models and nothing else")
    func freshInstallFetchesTheStack() async throws {
        let root = try Self.tempRoot()
        let fetcher = RecordingFetcher()
        let manager = Self.manager(root: root, fetcher: fetcher)

        #expect(await ModelStack.missing(in: manager) == ModelStack.models)
        let fetched = try await ModelStack.install(manager: manager)
        #expect(fetched == ModelStack.models)
        #expect(fetcher.fetched == ModelStack.models)
        #expect(await ModelStack.isInstalled(in: manager))
        // Never the fallbacks: a fresh install does not pull 110 MB nobody can choose.
        #expect(!fetcher.fetched.contains(.parakeetTDTCTC110m))
        #expect(!fetcher.fetched.contains(.whisperSmall))
    }

    // MARK: An existing install is left alone

    @Test("an existing manifest is untouched and no duplicate download is scheduled")
    func existingInstallIsKept() async throws {
        let root = try Self.tempRoot()
        let fetcher = RecordingFetcher()

        // Stand up an install exactly as a previous version would have left it: both models on
        // disk, each with the manifest the fetcher writes at the end of a successful download.
        var manifests: [ModelID: (url: URL, data: Data, modified: Date)] = [:]
        for id in ModelStack.models {
            let d = ModelCatalog.descriptor(id)
            let folder = ModelCatalog.folder(for: id, in: root)
            try Self.writeModel(d, at: folder)
            let manifest = try ModelManifest.build(modelID: id, hfRepo: d.hfRepo, folder: folder)
            try manifest.save(to: folder)
            let url = ModelManifest.url(in: folder)
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            manifests[id] = (url, try Data(contentsOf: url), attrs[.modificationDate] as? Date ?? .distantPast)
        }
        // A modification date has one-second resolution on some filesystems, so make "unchanged"
        // mean something: the rewrite this guards against would land after this point.
        try await Task.sleep(for: .milliseconds(1100))

        let manager = Self.manager(root: root, fetcher: fetcher)
        #expect(await ModelStack.missing(in: manager) == [])
        let fetched = try await ModelStack.install(manager: manager)

        #expect(fetched.isEmpty, "nothing was missing, so nothing may be fetched")
        #expect(fetcher.fetched.isEmpty, "no duplicate download may be scheduled")
        for (id, before) in manifests {
            let after = try Data(contentsOf: before.url)
            #expect(after == before.data, "\(id.rawValue): the manifest must be byte-identical")
            let modified = try FileManager.default
                .attributesOfItem(atPath: before.url.path)[.modificationDate] as? Date
            #expect(modified == before.modified, "\(id.rawValue): the manifest must not be rewritten")
            // And it still verifies against the files it describes, which is the point of keeping it.
            #expect(await manager.verify(id).isEmpty)
        }
    }

    /// Half an install — the shape a pre-R6.1 "Balanced" user is in — tops up the missing model
    /// only, and leaves the manifest of the one already there alone.
    @Test("a half-installed stack tops up the missing model only")
    func halfInstalledStackTopsUp() async throws {
        let root = try Self.tempRoot()
        let fetcher = RecordingFetcher()
        let present = ModelCatalog.descriptor(.parakeetTDTv3)
        let folder = ModelCatalog.folder(for: .parakeetTDTv3, in: root)
        try Self.writeModel(present, at: folder)
        try ModelManifest.build(modelID: .parakeetTDTv3, hfRepo: present.hfRepo, folder: folder)
            .save(to: folder)
        let manifestBefore = try Data(contentsOf: ModelManifest.url(in: folder))

        let manager = Self.manager(root: root, fetcher: fetcher)
        #expect(await ModelStack.missing(in: manager) == [.parakeetEOU160])
        let fetched = try await ModelStack.install(manager: manager)
        #expect(fetched == [.parakeetEOU160])
        #expect(fetcher.fetched == [.parakeetEOU160])
        #expect(try Data(contentsOf: ModelManifest.url(in: folder)) == manifestBefore)
        #expect(await ModelStack.isInstalled(in: manager))
    }

    /// Running the install twice over is the same as running it once. The app now starts it
    /// unprompted (on entering the step, on a relaunch), so this has to be true.
    @Test("installing twice fetches once")
    func installIsIdempotent() async throws {
        let root = try Self.tempRoot()
        let fetcher = RecordingFetcher()
        let manager = Self.manager(root: root, fetcher: fetcher)
        try await ModelStack.install(manager: manager)
        try await ModelStack.install(manager: manager)
        #expect(fetcher.fetched == ModelStack.models, "the second pass fetches nothing")
    }
}
