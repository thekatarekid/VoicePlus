import Foundation
import Testing
import Shared
@testable import Engine

/// Regression cover for the 1.7.9 report: onboarding downloaded the Fast tier, said "Using Parakeet
/// TDT-CTC 110M (tiny)", and the first "Dictate now" failed with
/// `The file "weight.bin.partial" doesn't exist.`
///
/// The file is FluidAudio's `FileDownloader` scratch: it streams a body into `<dest>.partial` and
/// then moves it into place. One sitting inside a `.mlmodelc` means that file never finished.
@Suite("Model integrity + atomic install", .serialized)
struct ModelIntegrityTests {

    // MARK: - Fixtures

    private static func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceplus-integrity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A model folder shaped like a real one: `.mlmodelc` bundles with `coremldata.bin` and a
    /// `weights/weight.bin`, plain files for everything else.
    @discardableResult
    private static func makeModel(_ d: ModelDescriptor, at folder: URL) throws -> URL {
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
        return folder
    }

    /// The error an async throwing body threw, or nil. `#expect(throws:)` cannot hand the value
    /// back from a body whose result is discarded, and these tests assert on the *message*.
    private static func errorFrom(_ body: () async throws -> Void) async -> Error? {
        do { try await body(); return nil } catch { return error }
    }

    private static let tiny = ModelCatalog.descriptor(.parakeetTDTCTC110m)
    private static let best = ModelCatalog.descriptor(.parakeetTDTv3)

    // MARK: - "Does it exist" is not "is it a model"

    @Test func completeModelReportsComplete() throws {
        let folder = try Self.makeModel(Self.tiny, at: Self.tempDir().appendingPathComponent("m"))
        #expect(ModelIntegrity.problems(for: Self.tiny, at: folder).isEmpty)
    }

    /// The bug itself: a `.mlmodelc` mid-download holds `weights/weight.bin.partial`, and the
    /// directory exists from the first byte — so bare `fileExists` called it installed.
    @Test func partialFileInsideBundleIsNotInstalled() throws {
        let folder = try Self.makeModel(Self.tiny, at: Self.tempDir().appendingPathComponent("m"))
        let weights = folder.appendingPathComponent("Decoder.mlmodelc/weights")
        try FileManager.default.removeItem(at: weights.appendingPathComponent("weight.bin"))
        try Data(repeating: 3, count: 100).write(to: weights.appendingPathComponent("weight.bin.partial"))

        let problems = ModelIntegrity.problems(for: Self.tiny, at: folder)
        #expect(problems.contains { $0.contains("weight.bin.partial") && $0.contains("unfinished") })
        #expect(!ModelIntegrity.isComplete(Self.tiny, at: folder))
        // The old check — every required path exists — still passes, which is exactly why the
        // model reported installed while it could not load.
        #expect(Self.tiny.requiredPaths.allSatisfy {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        })
    }

