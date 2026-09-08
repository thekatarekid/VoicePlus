import Foundation
import Testing
import Shared
@testable import Engine

/// Two defects in the 1.7.13 model-store maintenance, both of which land on a real 468 MB install the
/// first time the next release launches.
///
/// 1. `ModelLayoutMigration`'s `adoptedExisting` branch kept the *manifest-less* copy of a model and
///    deleted the *manifest-bearing* one, writing nothing in its place. `voiceplus-manifest.json` is
///    the only record of what each file is supposed to weigh, so that branch permanently disabled
///    `ModelIntegrity`'s truncation check for that model — the check added in 1.7.11 precisely
///    because a half-downloaded model reported as installed.
/// 2. The migration and the atomic publish both park the outgoing copy as `.superseded-<uuid>` /
///    `.replaced-<uuid>` before deleting it. A crash in between stranded the whole tree under a name
///    nothing ever looked at again.
@Suite("Model store maintenance: manifests + parked directories", .serialized)
struct ModelMaintenanceTests {

    // MARK: - Fixtures

    private static func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceplus-maint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A folder shaped like a real installed model. Byte-for-byte deterministic, so two of them are
    /// the byte-identical duplicate pair the migration exists to undo.
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

    /// Make a complete model folder *look* interrupted without changing any real file's size, so the
    /// manifest it already carries still describes its files exactly.
    private static func leaveDownloadDebris(in folder: URL, _ d: ModelDescriptor) throws {
        let bundle = folder.appendingPathComponent(d.requiredPaths.first { $0.hasSuffix(".mlmodelc") }!)
        try Data(repeating: 9, count: 8).write(to: bundle.appendingPathComponent("weights/weight.bin.partial"))
    }

    private static let v3 = ModelCatalog.descriptor(.parakeetTDTv3)
    private static func legacyFolder(_ root: URL) -> URL { root.appendingPathComponent(v3.legacyFolderNames[0], isDirectory: true) }
    private static func targetFolder(_ root: URL) -> URL { ModelCatalog.folder(for: .parakeetTDTv3, in: root) }

    /// A model with a manifest that actually re-hashes clean, which is the only thing "has a valid
    /// manifest" can be allowed to mean.
    private static func expectValidManifest(_ folder: URL, _ d: ModelDescriptor, _ comment: Comment) throws {
        let manifest = try #require(ModelManifest.load(from: folder), comment)
        #expect(manifest.modelID == d.id, comment)
        #expect(!manifest.files.isEmpty, comment)
        #expect(manifest.verify(in: folder).isEmpty, comment)
        #expect(ModelIntegrity.assess(d, at: folder) == .verified, comment)
    }

    // MARK: - Defect 1: every migration branch leaves a valid manifest

    /// The branch that caused this: the surviving copy is the one *without* a manifest, and the one
    /// carrying it is about to be deleted. Before the fix, this model was left un-checkable forever.
    @Test func adoptingFluidAudiosCopyKeepsAManifest() throws {
        let root = try Self.tempDir()
        try Self.makeModel(Self.v3, at: Self.legacyFolder(root))                    // ours: has the manifest
        try Self.leaveDownloadDebris(in: Self.legacyFolder(root), Self.v3)          // …but is incomplete
        try Self.makeModel(Self.v3, at: Self.targetFolder(root), manifest: false)   // FluidAudio's: complete, no manifest

        let results = ModelLayoutMigration.migrate(root: root)
        #expect(results.map(\.outcome) == [.adoptedExisting])
        // Salvaged from the copy we deleted rather than re-hashed: same bytes, a `stat` per file
        // instead of a SHA-256 pass over 468 MB.
        #expect(results[0].manifest == .adopted)
        #expect(!FileManager.default.fileExists(atPath: Self.legacyFolder(root).path))
        try Self.expectValidManifest(Self.targetFolder(root), Self.v3, "adoptedExisting")
    }

