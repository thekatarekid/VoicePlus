import Foundation
import Testing
@testable import Engine
import Shared

/// V5 G1 (Hinglish ASR) + G2 (Nemotron multilingual): recognizers over scripted sessions, the
/// residency contract, catalog entries and the LANG1 route provider. No model is loaded here.
@Suite struct LanguageRoutedASRTests {

    // MARK: Fakes

    final class ScriptedSession: NemotronStreamingSession, @unchecked Sendable {
        var tokens: [NemotronToken]
        var begun: [String?] = []
        var fed = 0
        init(tokens: [NemotronToken] = []) { self.tokens = tokens }
        func begin(language: String?) async { begun.append(language); fed = 0 }
        func feed(_ samples: [Float]) async throws { fed += samples.count }
        func partialText() async -> String { "partial \(fed)" }
        func finish() async throws -> [NemotronToken] { tokens }
    }

    final class ScriptedTranscriber: SpeechTranscribing, @unchecked Sendable {
        let maxWindowSeconds: Double
        var windows: [Int] = []
        let text: String
        init(maxWindowSeconds: Double = 30, text: String = "kal meeting hai") { self.maxWindowSeconds = maxWindowSeconds; self.text = text }
        func transcribe(_ samples: [Float]) async throws -> String { windows.append(samples.count); return text }
    }

    final class StubFinal: FinalRecognizer, @unchecked Sendable {
        let name: String
        init(_ name: String) { self.name = name }
        func recognize(_ samples: [Float]) async throws -> [TranscriptSpan] { [] }
    }

    final class StubPreview: PreviewRecognizer, @unchecked Sendable {
        let tag: String
        init(_ tag: String) { self.tag = tag }
        func feed(_ samples: [Float]) async throws -> String { tag }
        func reset() async {}
    }

    struct CountingInner: RecognizerProvider {
        let final = StubFinal("parakeet")
        let preview = StubPreview("eou")
        func resolve() async throws -> (final: FinalRecognizer, preview: PreviewRecognizer?) { (final, preview) }
        func revision() async -> Int { 6 }
    }

    static func tok(_ t: String, _ s: Double, _ e: Double, _ c: Float = 0.9) -> NemotronToken {
        NemotronToken(text: t, start: s, end: e, confidence: c)
    }

    // MARK: G2 — Nemotron

    @Test func piecesGroupIntoWordsWithTimesConfidenceAndProvenance() {
        let spans = NemotronRecognizer.spans(from: [
            Self.tok("\u{2581}gu", 0.0, 0.2, 0.81), Self.tok("ten", 0.2, 0.4, 1.0), Self.tok("\u{2581}Tag", 0.5, 0.8, 0.5),
            Self.tok(",", 0.8, 0.85, 0.9), Self.tok("<blank>", 0.9, 1.0),
        ])
        #expect(spans.map(\.text) == ["guten", "Tag,"])
        #expect(abs(spans[0].confidence - 0.9) < 0.001, "geometric mean of 0.81 and 1.0")
        #expect(spans[0].audioRange == 0.0...0.4)
        #expect(spans[1].audioRange == 0.5...0.85)
        #expect(spans.allSatisfy { $0.provenance == [.asr, NemotronRecognizer.stage] })
    }

    @Test func finalPassRunsThroughResidencyWithTheLanguagePrompt() async throws {
        let final = ScriptedSession(tokens: [Self.tok("\u{2581}hola", 0, 0.3)])
        let preview = ScriptedSession()
        let residency = ModelResidency()
        let loads = G2Counter()
        let runtime = NemotronRuntime(key: "test.nemotron", estimatedBytes: 1, residency: residency) {
            loads.bump(); return (final, preview)
        }
        let rec = NemotronRecognizer(runtime: runtime, language: "es")
        #expect(try await rec.recognize([Float](repeating: 0, count: 16_000)).map(\.text) == ["hola"])
        #expect(final.begun == ["es"] && final.fed == 16_000)
        #expect(await residency.isRegistered("test.nemotron"))
        #expect(await residency.isResident("test.nemotron"))
        _ = try await rec.recognize([0, 0])
        #expect(loads.value == 1, "one load; the second turn reuses the resident streams")
    }