    /// Both tiers run the same fetcher, the same presence check and the same loader. "Best"
    /// downloaded successfully for this user; nothing about it was safer.
    @Test func everyTierIsJudgedTheSameWay() throws {
        for descriptor in [Self.tiny, Self.best, ModelCatalog.descriptor(.parakeetEOU160)] {
            let folder = try Self.makeModel(descriptor, at: Self.tempDir().appendingPathComponent("m"))
            #expect(ModelIntegrity.isComplete(descriptor, at: folder))
            let bundle = try #require(descriptor.requiredPaths.first { $0.hasSuffix(".mlmodelc") })
            try Data(repeating: 4, count: 8).write(
                to: folder.appendingPathComponent("\(bundle)/weights/weight.bin.partial"))
            #expect(!ModelIntegrity.isComplete(descriptor, at: folder),
                    "\(descriptor.id.rawValue) must not report installed with a .partial inside")
        }
    }

    @Test func bundleWithoutCoreMLDataIsNotInstalled() throws {
        let folder = try Self.makeModel(Self.tiny, at: Self.tempDir().appendingPathComponent("m"))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("Decoder.mlmodelc/coremldata.bin"))
        #expect(ModelIntegrity.problems(for: Self.tiny, at: folder).contains { $0.contains("coremldata.bin") })
    }

    @Test func missingRequiredFileIsNotInstalled() throws {
        let folder = try Self.makeModel(Self.tiny, at: Self.tempDir().appendingPathComponent("m"))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("parakeet_vocab.json"))
        #expect(ModelIntegrity.problems(for: Self.tiny, at: folder) == ["parakeet_vocab.json is missing"])
    }

    /// A file truncated after install — the failure mode a full disk produces — is caught by the
    /// manifest's byte counts without re-hashing half a gigabyte.
    @Test func truncationAgainstTheManifestIsCaught() throws {
        let folder = try Self.makeModel(Self.tiny, at: Self.tempDir().appendingPathComponent("m"))
        try ModelManifest.build(modelID: .parakeetTDTCTC110m, hfRepo: Self.tiny.hfRepo, folder: folder).save(to: folder)
        #expect(ModelIntegrity.isComplete(Self.tiny, at: folder))
        try Data(repeating: 2, count: 8).write(to: folder.appendingPathComponent("Decoder.mlmodelc/weights/weight.bin"))
        #expect(ModelIntegrity.problems(for: Self.tiny, at: folder).contains { $0.contains("truncated") })
    }

    @Test func manifestNeverRecordsDownloadScratch() throws {
        let folder = try Self.makeModel(Self.tiny, at: Self.tempDir().appendingPathComponent("m"))
        try Data(repeating: 9, count: 32).write(to: folder.appendingPathComponent("Decoder.mlmodelc/weights/weight.bin.partial"))
        let manifest = try ModelManifest.build(modelID: .parakeetTDTCTC110m, hfRepo: Self.tiny.hfRepo, folder: folder)
        #expect(!manifest.files.contains { $0.path.contains(".partial") })
    }

    /// Repair drops the *bundle* the debris sits in, not just the debris. A bundle caught
    /// mid-download is missing an interior weight file that no `requiredPaths` list names, so
    /// deleting only the `.partial` would leave something that passes every check and still cannot
    /// load. Its intact siblings survive: a retry costs one bundle, not the whole model.
    @Test func repairRemovesTheIncompleteBundleAndKeepsTheRest() throws {
        let folder = try Self.makeModel(Self.tiny, at: Self.tempDir().appendingPathComponent("m"))
        let weights = folder.appendingPathComponent("Decoder.mlmodelc/weights")
        try Data(repeating: 3, count: 10).write(to: weights.appendingPathComponent("weight.bin.partial"))
        try Data("etag".utf8).write(to: weights.appendingPathComponent("weight.bin.partial.etag"))

        let removed = ModelIntegrity.removeIncompleteParts(under: folder)
        #expect(removed == ["Decoder.mlmodelc"])
        #expect(ModelIntegrity.scratchFiles(under: folder).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("Decoder.mlmodelc").path))
        // Untouched bundles stay: re-downloading is one bundle, not 110 MB.
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Preprocessor.mlmodelc/coremldata.bin").path))
        // And the model now reports what is true — not installed — so the UI offers a re-download.
        #expect(!ModelIntegrity.isComplete(Self.tiny, at: folder))
    }

    // MARK: - ModelManager

    /// Fetcher that writes a half-finished tree and returns *successfully* — the shape of a
    /// download that reported complete while the bytes were not there.
    final class HalfFinishedFetcher: ModelFetcher, @unchecked Sendable {
        var calls = 0
        func fetch(_ d: ModelDescriptor, into folder: URL, progress: ModelProgressHandler?) async throws {
            calls += 1
            try ModelIntegrityTests.makeModel(d, at: folder)
            let bundle = d.requiredPaths.first { $0.hasSuffix(".mlmodelc") }!
            let weights = folder.appendingPathComponent("\(bundle)/weights")
            try FileManager.default.removeItem(at: weights.appendingPathComponent("weight.bin"))
            try Data(repeating: 3, count: 16).write(to: weights.appendingPathComponent("weight.bin.partial"))
        }
    }

    @Test func downloadThatLandsIncompleteIsNotReportedInstalled() async throws {
        let root = try Self.tempDir()
        let fetcher = HalfFinishedFetcher()
        let manager = ModelManager(root: root, fetchers: [.finalTDT: fetcher], externalCaches: [:])

        await #expect(throws: ModelManagerError.self) { try await manager.ensureAvailable(.parakeetTDTCTC110m) }
        #expect(await !manager.isPresent(.parakeetTDTCTC110m))
        #expect(await manager.status(.parakeetTDTCTC110m) == .missing)
        #expect(await manager.bestFinalModelOnDisk() == nil)
        // And the debris is gone, so the retry is a retry rather than a second trip over the
        // same file. This is the recovery a user with a broken model on disk gets, unprompted.
        #expect(ModelIntegrity.scratchFiles(under: root.appendingPathComponent("parakeet-tdt-ctc-110m-coreml")).isEmpty)
        #expect(await !manager.isPresent(.parakeetTDTCTC110m), "repair must not leave a shell that reports installed")
    }

    @Test func incompleteModelFailsWithPlainLanguageNotAFileNSError() async throws {
        let root = try Self.tempDir()
        let folder = try Self.makeModel(Self.tiny, at: root.appendingPathComponent("parakeet-tdt-ctc-110m-coreml"))
        try Data(repeating: 3, count: 16).write(
            to: folder.appendingPathComponent("Decoder.mlmodelc/weights/weight.bin.partial"))
        let manager = ModelManager(root: root, fetchers: [:], externalCaches: [:])

        // `locate` refuses it, so this is `notPresent` rather than a CoreML crash — either way the
        // point is the sentence, which must name the model and a way out.
        let thrown = await Self.errorFrom { _ = try await manager.load(.parakeetTDTCTC110m) }
        #expect(thrown is ModelManagerError)
        let message = EngineMessage.describe(try #require(thrown))
        #expect(message.contains("Parakeet TDT-CTC 110M"))
        #expect(!message.contains(".partial"))
        #expect(message.lowercased().contains("download"))
    }

    /// The verbatim error from the report, as Cocoa produces it, must never reach a human.
    @Test func rawPartialFileErrorIsRewrittenForHumans() {
        let raw = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError, userInfo: [
            NSFilePathErrorKey: "/Models/parakeet-tdt-ctc-110m-coreml/Decoder.mlmodelc/weights/weight.bin.partial",
            NSLocalizedDescriptionKey: "The file “weight.bin.partial” doesn’t exist.",
        ])
        let message = EngineMessage.describe(raw)
        #expect(!message.contains("weight.bin.partial"))
        #expect(message.contains("didn’t finish downloading"))
        // Unrelated Cocoa file errors keep their own (already useful) description.
        let other = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError, userInfo: [
            NSFilePathErrorKey: "/tmp/notes.txt",
            NSLocalizedDescriptionKey: "The file “notes.txt” doesn’t exist.",
        ])
        #expect(EngineMessage.describe(other).contains("notes.txt"))
    }

    @Test func incompleteErrorNamesTheModelAndTheRecovery() {
        let text = try? #require(ModelManagerError.incomplete(.parakeetTDTv3, ["Encoder.mlmodelc/weights/weight.bin.partial is an unfinished download"]).errorDescription)
        let message = text ?? ""
        #expect(message.contains("Parakeet TDT 0.6B v3"))
        #expect(message.contains("Models"))
    }

    /// A fetcher that never finishes: the model must not report installed at any point while it
    /// runs, and cancelling must leave nothing that does.
    final class SlowFetcher: ModelFetcher, @unchecked Sendable {
        func fetch(_ d: ModelDescriptor, into folder: URL, progress: ModelProgressHandler?) async throws {
            // Materialise the directories first — this is what made an in-flight download look done.
            try ModelIntegrityTests.makeModel(d, at: folder)
            let bundle = d.requiredPaths.first { $0.hasSuffix(".mlmodelc") }!
            try FileManager.default.removeItem(at: folder.appendingPathComponent("\(bundle)/weights/weight.bin"))
            try Data(repeating: 3, count: 8).write(
                to: folder.appendingPathComponent("\(bundle)/weights/weight.bin.partial"))
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    @Test func cancelledDownloadLeavesNothingThatReportsInstalled() async throws {
        let root = try Self.tempDir()
        let manager = ModelManager(root: root, fetchers: [.finalTDT: SlowFetcher()], externalCaches: [:])
        let download = Task { try await manager.ensureAvailable(.parakeetTDTCTC110m) }
        // Let the fetcher lay down its directory tree before pulling the plug.
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(await !manager.isPresent(.parakeetTDTCTC110m))
        await manager.cancelDownload(.parakeetTDTCTC110m)
        _ = try? await download.value
        #expect(await !manager.isPresent(.parakeetTDTCTC110m))
        #expect(await manager.status(.parakeetTDTCTC110m) == .missing)
    }

    /// Counts overlapping loads. Two callers used to get two, because `load` suspends and an actor
    /// does not hold itself across a suspension — and each of those loads can re-download.
    final class LoadCounter: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var starts = 0
        private(set) var concurrentPeak = 0
        private var live = 0
        func enter() { lock.withLock { starts += 1; live += 1; concurrentPeak = max(concurrentPeak, live) } }
        func leave() { lock.withLock { live -= 1 } }
    }

    /// The root cause. `load` is actor-isolated but suspends on the CoreML load, and an actor
    /// releases itself across a suspension — so the launch preload and the user's first hotkey press
    /// both saw `loaded[id] == nil` and both went on to load. Each of those loads re-downloads
    /// whatever the cache is missing, and two downloads over one folder race on the same
    /// `weight.bin.partial`: one wins the move, the loser reports it missing.
    @Test func concurrentLoadsShareOneLoad() async throws {
        let root = try Self.tempDir()
        try Self.makeModel(Self.tiny, at: root.appendingPathComponent("parakeet-tdt-ctc-110m-coreml"))
        let counter = LoadCounter()
        let manager = ModelManager(root: root, fetchers: [:], externalCaches: [:]) { _, _, _ in
            counter.enter()
            defer { counter.leave() }
            try await Task.sleep(nanoseconds: 200_000_000)
            throw ModelManagerError.unsupported(.whisperSmall)   // stand-in: no CoreML models in CI
        }
        async let a: LoadedModel? = try? await manager.load(.parakeetTDTCTC110m)
        async let b: LoadedModel? = try? await manager.load(.parakeetTDTCTC110m)
        async let c: LoadedModel? = try? await manager.load(.parakeetTDTCTC110m)
        _ = await (a, b, c)
        #expect(counter.concurrentPeak == 1, "two loads over one model folder is what races on the scratch file")
        #expect(counter.starts == 1, "concurrent callers must share one load task")
        #expect(await !manager.isLoaded(.parakeetTDTCTC110m))
    }

    /// A load that dies on the scratch file — the raw failure from the report — comes back as a
    /// recoverable, plain-language error, and the debris is cleared so pressing the key again works.
    @Test func loadFailingOnScratchFileBecomesRecoverable() async throws {
        let root = try Self.tempDir()
        let folder = root.appendingPathComponent("parakeet-tdt-ctc-110m-coreml")
        try Self.makeModel(Self.tiny, at: folder)
        let scratch = folder.appendingPathComponent("Decoder.mlmodelc/weights/weight.bin.partial")
        let manager = ModelManager(root: root, fetchers: [:], externalCaches: [:]) { _, _, _ in
            // Exactly what FileDownloader throws when it loses the race for its own scratch file.
            try Data(repeating: 3, count: 8).write(to: scratch)
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError, userInfo: [
                NSFilePathErrorKey: scratch.path,
                NSLocalizedDescriptionKey: "The file \u{201C}weight.bin.partial\u{201D} doesn\u{2019}t exist.",
            ])
        }
        let thrown = await Self.errorFrom { _ = try await manager.load(.parakeetTDTCTC110m) }
        #expect(thrown is ModelManagerError)
        let message = EngineMessage.describe(try #require(thrown))
        #expect(!message.contains("weight.bin.partial"))
        #expect(message.contains("Parakeet TDT-CTC 110M"))
        #expect(ModelIntegrity.scratchFiles(under: folder).isEmpty, "the retry must not trip over the same debris")
        #expect(!ModelIntegrity.isComplete(Self.tiny, at: folder), "an incomplete model must report not installed, so the UI offers a re-download")
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Preprocessor.mlmodelc/coremldata.bin").path),
                "intact bundles are kept: a retry costs one bundle, not the model")
    }
}
