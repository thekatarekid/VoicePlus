import Foundation
import Testing
import Shared
@testable import Engine

/// Regression cover for the 1.7.13 report: **every model was downloaded twice**.
///
/// We stored TDT v3 in `Models/parakeet-tdt-0.6b-v3-coreml` (the `ModelID` raw value) and handed that
/// URL to `AsrModels.load(from:)`. FluidAudio ignores the folder it is given: it takes
/// `directory.deletingLastPathComponent()` as a models root and asks `ModelHub` for
/// `Repo.parakeetV3.folderName` — which is the repo name **minus `-coreml`**
/// (`ModelNames.swift:311`). So the load resolved to `Models/parakeet-tdt-0.6b-v3`, found it empty,
/// and re-downloaded 468 MB. Confirmed on the reporter's disk: two byte-identical 461 MB trees, one
/// with `voiceplus-manifest.json` and one without, ~81 s of "Warming up…" spent on the second.
///
/// These tests pin the resolution arithmetic itself rather than mocking FluidAudio, because the whole
/// bug lived in one line of path arithmetic that no mock would have reproduced.
@Suite("Model folder layout + migration", .serialized)
struct ModelLayoutTests {

    // MARK: - Fixtures

    private static func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceplus-layout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A folder shaped like a real installed model: `.mlmodelc` bundles with their `coremldata.bin`.
    @discardableResult
    private static func makeModel(_ d: ModelDescriptor, at folder: URL, manifest: Bool = true) throws -> URL {
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
        if manifest { try ModelManifest.build(modelID: d.id, hfRepo: d.hfRepo, folder: folder).save(to: folder) }
        return folder
    }

    /// FluidAudio's own resolution, transcribed from `AsrModels.load(from:)` + `Repo.folderName`:
    /// take the parent of the directory we pass, then re-descend into the repo folder name.
    private static func fluidAudioResolves(_ passed: URL, repoFolderName: String) -> URL {
        passed.deletingLastPathComponent().appendingPathComponent(repoFolderName, isDirectory: true)
    }

    /// `Repo.folderName` for the repos our two FluidAudio-loaded final models come from.
    /// `parakeetV3` falls through to the default (`name` minus `-coreml`); `parakeetTdtCtc110m` is an
    /// explicit case in `ModelNames.folderName`.
    private static let repoFolderNames: [ModelID: String] = [
        .parakeetTDTv3: "parakeet-tdt-0.6b-v3",
        .parakeetTDTCTC110m: "parakeet-tdt-ctc-110m",
    ]

    // MARK: - The stored path is the one FluidAudio resolves to

