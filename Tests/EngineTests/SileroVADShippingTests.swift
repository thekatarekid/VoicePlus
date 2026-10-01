import FluidAudio
import Foundation
import Testing
@testable import Engine
@testable import Shared

/// V5 C6 (+K17) — Silero VAD ships: catalog + stack entry, a checked-in copy every bundle carries,
/// resolution through `ModelManager.locate`, and Silero available in the test process.
@Suite("V5 C6 — Silero VAD ships")
struct SileroVADShippingTests {
    private static var checkedIn: URL { get throws { try #require(SileroModelLocator.sourceCheckoutFolder()) } }

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("c6-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: catalog

    @Test func catalogEntryMatchesUpstream() throws {
        let d = ModelCatalog.descriptor(.sileroVAD)
        #expect(d.hfRepo == "FluidInference/silero-vad-coreml")
        #expect(d.hfRepo == Repo.vad.rawValue, "FluidAudioFetcher resolves hfRepo to Repo.vad")
        #expect(d.folderName == Repo.vad.folderName)
        #expect(ModelCatalog.fluidAudioFolderName(for: .sileroVAD) == d.folderName)
        #expect(d.requiredPaths == [ModelNames.VAD.sileroVadFile], "the file the pinned FluidAudio asks for")
        #expect(d.role == .stack)
        #expect(d.license == "MIT")
        #expect(d.approxBytes < 3_000_000)
        #expect(ModelStack.models.contains(.sileroVAD))
        #expect(ModelStack.models.last == .sileroVAD, "small and last: never holds up a speech model")
        #expect(ModelID.allCases.firstIndex(of: .sileroVAD)! > ModelID.allCases.firstIndex(of: .speakerEmbedding)!,
                "appended, so older revision bit positions hold")
    }

    @Test func checkedInCopyIsCompleteAndVerified() throws {
        let folder = try Self.checkedIn
        let d = ModelCatalog.descriptor(.sileroVAD)
        #expect(ModelIntegrity.problems(for: d, at: folder).isEmpty)
        let manifest = try #require(ModelManifest.load(from: folder))
        #expect(manifest.modelID == .sileroVAD)
        #expect(manifest.verify(in: folder).isEmpty, "every byte matches its manifest")
        #expect(manifest.totalBytes == d.approxBytes, "catalog size is the real size")
    }

    // MARK: resolution

    @Test func locatorPrefersCurrentFileAndAcceptsLegacyExport() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let legacy = dir.appendingPathComponent("silero-vad-unified-256ms-v6.0.0.mlmodelc")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let locator = SileroModelLocator(folders: [dir])
        #expect(locator.resolve() == nil, "a .mlmodelc without coremldata.bin is not loadable")
        try Data([0]).write(to: legacy.appendingPathComponent("coremldata.bin"))
        #expect(locator.resolve()?.lastPathComponent == legacy.lastPathComponent)
        let current = dir.appendingPathComponent(ModelNames.VAD.sileroVadFile)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try Data([0]).write(to: current.appendingPathComponent("coremldata.bin"))
        #expect(locator.resolve()?.lastPathComponent == ModelNames.VAD.sileroVadFile)
    }

    @Test func defaultSearchOrderIsOursBundleFluidAudioThenCheckout() throws {
        let folders = SileroModelLocator.defaultFolders()
        #expect(folders.first == ModelCatalog.folder(for: .sileroVAD, in: ModelCatalog.modelsRoot()))
        let checkedIn = try Self.checkedIn
        #expect(folders.last == checkedIn, "source checkout is the last resort")
        #expect(folders.contains(MLModelConfigurationUtils.defaultModelsDirectory(for: .vad)))
    }

    /// K17 — Silero is available in the test process, with no download.
    @Test func loadIfAvailableIsNonNilInTests() async throws {
        let silero = try #require(await SileroVAD.loadIfAvailable())
        #expect(silero.name == "silero")
        #expect(SileroVAD.isModelDownloaded)
    }

    /// `VADFactory.make()` returns Silero from the bundled model, found through `ModelManager.locate`
    /// (the bundle is an external cache of the manager, as `BundledModelResources` makes it).
    @Test func factoryReturnsSileroThroughModelManager() async throws {
        let root = tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let checkedIn = try Self.checkedIn
        let manager = ModelManager(root: root, fetchers: [:], externalCaches: [.sileroVAD: [checkedIn]],
                                   maintenance: .skip)
        #expect(await manager.locate(.sileroVAD) == checkedIn)
        let vad = await VADFactory.make(manager: manager, locator: SileroModelLocator(folders: []))
        #expect(vad.name == "silero")
    }

    @Test func factoryFallsBackToEnergyWhenNothingResolves() async throws {
        let root = tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let manager = ModelManager(root: root, fetchers: [:], externalCaches: [:], maintenance: .skip)
        #expect(await VADFactory.make(manager: manager, locator: SileroModelLocator(folders: [])).name == "energy")
        #expect(await VADFactory.make(preferSilero: false).name == "energy")
    }

    /// §10 — the load goes through `ModelResidency` (one budget), and leaves it when the VAD goes.
    @Test func loadsThroughModelResidency() async throws {
        let residency = ModelResidency(budgetBytes: 1 << 30)
        var vad: SileroVAD? = try #require(await SileroVAD.loadIfAvailable(residency: residency))
        let keys = await residency.snapshot().residentKeys
        #expect(keys.count == 1 && keys[0].hasPrefix("vad.silero#"))
        #expect(vad?.name == "silero")
        vad = nil
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await residency.snapshot().entries.isEmpty, "unregistered with the VAD")
    }

    @Test func aFailingLoaderFallsBackInsteadOfThrowing() async throws {
        struct Boom: Error {}
        let checkedIn = try Self.checkedIn
        let vad = await SileroVAD.loadIfAvailable(locator: SileroModelLocator(folders: [checkedIn]),
                                                  loader: { _, _ in throw Boom() })
        #expect(vad == nil)
    }

    // MARK: mic gate on both VADs

    private func speechStarts(_ vad: any VADProtocol, samples: [Float]) async throws -> Int {
        let source = FixtureCaptureSource(wav: WAVFile(sampleRate: 16_000, samples: []))
        var options = AudioPipeline.Options()
        options.noAudioTimeout = 0
        let pipeline = AudioPipeline(source: source, vad: vad, options: options)
        let stream = pipeline.events()
        let collector = Task { () -> Int in
            var n = 0
            for await e in stream {
                if case .vad(.speechStart) = e { n += 1 }
                if case .stopped = e { break }
            }
            return n
        }
        try await pipeline.start()
        var i = 0
        while i < samples.count {
            let end = min(i + 800, samples.count)
            source.push(Array(samples[i..<end])); i = end
            await pipeline.drain()
        }
        await pipeline.stop()
        return await collector.value
    }

    @Test("mic gate opens on speech and stays shut on silence", arguments: ["silero", "energy"])
    func micGate(kind: String) async throws {
        func make() async throws -> any VADProtocol {
            kind == "silero" ? try #require(await SileroVAD.loadIfAvailable()) : EnergyVAD()
        }
        let speechURL = try #require(AudioFixtures.list("vad").first)
        let speech = try WAVFile.read(url: speechURL).samples
        #expect(try await speechStarts(try await make(), samples: speech) >= 1, "\(kind): speech opens the gate")
        for url in AudioFixtures.list("silence") {
            let quiet = try WAVFile.read(url: url).samples
            #expect(try await speechStarts(try await make(), samples: quiet) == 0, "\(kind): \(url.lastPathComponent)")
        }
    }
}