    /// Same branch, but the donor has nothing to give. Then it must be rebuilt from disk, using the
    /// same `ModelManifest.build` writer both fetchers use — never a second, divergent one.
    @Test func adoptingRebuildsWhenNoCopyHasAManifest() throws {
        let root = try Self.tempDir()
        try Self.makeModel(Self.v3, at: Self.legacyFolder(root), manifest: false)
        try Self.leaveDownloadDebris(in: Self.legacyFolder(root), Self.v3)
        try Self.makeModel(Self.v3, at: Self.targetFolder(root), manifest: false)

        let results = ModelLayoutMigration.migrate(root: root)
        #expect(results.map(\.outcome) == [.adoptedExisting])
        #expect(results[0].manifest == .rebuilt)
        try Self.expectValidManifest(Self.targetFolder(root), Self.v3, "adoptedExisting, no donor")
    }

    /// A donor manifest is only adopted when it describes the folder *exactly*. A copy that is a
    /// different download must not have its byte counts stamped onto this one.
    @Test func aMismatchedDonorManifestIsRebuiltNotAdopted() throws {
        let root = try Self.tempDir()
        let legacy = Self.legacyFolder(root)
        try Self.makeModel(Self.v3, at: legacy, manifest: false)
        // Give the donor a manifest that records a *different* download: same paths, other sizes.
        let weights = legacy.appendingPathComponent(Self.v3.requiredPaths.first { $0.hasSuffix(".mlmodelc") }!)
            .appendingPathComponent("weights/weight.bin")
        try Data(repeating: 2, count: 8192).write(to: weights)
        try ModelManifest.build(modelID: Self.v3.id, hfRepo: Self.v3.hfRepo, folder: legacy).save(to: legacy)
        try Self.leaveDownloadDebris(in: legacy, Self.v3)
        try Self.makeModel(Self.v3, at: Self.targetFolder(root), manifest: false)

        let results = ModelLayoutMigration.migrate(root: root)
        #expect(results[0].outcome == .adoptedExisting)
        #expect(results[0].manifest == .rebuilt)
        try Self.expectValidManifest(Self.targetFolder(root), Self.v3, "mismatched donor")
    }

    /// The plain-rename branch, when the folder being renamed never had a manifest.
    @Test func renamingAManifestLessFolderRebuildsOne() throws {
        let root = try Self.tempDir()
        try Self.makeModel(Self.v3, at: Self.legacyFolder(root), manifest: false)

        let results = ModelLayoutMigration.migrate(root: root)
        #expect(results.map(\.outcome) == [.renamed])
        #expect(results[0].manifest == .rebuilt)
        try Self.expectValidManifest(Self.targetFolder(root), Self.v3, "renamed")
    }

    /// The both-complete branch. The kept copy already carries a manifest, so this must cost one
    /// file read and no hashing.
    @Test func replacingTheDuplicateKeepsTheManifestItAlreadyHad() throws {
        let root = try Self.tempDir()
        try Self.makeModel(Self.v3, at: Self.legacyFolder(root))
        try Self.makeModel(Self.v3, at: Self.targetFolder(root), manifest: false)

        let results = ModelLayoutMigration.migrate(root: root)
        #expect(results.map(\.outcome) == [.replacedDuplicate])
        #expect(results[0].manifest == .alreadyPresent)
        try Self.expectValidManifest(Self.targetFolder(root), Self.v3, "replacedDuplicate")
    }

