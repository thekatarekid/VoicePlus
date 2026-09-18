import Foundation
import Testing
import Shared
@testable import Engine

/// A5 / V4.8 — the model store's maintenance pass (layout migration + parked sweep) is off the
/// launch path. `ModelManager.init` used to run it synchronously under a cross-process file lock,
/// on the path that builds the container, so the hotkey was not armed until another process let go
/// of the lock. These run the pass under a fake lock the test holds.
@Suite("Model maintenance off the launch path (V4.8)", .serialized)
struct ModelMaintenanceOffLaunchTests {

    static let v3 = ModelCatalog.descriptor(.parakeetTDTv3)

    private static func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceplus-maint-a5-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private static func makeModel(_ d: ModelDescriptor, at folder: URL) throws -> URL {
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
        return folder
    }

    private static func legacyFolder(_ root: URL) -> URL { root.appendingPathComponent(v3.legacyFolderNames[0], isDirectory: true) }
    private static func targetFolder(_ root: URL) -> URL { ModelCatalog.folder(for: .parakeetTDTv3, in: root) }
    private static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// A cross-process lock the test holds. `body` runs only after `release()`, and the lock records
    /// that it ran — and that the migration happened inside it.
    final class HeldLock: @unchecked Sendable {
        private let entered = DispatchSemaphore(value: 0)
        private let gate = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var _entries = 0
        private var _bodies = 0
        private var _legacyBefore: Bool?
        private var _legacyAfter: Bool?
        let legacy: URL

        init(legacy: URL) { self.legacy = legacy }

        var entries: Int { lock.withLock { _entries } }
        var bodies: Int { lock.withLock { _bodies } }
        /// Whether the legacy folder existed just before / just after the body, i.e. the migration
        /// ran *under* the lock.
        var legacyAroundBody: (Bool?, Bool?) { lock.withLock { (_legacyBefore, _legacyAfter) } }

        var rootLock: ModelManager.RootLock {
            { [self] _, body in
                lock.withLock { _entries += 1 }
                entered.signal()
                gate.wait()
                lock.withLock { _legacyBefore = FileManager.default.fileExists(atPath: legacy.path) }
                body()
                lock.withLock {
                    _legacyAfter = FileManager.default.fileExists(atPath: legacy.path)
                    _bodies += 1
                }
            }
        }

        func waitUntilEntered(seconds: TimeInterval = 5) -> Bool { entered.wait(timeout: .now() + seconds) == .success }
        func release() { gate.signal() }
    }

