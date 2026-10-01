import FluidAudio
import Foundation
import Testing
import Shared
@testable import Engine

/// H3 (V4.50) — the speaker-embedding weights are a required part of the stack, and the factory
/// picks WeSpeaker whenever a complete copy is on disk. CoreML is never asked to load a fixture:
/// the choice is tested with an injected loader; the real weights are exercised only when this
/// machine happens to have them.
@Suite("H3 — speaker-embedding weights in the catalog, and the factory's choice")
struct SpeakerModelCatalogTests {
    private static func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceplus-speaker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A folder that passes `ModelIntegrity` for `descriptor`: bundles with `coremldata.bin` + weights.
    private static func writeModel(_ descriptor: ModelDescriptor, at folder: URL, skip: Set<String> = []) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for path in descriptor.requiredPaths where !skip.contains(path) {
            let bundle = folder.appendingPathComponent(path)
            try fm.createDirectory(at: bundle.appendingPathComponent("weights"), withIntermediateDirectories: true)
            try Data(repeating: 1, count: 64).write(to: bundle.appendingPathComponent("coremldata.bin"))
            try Data(repeating: 2, count: 512).write(to: bundle.appendingPathComponent("weights/weight.bin"))
        }
    }

    final class RecordingFetcher: ModelFetcher, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [ModelID] = []
        var fetched: [ModelID] { lock.withLock { storage } }
        func fetch(_ descriptor: ModelDescriptor, into folder: URL, progress: ModelProgressHandler?) async throws {
            lock.withLock { storage.append(descriptor.id) }
            try SpeakerModelCatalogTests.writeModel(descriptor, at: folder)
        }
    }

    /// Stands in for a loaded WeSpeaker.
    final class FakeWeSpeaker: SpeakerEmbedder, @unchecked Sendable {
        let name = "fake-wespeaker"
        let dimension = 2
        let identifiesSpeakers = true
        func embed(_ samples: [Float]) throws -> SpeakerEmbedding { SpeakerEmbedding(vector: [1, 0], embedder: name) }
    }

    // MARK: Descriptor

    @Test("the descriptor names FluidAudio's diarizer repo, its folder and its two bundles")
    func descriptorMatchesFluidAudio() throws {
        let d = ModelCatalog.descriptor(.speakerEmbedding)
        #expect(d.id == .speakerEmbedding)
        // The fetcher resolves the repo through FluidAudio; a typo here would be `noRemoteFiles`.
        #expect(Repo(rawValue: d.hfRepo) == .diarizer)
        #expect(d.hfSubdirectory.isEmpty)
        #expect(d.folderName == Repo.diarizer.folderName)
        #expect(ModelCatalog.fluidAudioFolderName(for: .speakerEmbedding) == d.folderName)
        #expect(Set(d.requiredPaths) == ModelNames.Diarizer.requiredModels,
                "exactly the bundles ModelHub fetches for the diarizer, and nothing it does not")
        #expect(d.requiredPaths.contains(ModelNames.Diarizer.embeddingFile))
        // Measured from the repo and from FluidAudio's own download: 5,766,532 + 7,954,144 bytes.
        #expect(d.approxBytes == 13_720_676)
        #expect(d.license == "CC-BY-4.0")
        #expect(d.role == .stack)
        // Borrowed kind (see `ModelKind`): FluidAudioFetcher in the default fetcher table.
        #expect(d.kind == .streamingEOU)
    }

    @Test("its identity round-trips and never collides with another model's")
    func identityRoundTrips() throws {
        let encoded = try JSONEncoder().encode([ModelID.speakerEmbedding])
        #expect(try JSONDecoder().decode([ModelID].self, from: encoded) == [.speakerEmbedding])
        #expect(ModelID(rawValue: "speaker-diarization-coreml") == .speakerEmbedding)
        #expect(ModelID.allCases.firstIndex(of: .speakerEmbedding) == 4, "appended, so older bit positions hold")
        let folders = ModelID.allCases.map(ModelCatalog.folderName(for:))
        #expect(Set(folders).count == folders.count)
    }

    @Test("it is a required download with Parakeet, after both speech models")
    func requiredWithTheStack() {
        #expect(ModelStack.models == [.parakeetTDTv3, .parakeetEOU160, .speakerEmbedding, .sileroVAD])  // + V5 C6
        #expect(ModelStack.approximateBytes == 483_257_242 + 224_047_838 + 13_720_676 + 1_063_425)  // FX3: real sizes
        #expect(ModelCatalog.userVisible(qwenRefinementEnabled: false).contains(.speakerEmbedding),
                "Settings › Models lists it (the speaker-embedding row)")
    }

    @Test("the install round trip: the stack fetches it, the manager finds it, the factory loads it from there")
    func installRoundTrip() async throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fetcher = RecordingFetcher()
        let manager = ModelManager(root: root,
                                   fetchers: [.finalTDT: fetcher, .streamingEOU: fetcher, .whisper: fetcher],
                                   externalCaches: [:], maintenance: .skip)
        #expect(await !manager.isPresent(.speakerEmbedding))
        try await ModelStack.install(manager: manager)
        #expect(fetcher.fetched.suffix(2) == [.speakerEmbedding, .sileroVAD], "after both speech models (V5 C6: Silero last)")
        let installed = try #require(await manager.locate(.speakerEmbedding))
        #expect(installed.standardizedFileURL == ModelCatalog.folder(for: .speakerEmbedding, in: root).standardizedFileURL)

        // The factory's first candidate is exactly where the stack put it.
        let candidates = SpeakerEmbedderFactory.modelDirectories(modelsRoot: root)
        #expect(candidates.first?.standardizedFileURL == installed.standardizedFileURL)
        #expect(SpeakerEmbedderFactory.locateModel(in: candidates)?.standardizedFileURL == installed.standardizedFileURL)
        var loadedFrom: URL?
        let chosen = SpeakerEmbedderFactory.make(candidates: candidates) { url in loadedFrom = url; return FakeWeSpeaker() }
        #expect(chosen.identifiesSpeakers)
        #expect(loadedFrom?.standardizedFileURL == installed.standardizedFileURL)
    }

    // MARK: Factory choice

    @Test("weights present → WeSpeaker, so identifiesSpeakers is true")
    func presentWeightsAreChosen() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let own = root.appendingPathComponent("own"), cache = root.appendingPathComponent("cache")
        try Self.writeModel(ModelCatalog.descriptor(.speakerEmbedding), at: own)
        try Self.writeModel(ModelCatalog.descriptor(.speakerEmbedding), at: cache)
        var loadedFrom: [URL] = []
        let chosen = SpeakerEmbedderFactory.make(candidates: [own, cache]) { loadedFrom.append($0); return FakeWeSpeaker() }
        #expect(chosen.identifiesSpeakers)
        #expect(SpeakerFilter.availability(of: chosen) == .available)
        #expect(loadedFrom == [own], "our own install is preferred over the shared cache")

        // Only the shared cache has it: that copy is used, never re-downloaded here.
        loadedFrom = []
        _ = SpeakerEmbedderFactory.make(candidates: [root.appendingPathComponent("missing"), cache]) { loadedFrom.append($0); return FakeWeSpeaker() }
        #expect(loadedFrom == [cache])
    }

    @Test("weights absent, incomplete or unloadable → MFCC, labelled \"Voice filtering unavailable\"")
    func fallbackIsMFCC() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var loads = 0
        let load: (URL) -> (any SpeakerEmbedder)? = { _ in loads += 1; return FakeWeSpeaker() }

        // Absent.
        let none = SpeakerEmbedderFactory.make(candidates: [root.appendingPathComponent("nothing")], load: load)
        #expect(none is MFCCEmbedder)
        #expect(!none.identifiesSpeakers)
        #expect(SpeakerFilter.availability(of: none).label == "Voice filtering unavailable")
        #expect(loads == 0, "CoreML is never handed a folder that is not there")

        // Incomplete: the embedding bundle never arrived.
        let partial = root.appendingPathComponent("partial")
        try Self.writeModel(ModelCatalog.descriptor(.speakerEmbedding), at: partial, skip: ["wespeaker_v2.mlmodelc"])
        #expect(SpeakerEmbedderFactory.make(candidates: [partial], load: load) is MFCCEmbedder)
        // Interrupted download: a scratch file inside a bundle.
        let torn = root.appendingPathComponent("torn")
        try Self.writeModel(ModelCatalog.descriptor(.speakerEmbedding), at: torn)
        try Data([0]).write(to: torn.appendingPathComponent("wespeaker_v2.mlmodelc/weights/weight.bin.partial"))
        #expect(SpeakerEmbedderFactory.make(candidates: [torn], load: load) is MFCCEmbedder)
        #expect(loads == 0, "half a model is never handed to CoreML")

        // Complete but CoreML refuses it.
        let refused = root.appendingPathComponent("refused")
        try Self.writeModel(ModelCatalog.descriptor(.speakerEmbedding), at: refused)
        #expect(SpeakerEmbedderFactory.make(candidates: [refused]) { _ in nil } is MFCCEmbedder)
    }

    @Test("speaker candidates prefer writable models, then bundled resources, then FluidAudio cache")
    func defaultCandidates() {
        let dirs = SpeakerEmbedderFactory.modelDirectories()
        let own = ModelCatalog.folder(for: .speakerEmbedding, in: ModelCatalog.modelsRoot())
        let bundled = Bundle.main.resourceURL.map {
            $0.appendingPathComponent("Models", isDirectory: true)
                .appendingPathComponent("speaker-diarization", isDirectory: true)
        }
        let foreign = MLModelConfigurationUtils.defaultModelsDirectory(for: .diarizer)
        #expect(dirs == [own] + [bundled].compactMap { $0 } + [foreign])
    }

    /// On a machine that has the real weights (this one has FluidAudio's copy), the production
    /// factory loads them and identification is real — fixture-verified only where they exist.
    @Test("with the real weights on disk, the production factory identifies speakers")
    func realWeightsWhenPresent() throws {
        guard FluidSpeakerEmbedder.isAvailable else {
            #expect(SpeakerEmbedderFactory.make() is MFCCEmbedder)
            return
        }
        let embedder = SpeakerEmbedderFactory.make()
        #expect(embedder is FluidSpeakerEmbedder)
        #expect(embedder.identifiesSpeakers)
        let dir = try #require(SpeakerEmbedderFactory.locateModel())
        #expect(FluidSpeakerEmbedder.load(from: dir) != nil)
    }
}