    /// Whatever the branch, and whatever the starting state, the model ends up with a manifest. This
    /// is the invariant the individual cases above are instances of.
    @Test(arguments: [
        (legacy: true as Bool?, legacyManifest: true, target: true as Bool?, targetManifest: false, breakLegacy: false),
        (legacy: true, legacyManifest: false, target: true, targetManifest: false, breakLegacy: false),
        (legacy: true, legacyManifest: true, target: true, targetManifest: false, breakLegacy: true),
        (legacy: true, legacyManifest: false, target: nil, targetManifest: false, breakLegacy: false),
        (legacy: nil, legacyManifest: false, target: true, targetManifest: false, breakLegacy: false),
        (legacy: nil, legacyManifest: false, target: true, targetManifest: true, breakLegacy: false),
    ])
    func everyMigrationBranchLeavesAValidManifest(
        _ c: (legacy: Bool?, legacyManifest: Bool, target: Bool?, targetManifest: Bool, breakLegacy: Bool)
    ) throws {
        let root = try Self.tempDir()
        if c.legacy != nil {
            try Self.makeModel(Self.v3, at: Self.legacyFolder(root), manifest: c.legacyManifest)
            if c.breakLegacy { try Self.leaveDownloadDebris(in: Self.legacyFolder(root), Self.v3) }
        }
        if c.target != nil { try Self.makeModel(Self.v3, at: Self.targetFolder(root), manifest: c.targetManifest) }

        ModelLayoutMigration.migrate(root: root)
        try Self.expectValidManifest(Self.targetFolder(root), Self.v3, "\(c)")
        // …and it is idempotent: a second pass changes nothing and re-hashes nothing.
        #expect(ModelLayoutMigration.migrate(root: root).isEmpty, "\(c)")
        try Self.expectValidManifest(Self.targetFolder(root), Self.v3, "\(c) second pass")
    }

    /// The already-damaged install: an earlier build's `adoptedExisting` already ran and left a
    /// complete, manifest-less model with no legacy folder to migrate. Nothing else in the app ever
    /// writes a manifest for an installed model, so if this pass does not heal it, nothing will.
    @Test func aModelLeftManifestLessByAnEarlierRunIsHealed() throws {
        let root = try Self.tempDir()
        try Self.makeModel(Self.v3, at: Self.targetFolder(root), manifest: false)
        #expect(ModelIntegrity.assess(Self.v3, at: Self.targetFolder(root)) != .verified)

        let results = ModelLayoutMigration.migrate(root: root)
        #expect(results.map(\.outcome) == [.nothingToDo])
        #expect(results[0].manifest == .rebuilt)
        try Self.expectValidManifest(Self.targetFolder(root), Self.v3, "healed no-op")
    }

    /// The one case where writing a manifest would be worse than having none: a manifest built over
    /// a truncated file records the truncation as correct, converting a detectable fault into a
    /// permanent lie. So an incomplete folder gets nothing.
    @Test func noManifestIsWrittenForAnIncompleteModel() throws {
        let root = try Self.tempDir()
        let folder = try Self.makeModel(Self.v3, at: Self.targetFolder(root), manifest: false)
        try Self.leaveDownloadDebris(in: folder, Self.v3)

        #expect(ModelManifest.ensure(for: Self.v3, at: folder) == .notRebuilt)
        #expect(ModelManifest.load(from: folder) == nil)
        #expect(ModelManifest.ensure(for: Self.v3, at: root.appendingPathComponent("nope")) == .noFolder)
    }

    // MARK: - Defect 1: a manifest-less model never reads as verified

    /// `problems(for:at:)` returning empty means "nothing we can see is wrong", and without a
    /// manifest the set of things we can see is strictly smaller. The two must not flatten together.
    @Test func aManifestLessModelIsUsableButNeverVerified() throws {
        let root = try Self.tempDir()
        let folder = try Self.makeModel(Self.v3, at: Self.targetFolder(root), manifest: false)

        let verdict = ModelIntegrity.assess(Self.v3, at: folder)
        #expect(verdict != .verified)
        #expect(!verdict.isManifestBacked)
        #expect(verdict.isUsable)                                   // it still loads; that is not the same claim
        if case .unverifiable(let reason) = verdict {
            #expect(reason.contains(ModelManifest.fileName))
        } else {
            Issue.record("expected .unverifiable, got \(verdict)")
        }
        // The check the manifest is the *only* way to make: a file at the right path, right name,
        // half the bytes. Invisible without a manifest, caught with one.
        try ModelManifest.build(modelID: Self.v3.id, hfRepo: Self.v3.hfRepo, folder: folder).save(to: folder)
        #expect(ModelIntegrity.assess(Self.v3, at: folder) == .verified)
        let weights = folder.appendingPathComponent(Self.v3.requiredPaths.first { $0.hasSuffix(".mlmodelc") }!)
            .appendingPathComponent("weights/weight.bin")
        try Data(repeating: 2, count: 16).write(to: weights)
        #expect(!ModelIntegrity.assess(Self.v3, at: folder).isUsable)
    }