    @Test func previewBeginsOnceAndAgainAfterReset() async throws {
        let session = ScriptedSession()
        let runtime = NemotronRuntime(key: "test.preview", estimatedBytes: 1, residency: ModelResidency()) { (ScriptedSession(), session) }
        let preview = NemotronPreviewRecognizer(runtime: runtime, language: nil)
        _ = try await preview.feed([0, 0, 0])
        #expect(try await preview.feed([0, 0]) == "partial 5")
        #expect(session.begun.count == 1)
        await preview.reset()
        #expect(try await preview.feed([0]) == "partial 1")
        #expect(session.begun == [nil, nil])
    }

    @Test func promptLanguagesNameWhatTheModelKnows() {
        #expect(NemotronMultilingualFiles.promptLanguage(for: "ja") == "ja-JP")
        #expect(NemotronMultilingualFiles.promptLanguage(for: "hi") == "hi")
        #expect(NemotronMultilingualFiles.promptLanguage(for: "de-DE") == "de")
        #expect(NemotronMultilingualFiles.promptLanguage(for: nil) == nil)
    }

    // MARK: Catalog

    @Test func catalogHasOneNemotronVariantAndTheConvertedSrota() {
        let n = ModelCatalog.descriptor(.nemotronMultilingual)
        #expect(n.role == .onDemand && n.kind == .whisper)
        #expect(n.hfRepo == "FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML" && n.hfSubdirectory == "multilingual/1120ms")
        #expect(n.remoteFiles.count == 22 && n.approxBytes == 664_144_423)
        #expect(n.remoteFiles.filter { $0.path.hasSuffix("weight.bin") }.allSatisfy { $0.sha256?.count == 64 })
        #expect(Set(n.requiredPaths).isSubset(of: Set(n.remoteFiles.map(\.path)).union(["encoder.mlmodelc", "decoder.mlmodelc", "joint.mlmodelc"])))

        let h = ModelCatalog.descriptor(.qwen3AsrHinglish)
        #expect(h.role == .onDemand && h.kind == .whisper)
        #expect(h.remoteFiles.isEmpty, "no CoreML Srota upstream — installed by the recipe, never fetched")
        #expect(h.requiredPaths == Qwen3WeightsLayout.requiredPaths)
        #expect(h.license == "Apache-2.0")
        #expect(ModelCatalog.fluidAudioFolderName(for: .qwen3AsrHinglish) == nil)
        #expect(!ModelCatalog.userVisible(qwenRefinementEnabled: true).contains(.nemotronMultilingual))
        #expect(Set(ModelID.allCases.map { ModelCatalog.folderName(for: $0) }).count == ModelID.allCases.count)
    }

    @Test func installCheckNeedsEveryRequiredFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nemo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(!NemotronMultilingualFiles.isInstalled(at: dir))
        for p in NemotronMultilingualFiles.requiredPaths {
            try Data().write(to: dir.appendingPathComponent(p))
        }
        #expect(NemotronMultilingualFiles.isInstalled(at: dir))
    }

    // MARK: G1 — Hinglish

    @Test func hinglishSpansSpreadTimeByCharacterShare() {
        let spans = HinglishRecognizer.spans(text: "kal  meeting", from: 1, to: 2.1)
        #expect(spans.map(\.text) == ["kal", "meeting"])
        #expect(abs(spans[0].audioRange.lowerBound - 1) < 1e-9 && abs(spans[0].audioRange.upperBound - 1.33) < 1e-9)
        #expect(abs(spans[1].audioRange.upperBound - 2.1) < 1e-9)
        #expect(spans.allSatisfy { $0.confidence == HinglishRecognizer.unscoredConfidence && !$0.isLowConfidence })
        #expect(spans.allSatisfy { $0.provenance == [.asr, HinglishRecognizer.stage] })
    }

    @Test func longUtterancesAreCutIntoModelWindowsAndTinyTailsSkipped() async throws {
        let t = ScriptedTranscriber(maxWindowSeconds: 10)
        let rec = HinglishRecognizer(transcriber: t)
        // 19.6 s: windows of 9.5 s → 9.5 + 9.5 + 0.6
        let spans = try await rec.recognize([Float](repeating: 0, count: 313_600))
        #expect(t.windows == [152_000, 152_000, 9_600])
        #expect(spans.count == 9)
        #expect(spans.last!.audioRange.upperBound <= 19.6 + 1e-9)
        let t2 = ScriptedTranscriber(maxWindowSeconds: 10)
        _ = try await HinglishRecognizer(transcriber: t2).recognize([Float](repeating: 0, count: 152_000 + 3_000))
        #expect(t2.windows == [152_000], "a 0.19 s tail is not decoded")
    }

    @Test func hinglishFillsTheCodeSwitchSlot() async throws {
        let rec = HinglishRecognizer(transcriber: ScriptedTranscriber())
        let router = CodeSwitchRouter(primary: StubFinal("parakeet"), indic: rec)
        #expect(rec.languages == ["hi", "en"] && rec.isAvailable)
        #expect(router.shouldRouteToIndic(previewText: "kal meeting hai na"))
        let merged = try await router.recognize([0], previewText: "kal kaam hai")
        #expect(merged.text.contains("meeting"))
    }

    @Test func factoryReturnsNilUntilTheRecipeInstalledTheFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(HinglishASRFactory.make(root: root, residency: ModelResidency()) == nil)
        let folder = root.appendingPathComponent(HinglishASRFiles.folderName)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for p in HinglishASRFiles.requiredPaths { try Data().write(to: folder.appendingPathComponent(p)) }
        let made = try #require(HinglishASRFactory.make(root: root, residency: ModelResidency()))
        #expect(made is HinglishRecognizer && made.name == HinglishASRCandidate.srota.rawValue)
        #expect(HinglishASRFactory.make(candidate: .nemotronHinglish, root: root, residency: ModelResidency()) == nil)
        #expect(HinglishASRCandidate.shipped == .srota)
    }

    // MARK: Routing

    @Test func noPlanIsTheInnerProviderAndTheSameRevision() async throws {
        let p = LanguageRoutedRecognizerProvider(inner: CountingInner(), plan: { .parakeetOnly },
                                                 hinglish: { StubFinal("h") }, multilingual: { _ in (StubFinal("n"), nil) })
        #expect(try await p.resolve().final.name == "parakeet")
        #expect(await p.revision() == 6)
        #expect(p.lastRoute == .parakeet)
    }

    @Test func hindiPrefersHinglishWithNemotronPreview() async throws {
        let langs = G2Box<[String?]>([])
        let p = LanguageRoutedRecognizerProvider(
            inner: CountingInner(), plan: { ASRRoutePlan(preferred: [.hinglish, .multilingual], nemotronLanguage: "hi") },
            hinglish: { StubFinal("srota") },
            multilingual: { l in langs.value.append(l); return (StubFinal("nemotron"), StubPreview("nemo-preview")) })
        let r = try await p.resolve()
        #expect(r.final.name == "srota")
        #expect(try await r.preview?.feed([]) == "nemo-preview")
        #expect(langs.value == ["hi"])
        #expect(p.lastRoute == .hinglish)
        #expect(await p.revision() != 6, "a language plan changes the revision so the engine re-resolves")
    }

    @Test func missingModelsFallThroughToTheNextRoute() async throws {
        let plan = ASRRoutePlan(preferred: [.hinglish, .multilingual], nemotronLanguage: "hi")
        let nemoOnly = LanguageRoutedRecognizerProvider(inner: CountingInner(), plan: { plan }, hinglish: { nil },
                                                        multilingual: { _ in (StubFinal("nemotron"), StubPreview("np")) })
        #expect(try await nemoOnly.resolve().final.name == "nemotron")
        #expect(nemoOnly.lastRoute == .multilingual)

        let hinglishNoNemo = LanguageRoutedRecognizerProvider(inner: CountingInner(), plan: { plan }, hinglish: { StubFinal("srota") },
                                                              multilingual: { _ in nil })
        let r = try await hinglishNoNemo.resolve()
        #expect(r.final.name == "srota")
        #expect(try await r.preview?.feed([]) == "eou", "Parakeet's preview stands in")

        let nothing = LanguageRoutedRecognizerProvider(inner: CountingInner(), plan: { plan }, hinglish: { nil }, multilingual: { _ in nil })
        #expect(try await nothing.resolve().final.name == "parakeet")
        #expect(nothing.lastRoute == .parakeet)
    }

    @Test func planSignatureIsStable() {
        let a = ASRRoutePlan(preferred: [.multilingual], nemotronLanguage: "ja-JP")
        #expect(a.signature == ASRRoutePlan(preferred: [.parakeet, .multilingual], nemotronLanguage: "ja-JP").signature)
        #expect(a.signature != ASRRoutePlan(preferred: [.multilingual], nemotronLanguage: nil).signature)
    }
}

final class G2Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

final class G2Box<T>: @unchecked Sendable {
    var value: T
    init(_ v: T) { value = v }
}
