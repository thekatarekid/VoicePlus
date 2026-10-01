import Engine
import Foundation
import Lab
import Shared
import Testing
@testable import VoicePlusApp

/// V5 G1/G2 — LANG1 languages → the ASR route, the models fetched, and the V1 eval backends.
@Suite struct LanguageASRRoutingTests {
    static func prefs(_ langs: [String]) -> LanguagePreferences { LanguagePreferences(languages: langs) }

    @Test func routePlansFollowTheChosenLanguages() {
        #expect(Self.prefs(["en"]).asrRoutePlan == .parakeetOnly)
        #expect(Self.prefs(["en", "de", "fr"]).asrRoutePlan == .parakeetOnly)
        #expect(Self.prefs(["en", "hi"]).asrRoutePlan == ASRRoutePlan(preferred: [.hinglish, .multilingual], nemotronLanguage: "hi"))
        #expect(Self.prefs(["hi", "en", "ja"]).asrRoutePlan == ASRRoutePlan(preferred: [.hinglish, .multilingual], nemotronLanguage: nil))
        #expect(Self.prefs(["ja"]).asrRoutePlan == ASRRoutePlan(preferred: [.multilingual], nemotronLanguage: "ja-JP"))
        #expect(Self.prefs(["en", "ja"]).asrRoutePlan == ASRRoutePlan(preferred: [.multilingual], nemotronLanguage: nil))
    }

    @Test func onlyTheNeededRouteModelsAreFetched() {
        #expect(Self.prefs(["en"]).routeModels.isEmpty)
        #expect(Self.prefs(["en", "hi"]).routeModels == [.qwen3AsrHinglish])
        #expect(Self.prefs(["ja", "hi"]).routeModels == [.qwen3AsrHinglish, .nemotronMultilingual])
        // Srota has no published CoreML yet: installed by its recipe, never fetched.
        #expect(LanguageASRRouting.fetchable([.qwen3AsrHinglish, .nemotronMultilingual]) == [.nemotronMultilingual])
        #expect(LanguagePreferences.ASRRoute.multilingual.modelID == .nemotronMultilingual)
    }

    @Test func routerReadsTheStoredLanguagesAndFallsBackWhenNothingIsInstalled() async throws {
        let store = InMemorySettingsStore()
        LanguagePreferences(languages: ["en", "hi"]).save(to: store)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("route-\(UUID().uuidString)")
        let routing = LanguageASRRouting(settings: { store }, root: root, residency: ModelResidency())
        #expect(routing.plan.preferred == [.hinglish, .multilingual])
        #expect(routing.hinglish() == nil && routing.multilingual(language: "hi") == nil)
        #expect(routing.autoFetch == false, "a test runner never downloads")

        final class Parakeet: FinalRecognizer, @unchecked Sendable {
            let name = "parakeet"
            func recognize(_ samples: [Float]) async throws -> [TranscriptSpan] { [] }
        }
        let provider = routing.provider(inner: StaticRecognizerProvider(final: Parakeet()))
        #expect(try await provider.resolve().final.name == "parakeet")
        #expect(provider.lastRoute == .parakeet)
    }

    @Test func installedNemotronServesTheMultilingualRoute() async throws {
        let store = InMemorySettingsStore()
        LanguagePreferences(languages: ["ja"]).save(to: store)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("route-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = ModelCatalog.folder(for: .nemotronMultilingual, in: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for p in NemotronMultilingualFiles.requiredPaths { try Data().write(to: folder.appendingPathComponent(p)) }
        let routing = LanguageASRRouting(settings: { store }, root: root, residency: ModelResidency())
        let pair = try #require(routing.multilingual(language: "ja-JP"))
        #expect(pair.final is NemotronRecognizer && pair.preview is NemotronPreviewRecognizer)
        #expect((pair.final as? NemotronRecognizer)?.language == "ja-JP")
        // Nothing is loaded until a turn runs (residency loads on first use).
    }

    @Test func evalBackendsAreRegisteredAndSayWhenAModelIsMissing() async throws {
        var registry = LabRegistry.mocks
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("eval-\(UUID().uuidString)")
        LanguageASRRouting.registerEvalBackends(&registry, root: root)
        for id in ["hinglish-srota", "hinglish-nemotron", "nemotron-multilingual"] {
            let backend = try #require(try registry.evalBackends[id]?())
            #expect(backend.modelID == id)
        }
        let wav = root.appendingPathComponent("a.wav")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try EvalAudio.writeWAV([Float](repeating: 0, count: 1_600), to: wav)
        let backend = try registry.evalBackends["hinglish-srota"]!()
        await #expect(throws: EvalError.self) {
            _ = try await backend.evaluate(EvalItem(id: "x", reference: "kal"), audioURL: wav, stage: .asr)
        }
    }

    // MARK: G1 V1 — MUCS-2021 + HiACC, gated on the owner's manifests and the converted models

    static var hinglishEvalReady: Bool {
        let paths = EvalPaths()
        let sets = ["mucs2021", "hiacc"].allSatisfy { (try? paths.loadManifest(set: $0)) != nil }
        return sets && HinglishASRFactory.make(root: ModelCatalog.modelsRoot()) != nil
    }

    @Test(.enabled(if: LanguageASRRoutingTests.hinglishEvalReady))
    func hinglishV1OnMUCSAndHiACC() async throws {
        var registry = LabRegistry.mocks
        LanguageASRRouting.registerEvalBackends(&registry)
        let eval = PublicEval()
        for set in ["mucs2021", "hiacc"] {
            let manifest = try EvalPaths().loadManifest(set: set)
            let report = try await eval.run(manifest: manifest, backend: try registry.evalBackends["hinglish-srota"]!())
            _ = try eval.write(report)
            print("G1 \(set): \(PublicEval.table(report))")
        }
    }
}