    /// An outright missing folder is incomplete, not merely unverifiable.
    @Test func anAbsentModelIsIncompleteNotUnverifiable() throws {
        let root = try Self.tempDir()
        let verdict = ModelIntegrity.assess(Self.v3, at: Self.targetFolder(root))
        #expect(!verdict.isUsable)
        #expect(!verdict.isManifestBacked)
    }

    // MARK: - Defect 2: parked directories are swept

    private static func park(_ root: URL, _ name: String, kind: String = "superseded",
                             token: String = UUID().uuidString, bytes: Int = 2048) throws -> URL {
        let url = root.appendingPathComponent("\(name).\(kind)-\(token)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url.appendingPathComponent("weight.bin"))
        return url
    }

    /// Both park spellings go — `.superseded-` from the migration, `.replaced-` from the atomic
    /// publish in `FluidAudioFetcher.fetch` — and the bytes are reported.
    @Test func staleParkedDirectoriesAreRemoved() throws {
        let root = try Self.tempDir()
        let a = try Self.park(root, Self.v3.folderName, kind: "superseded")
        let b = try Self.park(root, Self.v3.folderName, kind: "replaced")
        let c = try Self.park(root, Self.v3.legacyFolderNames[0], kind: "replaced")
        // A claim marker left by a sweep that was killed between the rename and the delete is itself
        // collectable, so an interrupted sweep cannot become new litter.
        let d = try Self.park(root, ModelCatalog.folderName(for: .parakeetTDTCTC110m), kind: "sweeping")

        let swept = ParkedModelDirectories.sweep(root: root, now: Date().addingTimeInterval(3600))
        #expect(Set(swept.map(\.name)) == Set([a, b, c, d].map(\.lastPathComponent)))
        #expect(swept.allSatisfy { $0.bytes == 2048 })
        for url in [a, b, c, d] { #expect(!FileManager.default.fileExists(atPath: url.path)) }
        #expect(ParkedModelDirectories.sweep(root: root, now: Date().addingTimeInterval(3600)).isEmpty)
    }

    /// The grace period is the guard against deleting a park a *live* process is mid-swap over. A
    /// park is only ever live for one rename plus one delete, so anything young is left alone.
    ///
    /// It has to be measured from attribute-modification time, not `mtime`: parking is a rename, and
    /// a rename bumps `st_ctime` while leaving `st_mtime` and the birth time as they were. A park
    /// made by moving a year-old model tree reads as a year old by `mtime` and as seconds old here.
    @Test func aFreshlyParkedDirectoryIsLeftAlone() throws {
        let root = try Self.tempDir()
        let real = try Self.makeModel(Self.v3, at: Self.targetFolder(root))
        let parked = Self.targetFolder(root).appendingPathExtension("superseded-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: real, to: parked)          // exactly how a park is made
        // Backdate content and birth time; only the rename's ctime says it is young.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0),
                                               .creationDate: Date(timeIntervalSince1970: 0)],
                                              ofItemAtPath: parked.path)

        #expect(ParkedModelDirectories.sweep(root: root).isEmpty)
        #expect(FileManager.default.fileExists(atPath: parked.path))
        // …and once the grace period has passed, it goes.
        #expect(ParkedModelDirectories.sweep(root: root, now: Date().addingTimeInterval(3600)).count == 1)
        #expect(!FileManager.default.fileExists(atPath: parked.path))
    }

    /// Everything the sweeper must not touch, in one place. Each of these is a way a `rm -rf` of a
    /// name read out of a directory listing could go wrong.
    @Test func theSweeperTouchesNothingItDoesNotOwn() throws {
        let root = try Self.tempDir()
        let fm = FileManager.default
        var survivors: [URL] = []

        // A real installed model, under both its current and its legacy name.
        survivors.append(try Self.makeModel(Self.v3, at: Self.targetFolder(root)))
        survivors.append(try Self.makeModel(Self.v3, at: Self.legacyFolder(root)))
        // Another application's directory — the reporter had 1.2 GB of one of these — including one
        // deliberately spelled like a park.
        let stranger = root.appendingPathComponent("qwen3-asr-0.6b", isDirectory: true)
        try fm.createDirectory(at: stranger, withIntermediateDirectories: true)
        survivors.append(stranger)
        survivors.append(try Self.park(root, "qwen3-asr-0.6b"))
        // Our own staging directory: a cancelled download's `.partial` files live there on purpose,
        // resumable, and deleting them costs the user the bytes again.
        let staging = FluidAudioFetcher.stagingFolder(for: .parakeetTDTv3, beside: Self.targetFolder(root))
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        survivors.append(staging)
        // Right base name, suffix that is not one of ours or not a UUID.
        survivors.append(try Self.park(root, Self.v3.folderName, kind: "backup"))
        survivors.append(try Self.park(root, Self.v3.folderName, token: "not-a-uuid"))
        survivors.append(try Self.park(root, Self.v3.folderName, token: ""))
        // A *file* named like a park.
        let file = root.appendingPathComponent("\(Self.v3.folderName).superseded-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: file)
        survivors.append(file)

        // A symlink named like a park, pointing at something outside the root. Following it would
        // delete a directory the sweeper was never given.
        let outside = try Self.tempDir()
        try Data("precious".utf8).write(to: outside.appendingPathComponent("keep.txt"))
        let link = root.appendingPathComponent("\(Self.v3.folderName).superseded-\(UUID().uuidString)")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)

        #expect(ParkedModelDirectories.sweep(root: root, now: Date().addingTimeInterval(3600)).isEmpty)
        for url in survivors { #expect(fm.fileExists(atPath: url.path), "\(url.lastPathComponent)") }
        #expect(fm.fileExists(atPath: link.path))
        #expect(fm.fileExists(atPath: outside.appendingPathComponent("keep.txt").path))
        // Nothing beneath the surviving model was disturbed either.
        #expect(ModelIntegrity.isComplete(Self.v3, at: Self.targetFolder(root)))
    }

    /// `~/Library/Application Support/FluidAudio/Models` belongs to a different application. We read
    /// models out of it as a warm-start courtesy and are never entitled to delete inside it.
    @Test func theSweeperRefusesAnotherApplicationsModelsRoot() throws {
        let foreign = ModelManager.defaultExternalCaches()[.parakeetTDTv3]!.first!.deletingLastPathComponent()
        #expect(!ParkedModelDirectories.isSweepableRoot(foreign))
        #expect(!ParkedModelDirectories.isSweepableRoot(foreign.appendingPathComponent("anything")))
        #expect(ParkedModelDirectories.isSweepableRoot(ModelCatalog.modelsRoot()))
        #expect(ParkedModelDirectories.sweep(root: foreign, now: Date().addingTimeInterval(3600)).isEmpty)
    }

    /// Name parsing, on its own, because model folder names contain dots of their own
    /// (`parakeet-tdt-0.6b-v3`) and parsing from the left would take the base name apart.
    @Test func parkedNamesAreParsedFromTheRight() {
        let uuid = UUID().uuidString
        #expect(ParkedModelDirectories.parkedFolderName("parakeet-tdt-0.6b-v3.superseded-\(uuid)") == "parakeet-tdt-0.6b-v3")
        #expect(ParkedModelDirectories.parkedFolderName("parakeet-tdt-0.6b-v3-coreml.replaced-\(uuid)") == "parakeet-tdt-0.6b-v3-coreml")
        #expect(ParkedModelDirectories.parkedFolderName("parakeet-tdt-0.6b-v3") == nil)
        #expect(ParkedModelDirectories.parkedFolderName("parakeet-tdt-0.6b-v3.superseded-\(uuid)x") == nil)
        #expect(ParkedModelDirectories.parkedFolderName(".staging-parakeetTDTv3") == nil)
        #expect(ParkedModelDirectories.parkedFolderName("something-else.superseded-\(uuid)") == nil)
    }

    // MARK: - Wiring

    /// The manager does both jobs on the way up, so a crash mid-swap is cleaned up by the next
    /// launch rather than never — and `repair(_:)`, the recovery path a failed install runs, sees
    /// parked directories too instead of only scratch files.
    @Test func theManagerMigratesAndSweepsOnInit() async throws {
        let root = try Self.tempDir()
        try Self.makeModel(Self.v3, at: Self.legacyFolder(root))
        try Self.makeModel(Self.v3, at: Self.targetFolder(root), manifest: false)
        let stale = try Self.park(root, Self.v3.folderName, kind: "replaced")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)],
                                              ofItemAtPath: stale.path)