    @Test func storedFolderIsWhatFluidAudioResolvesTo() throws {
        let root = try Self.tempDir()
        for (id, repoFolder) in Self.repoFolderNames {
            let stored = ModelCatalog.folder(for: id, in: root)
            #expect(stored.lastPathComponent == repoFolder,
                    "\(id.rawValue) must be stored under FluidAudio's own folder name")
            // The round trip `AsrModels.load` performs must land back on the same directory.
            #expect(Self.fluidAudioResolves(stored, repoFolderName: repoFolder).standardizedFileURL == stored.standardizedFileURL)
        }
    }

    /// The same claim, but read out of FluidAudio itself instead of transcribed. If upstream renames
    /// a repo folder, this fails here rather than costing every user another 468 MB.
    @Test func folderNameAgreesWithFluidAudiosOwn() {
        for id in ModelID.allCases {
            guard let upstream = ModelCatalog.fluidAudioFolderName(for: id) else { continue }
            #expect(ModelCatalog.folderName(for: id) == upstream, "\(id.rawValue) must be stored where FluidAudio looks")
        }
        // And the two models that go through ModelHub are covered — a nil for both would pass vacuously.
        #expect(ModelCatalog.fluidAudioFolderName(for: .parakeetTDTv3) != nil)
        #expect(ModelCatalog.fluidAudioFolderName(for: .parakeetTDTCTC110m) != nil)
    }

    /// What the bug looked like: the old layout resolved *away* from the folder we filled.
    @Test func oldLayoutResolvedToADifferentFolder() {
        let root = URL(fileURLWithPath: "/tmp/Models", isDirectory: true)
        let old = root.appendingPathComponent(ModelID.parakeetTDTv3.rawValue, isDirectory: true)
        let resolved = Self.fluidAudioResolves(old, repoFolderName: "parakeet-tdt-0.6b-v3")
        #expect(resolved != old)                                  // the second download, in one line
        #expect(resolved.lastPathComponent == "parakeet-tdt-0.6b-v3")
    }

    /// The EOU model is loaded by `StreamingEouAsrManager.loadModels(from:)`, which opens the files in
    /// the directory it is given — no `ModelHub`, no re-derived parent, no duplicate. Its folder name
    /// stays the raw value, and no migration is claimed for it.
    @Test func eouKeepsItsFolderAndNeedsNoMigration() {
        let d = ModelCatalog.descriptor(.parakeetEOU160)
        #expect(d.folderName == ModelID.parakeetEOU160.rawValue)
        #expect(d.legacyFolderNames.isEmpty)
    }

    @Test func everyModelHasANonDottedFolderName() {
        // `FluidAudioFetcher.stagingFolder` relies on this: `.staging-…` can never collide with, or
        // be migrated as, an installed model.
        for id in ModelID.allCases {
            let d = ModelCatalog.descriptor(id)
            #expect(!d.folderName.hasPrefix("."))
            #expect(!d.folderName.isEmpty)
            #expect(!d.legacyFolderNames.contains(d.folderName))
            for legacy in d.legacyFolderNames { #expect(!legacy.hasPrefix(".")) }
        }
        // Folder names must stay unique or two models would share a directory.
        let names = ModelID.allCases.map { ModelCatalog.folderName(for: $0) }
        #expect(Set(names).count == names.count)
    }

    // MARK: - Migrating an existing install

    /// The plain case: 1.7.12 install, the duplicate not yet fetched (or already cleaned).
    /// The model is renamed, never re-downloaded.
    @Test func legacyFolderAloneIsRenamed() throws {
        let root = try Self.tempDir()
        let d = ModelCatalog.descriptor(.parakeetTDTv3)
        let legacy = try Self.makeModel(d, at: root.appendingPathComponent(d.legacyFolderNames[0]))
        let sha = try #require(ModelManifest.load(from: legacy)).files.first?.sha256

        let results = ModelLayoutMigration.migrate(root: root)
        #expect(results.contains { $0.id == .parakeetTDTv3 && $0.outcome == .renamed })

        let target = ModelCatalog.folder(for: .parakeetTDTv3, in: root)
        #expect(FileManager.default.fileExists(atPath: target.path))
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        // Same bytes, same manifest — nothing was re-fetched.
        #expect(ModelManifest.load(from: target)?.files.first?.sha256 == sha)
        #expect(ModelIntegrity.isComplete(d, at: target))
    }

    /// The reported disk: our folder *and* FluidAudio's orphan duplicate, the orphan identifiable by
    /// having no `voiceplus-manifest.json`. One folder survives, the wasted bytes come back, and the
    /// user downloads nothing.
    @Test func orphanDuplicateIsRemovedAndSpaceReclaimed() throws {
        let root = try Self.tempDir()
        let d = ModelCatalog.descriptor(.parakeetTDTv3)
        let legacy = try Self.makeModel(d, at: root.appendingPathComponent(d.legacyFolderNames[0]))
        let orphan = try Self.makeModel(d, at: root.appendingPathComponent(d.folderName), manifest: false)
        #expect(ModelManifest.load(from: orphan) == nil)          // that is what makes it the orphan
        let orphanBytes = ModelLayoutMigration.directorySize(orphan)
        #expect(orphanBytes > 0)

        let results = ModelLayoutMigration.migrate(root: root)
        let v3 = try #require(results.first { $0.id == .parakeetTDTv3 })
        #expect(v3.outcome == .replacedDuplicate)
        #expect(v3.reclaimedBytes == orphanBytes)

        let target = ModelCatalog.folder(for: .parakeetTDTv3, in: root)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(ModelIntegrity.isComplete(d, at: target))
        #expect(ModelManifest.load(from: target) != nil)          // our copy won: the manifest survived
        // Exactly one directory for this model is left under the root.
        let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(entries.filter { $0.contains("parakeet-tdt-0.6b-v3") } == [d.folderName])
    }

    /// If our own copy is the broken one, the complete FluidAudio copy is adopted rather than
    /// deleted — the user still downloads nothing.
    @Test func incompleteLegacyYieldsToACompleteDuplicate() throws {
        let root = try Self.tempDir()
        let d = ModelCatalog.descriptor(.parakeetTDTCTC110m)
        let legacy = try Self.makeModel(d, at: root.appendingPathComponent(d.legacyFolderNames[0]))
        // Interrupt it the way a dropped download does.
        try FileManager.default.removeItem(at: legacy.appendingPathComponent("Decoder.mlmodelc"))
        try Self.makeModel(d, at: root.appendingPathComponent(d.folderName), manifest: false)

        let results = ModelLayoutMigration.migrate(root: root)
        let tiny = try #require(results.first { $0.id == .parakeetTDTCTC110m })
        #expect(tiny.outcome == .adoptedExisting)
        #expect(tiny.reclaimedBytes > 0)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(ModelIntegrity.isComplete(d, at: ModelCatalog.folder(for: .parakeetTDTCTC110m, in: root)))
    }

    @Test func migrationIsIdempotentAndQuietOnAFreshInstall() throws {
        let root = try Self.tempDir()
        #expect(ModelLayoutMigration.migrate(root: root).isEmpty)          // nothing on disk at all
        let d = ModelCatalog.descriptor(.parakeetTDTv3)
        try Self.makeModel(d, at: root.appendingPathComponent(d.legacyFolderNames[0]))
        #expect(ModelLayoutMigration.migrate(root: root).count == 1)
        #expect(ModelLayoutMigration.migrate(root: root).isEmpty)          // second run: nothing left to do
        #expect(ModelIntegrity.isComplete(d, at: ModelCatalog.folder(for: .parakeetTDTv3, in: root)))
    }

    /// Migration runs from `ModelManager.init`, so an old install is already on the new layout by the
    /// time anything asks where a model is — and reports present without touching the network.
    @Test func managerMigratesOnInitAndFindsTheModel() async throws {
        let root = try Self.tempDir()
        let d = ModelCatalog.descriptor(.parakeetTDTv3)
        try Self.makeModel(d, at: root.appendingPathComponent(d.legacyFolderNames[0]))
        try Self.makeModel(d, at: root.appendingPathComponent(d.folderName), manifest: false)

        let m = ModelManager(root: root, fetchers: [:], externalCaches: [:])
        #expect(await m.isPresent(.parakeetTDTv3))
        #expect(await m.locate(.parakeetTDTv3) == ModelCatalog.folder(for: .parakeetTDTv3, in: root))
        #expect(await m.bestFinalModelOnDisk() == .parakeetTDTv3)
        // No fetcher is registered, so anything that wanted to download would have thrown here.
        #expect(try await m.ensureAvailable(.parakeetTDTv3) == ModelCatalog.folder(for: .parakeetTDTv3, in: root))
    }

    /// Nothing outside the model folders is touched — in particular, a directory belonging to another
    /// app (the reporter has 1.2 GB of `qwen3-asr-0.6b` from an unrelated one) stays put.
    @Test func migrationLeavesUnrelatedDirectoriesAlone() throws {
        let root = try Self.tempDir()
        let stranger = root.appendingPathComponent("qwen3-asr-0.6b", isDirectory: true)
        try FileManager.default.createDirectory(at: stranger, withIntermediateDirectories: true)
        try Data("not ours".utf8).write(to: stranger.appendingPathComponent("model.bin"))
        let staging = FluidAudioFetcher.stagingFolder(for: .parakeetTDTv3, beside: ModelCatalog.folder(for: .parakeetTDTv3, in: root))
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        ModelLayoutMigration.migrate(root: root)
        #expect(FileManager.default.fileExists(atPath: stranger.appendingPathComponent("model.bin").path))
        #expect(FileManager.default.fileExists(atPath: staging.path))
    }

    // MARK: - First-launch order (bug 2)

    /// The old constant put the 110M tiny model first unconditionally, so a user who already had the
    /// 0.6B v3 queued a 110 MB download of a worse model — and got v3 last, behind 400 MB of EOU.
    @Test func bestAvailableModelWinsFirstLaunch() {
        // v3 already there: nothing left to fetch but the streaming preview.
        #expect(BundledModel.firstLaunchOrder(bestFinalOnDisk: .parakeetTDTv3) == [.parakeetEOU160])
        // Only the tiny model there: upgrade to v3 first, and never re-queue the tiny one.
        let fromTiny = BundledModel.firstLaunchOrder(bestFinalOnDisk: .parakeetTDTCTC110m)
        #expect(fromTiny == [.parakeetTDTv3, .parakeetEOU160])
        #expect(!fromTiny.contains(.parakeetTDTCTC110m))
        // Whenever anything usable is already installed, the queue is strictly best-first: the tiny
        // model is never queued ahead of v3 again. (Cold start is the one deliberate exception —
        // see `coldStartStillFetchesTheTinyModelFirst`.)
        for best in [ModelID.parakeetTDTCTC110m, .parakeetTDTv3] {
            let finals = BundledModel.firstLaunchOrder(bestFinalOnDisk: best)
                .filter { BundledModel.finalModelsByQuality.contains($0) }
            #expect(finals == BundledModel.finalModelsByQuality.filter { finals.contains($0) })
        }
        // And v3 is always queued before the 400 MB preview model, so the best final recogniser
        // arrives first rather than last.
        for best in [ModelID?.none, .parakeetTDTCTC110m] {
            let order = BundledModel.firstLaunchOrder(bestFinalOnDisk: best)
            let v3 = try? #require(order.firstIndex(of: .parakeetTDTv3))
            let eou = try? #require(order.firstIndex(of: .parakeetEOU160))
            #expect((v3 ?? 0) < (eou ?? 0))
        }
    }

    /// …without regressing the genuine fallback: with an empty disk the tiny model is still first and
    /// still the one `bootstrap` awaits, because it is what makes dictation work in seconds.
    @Test func coldStartStillFetchesTheTinyModelFirst() {
        let cold = BundledModel.firstLaunchOrder(bestFinalOnDisk: nil)
        #expect(cold.first == BundledModel.id)
        #expect(cold == [.parakeetTDTCTC110m, .parakeetTDTv3, .parakeetEOU160])
    }

    /// `chooseFinal`'s ordering contract: it, `bestFinalModelOnDisk` and the download order all read
    /// the same ranking, so they cannot drift apart.
    @Test func qualityRankingMatchesChooseFinal() async throws {
        #expect(BundledModel.finalModelsByQuality == [.parakeetTDTv3, .parakeetTDTCTC110m])
        let root = try Self.tempDir()
        let v3 = ModelCatalog.descriptor(.parakeetTDTv3)
        let tiny = ModelCatalog.descriptor(.parakeetTDTCTC110m)

        let onlyTiny = ModelManager(root: root, fetchers: [:], externalCaches: [:])
        try Self.makeModel(tiny, at: ModelCatalog.folder(for: .parakeetTDTCTC110m, in: root))
        #expect(await RecognizerFactory.chooseFinal(manager: onlyTiny, appleSpeechAvailable: true) == .tiny)
        #expect(await onlyTiny.bestFinalModelOnDisk() == .parakeetTDTCTC110m)

        try Self.makeModel(v3, at: ModelCatalog.folder(for: .parakeetTDTv3, in: root))
        let both = ModelManager(root: root, fetchers: [:], externalCaches: [:])
        #expect(await RecognizerFactory.chooseFinal(manager: both, appleSpeechAvailable: true) == .tdtV3)
        #expect(await both.bestFinalModelOnDisk() == .parakeetTDTv3)
        #expect(BundledModel.firstLaunchOrder(bestFinalOnDisk: await both.bestFinalModelOnDisk()) == [.parakeetEOU160])
    }
}