    final class LoaderLog: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        var calls: [URL] { lock.withLock { urls } }
        func record(_ url: URL) { lock.withLock { urls.append(url) } }
    }

    /// The acceptance test: with the lock held by someone else, `init` returns at once, and the pass
    /// still completes — under the lock — once it is released.
    @Test func initReturnsBeforeMaintenanceCompletes() async throws {
        let root = try Self.tempDir()
        try Self.makeModel(Self.v3, at: Self.legacyFolder(root))
        let held = HeldLock(legacy: Self.legacyFolder(root))

        let t0 = Date()
        let manager = ModelManager(root: root, fetchers: [:], externalCaches: [:], rootLock: held.rootLock)
        #expect(Date().timeIntervalSince(t0) < 1, "init waited on the maintenance lock")
        #expect(!manager.isMaintenanceComplete)

        manager.startMaintenance()
        #expect(held.waitUntilEntered(), "the pass never reached the lock")
        #expect(!manager.isMaintenanceComplete, "the pass must still be waiting on the held lock")
        #expect(Self.exists(Self.legacyFolder(root)), "nothing may move before the lock is taken")

        held.release()
        await manager.maintenanceFinished()
        #expect(manager.isMaintenanceComplete)
        #expect(held.bodies == 1)
        #expect(held.legacyAroundBody == (true, false), "the migration ran inside the lock")
        #expect(!Self.exists(Self.legacyFolder(root)))
        #expect(Self.exists(Self.targetFolder(root)))
        #expect(await manager.locate(.parakeetTDTv3) == Self.targetFolder(root))
    }

    /// What the app uses: `.deferred` never starts the pass from a read, so the container build's
    /// `isPresent` neither blocks nor migrates — and an unmigrated install still reads as present.
    @Test func deferredReadsNeitherStartNorWaitForThePass() async throws {
        let root = try Self.tempDir()
        try Self.makeModel(Self.v3, at: Self.legacyFolder(root))
        let held = HeldLock(legacy: Self.legacyFolder(root))
        let manager = ModelManager(root: root, fetchers: [:], externalCaches: [:], maintenance: .deferred, rootLock: held.rootLock)

        #expect(await manager.isPresent(.parakeetTDTv3), "an unmigrated install is present, not missing")
        #expect(await RecognizerFactory.chooseFinal(manager: manager, appleSpeechAvailable: false) == .tdtV3)
        #expect(held.entries == 0, "a read on the build path started the pass")
        #expect(Self.exists(Self.legacyFolder(root)))

        manager.startMaintenance()
        #expect(held.waitUntilEntered())
        held.release()
        await manager.maintenanceFinished()
        #expect(await manager.locate(.parakeetTDTv3) == Self.targetFolder(root), "after the pass, the migrated folder")
    }

    /// A migration that ran halfway through a load would move the folder out from under CoreML, so
    /// the pass that used to finish inside `init` is awaited by `load` instead — and a load is
    /// allowed to start it if the app has not yet.
    @Test func loadWaitsForThePassAndLoadsTheMigratedFolder() async throws {
        let root = try Self.tempDir()
        try Self.makeModel(Self.v3, at: Self.legacyFolder(root))
        let held = HeldLock(legacy: Self.legacyFolder(root))
        let log = LoaderLog()
        let manager = ModelManager(root: root, fetchers: [:], externalCaches: [:],
                                   loader: { _, _, url in
                                       log.record(url)
                                       throw ModelManagerError.unsupported(.whisperSmall)   // no CoreML in CI
                                   },
                                   maintenance: .deferred, rootLock: held.rootLock)

        let load = Task { try? await manager.load(.parakeetTDTv3) }
        #expect(held.waitUntilEntered(), "the load did not start the pending pass")
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(log.calls.isEmpty, "CoreML was handed a folder while the migration was pending")

        held.release()
        _ = await load.value
        #expect(log.calls == [Self.targetFolder(root)], "the load must see the migrated layout")
        #expect(!Self.exists(Self.legacyFolder(root)))
    }

    /// `.run` (the default outside the app) still settles the layout before the first read — inline,
    /// on first use, instead of in `init`.
    @Test func runModeSettlesOnTheFirstRead() async throws {
        let root = try Self.tempDir()
        try Self.makeModel(Self.v3, at: Self.legacyFolder(root))
        let manager = ModelManager(root: root, fetchers: [:], externalCaches: [:])
        #expect(!manager.isMaintenanceComplete, "init ran the pass")
        #expect(Self.exists(Self.legacyFolder(root)))
        #expect(await manager.isPresent(.parakeetTDTv3))
        #expect(manager.isMaintenanceComplete)
        #expect(!Self.exists(Self.legacyFolder(root)))
        #expect(await manager.locate(.parakeetTDTv3) == Self.targetFolder(root))
    }

    @Test func skipNeverTouchesTheRoot() async throws {
        let root = try Self.tempDir()
        try Self.makeModel(Self.v3, at: Self.legacyFolder(root))
        let held = HeldLock(legacy: Self.legacyFolder(root))
        let manager = ModelManager(root: root, fetchers: [:], externalCaches: [:], maintenance: .skip, rootLock: held.rootLock)
        manager.startMaintenance()
        await manager.maintenanceFinished()
        _ = await manager.isPresent(.parakeetTDTv3)
        #expect(manager.isMaintenanceComplete)
        #expect(held.entries == 0)
        #expect(Self.exists(Self.legacyFolder(root)))
    }

    // MARK: the pass itself

    final class RunCount: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        var value: Int { lock.withLock { n } }
        func bump() { lock.withLock { n += 1 } }
    }

    @Test func thePassRunsExactlyOnceHoweverItIsReached() async {
        let runs = RunCount()
        let pass = ModelMaintenancePass(skipped: false) { runs.bump() }
        #expect(pass.current == .pending)
        pass.waitWhileRunning()                 // pending: returns without running it
        #expect(runs.value == 0)
        pass.startDetached()
        pass.startDetached()
        await pass.finished()
        pass.runOrWait()
        await pass.finished()
        #expect(runs.value == 1)
        #expect(pass.isComplete)
    }

    @Test func concurrentWaitersAllResumeWhenThePassFinishes() async {
        let gate = DispatchSemaphore(value: 0)
        let pass = ModelMaintenancePass(skipped: false) { gate.wait() }
        pass.startDetached()
        async let a: Void = pass.finished()
        async let b: Void = pass.finished()
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(!pass.isComplete)
        gate.signal()
        _ = await (a, b)
        #expect(pass.isComplete)
    }
}