        let manager = ModelManager(root: root, fetchers: [:], externalCaches: [:])
        #expect(await manager.isPresent(.parakeetTDTv3))
        try Self.expectValidManifest(Self.targetFolder(root), Self.v3, "after init")
        #expect(await manager.assess(.parakeetTDTv3) == .verified)

        // The park was made seconds ago, so the grace period spares it on this launch — that is the
        // guard doing its job, not a miss. `repair` looks at it on the same terms.
        #expect(FileManager.default.fileExists(atPath: stale.path))
        await manager.repair(.parakeetTDTv3)
        #expect(ParkedModelDirectories.sweep(root: root, now: Date().addingTimeInterval(3600)).count == 1)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }

    /// `.skip` is what keeps `swift test` from rearranging a developer's real 468 MB model store:
    /// eleven tests point `ModelManager` at `ModelCatalog.modelsRoot()` to read real models.
    @Test func skippedMaintenanceLeavesTheRootExactlyAsItFoundIt() async throws {
        let root = try Self.tempDir()
        try Self.makeModel(Self.v3, at: Self.legacyFolder(root))
        let stale = try Self.park(root, Self.v3.folderName, kind: "replaced")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0),
                                               .creationDate: Date(timeIntervalSince1970: 0)],
                                              ofItemAtPath: stale.path)
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))

        _ = ModelManager(root: root, fetchers: [:], externalCaches: [:], maintenance: .skip)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)) == before)
        #expect(FileManager.default.fileExists(atPath: Self.legacyFolder(root).path))
        #expect(FileManager.default.fileExists(atPath: stale.path))
    }

    /// The maintenance pass holds a cross-process lock so two VoicePlus processes launching together
    /// cannot interleave a park, a rename and a delete over the same two paths. Bounded, and it runs
    /// the work either way: a hung holder must not turn into an app that never finishes launching.
    @Test func theRootLockRunsItsBodyAndReleases() throws {
        let root = try Self.tempDir()
        var runs = 0
        for _ in 0..<3 {
            let value = ModelRootLock.withLock(root: root, waitingUpTo: 1) { runs += 1; return runs }
            #expect(value == runs)
        }
        #expect(runs == 3)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(ModelRootLock.fileName).path))
        // The lock file itself is not mistaken for a park or a model.
        #expect(ParkedModelDirectories.sweep(root: root, now: Date().addingTimeInterval(3600)).isEmpty)
    }
}
