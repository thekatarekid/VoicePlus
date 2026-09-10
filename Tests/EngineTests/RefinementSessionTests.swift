import Foundation
import Testing
import Shared
@testable import Engine

/// R5.1 — the `RefinementSession` contract, exercised with no weights at all.
///
/// Everything the wave-2 `RefineStage` depends on is here: the deadline is hard, a cancelled
/// caller stops the pass, and a refined span keeps `audioRange` and gains provenance instead of
/// silently becoming a new span. `Qwen3RefinementWERTests` is the other half — the real model.
@Suite("Refinement session (mock)")
struct RefinementSessionTests {
    static func samples(seconds: Double) -> [Float] {
        [Float](repeating: 0.01, count: Int(Double(Refinement.sampleRate) * seconds))
    }

    // MARK: Span shape

    @Test func spanCoversTheAudioAndCarriesProvenance() async throws {
        let session = MockRefinementSession()
        let spans = try await session.refine(
            samples: Self.samples(seconds: 1.5), context: "", deadline: .seconds(5)
        )
        let span = try #require(spans.first)
        #expect(spans.count == 1)
        #expect(span.audioRange.lowerBound == 0)
        #expect(abs(span.audioRange.upperBound - 1.5) < 1e-9)
        #expect(span.provenance == [.refineQwen3])
        #expect(span.confidence == Refinement.confidenceNotReported)
        #expect(!span.needsRepair)
    }

    @Test func mockOutputIsDeterministic() async throws {
        let session = MockRefinementSession()
        let audio = Self.samples(seconds: 2)
        let a = try await session.refine(samples: audio, context: "Priya standup", deadline: .seconds(5))
        let b = try await session.refine(samples: audio, context: "Priya standup", deadline: .seconds(5))
        #expect(a == b)
        #expect(a.first?.text == "mock refinement of 2.00s with 2 context words")
    }

    /// The shape `RefineStage` uses: replace text in place, keep everything else.
    @Test func refiningAnExistingSpanPreservesAudioRangeAndAppendsProvenance() async throws {
        let session = MockRefinementSession(text: "the corrected text")
        let pass1 = TranscriptSpan(
            text: "the currected text",
            confidence: 0.42,
            audioRange: 4.0...7.5,
            alternates: [Alternate(text: "the corrected text", score: 0.3, source: .beam)],
            provenance: [.asr],
            stability: .final
        )
        let refined = try await session.refine(
            span: pass1, samples: Self.samples(seconds: 3.5), context: "", deadline: .seconds(5)
        )
        #expect(refined.text == "the corrected text")
        #expect(refined.audioRange == 4.0...7.5)          // not 0…3.5
        #expect(refined.confidence == 0.42)               // pass-1 confidence, not invented
        #expect(refined.provenance == [.asr, .refineQwen3])
        #expect(refined.alternates == pass1.alternates)
        #expect(refined.stability == pass1.stability)
    }

    /// A pass that comes back with nothing must not blank the span.
    @Test func emptyRefinementLeavesPassOneTextAlone() async throws {
        let session = MockRefinementSession(text: "   ")
        let pass1 = TranscriptSpan(text: "keep me", confidence: 0.8, audioRange: 0...1, provenance: [.asr])
        let refined = try await session.refine(
            span: pass1, samples: Self.samples(seconds: 1), context: "", deadline: .seconds(5)
        )
        #expect(refined.text == "keep me")
        #expect(refined.provenance == [.asr, .refineQwen3])
    }

    // MARK: Deadline

    @Test func deadlineIsHardAndReturnsPromptly() async throws {
        let session = MockRefinementSession(work: .seconds(30))
        let start = ContinuousClock.now
        await #expect(throws: RefinementError.deadlineExceeded(.milliseconds(80))) {
            _ = try await session.refine(
                samples: Self.samples(seconds: 1), context: "", deadline: .milliseconds(80)
            )
        }
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .seconds(5), "the deadline did not interrupt the pass; waited \(elapsed)")
    }

    @Test func workInsideTheDeadlineSucceeds() async throws {
        let session = MockRefinementSession(work: .milliseconds(20))
        let spans = try await session.refine(
            samples: Self.samples(seconds: 1), context: "", deadline: .seconds(5)
        )
        #expect(spans.count == 1)
    }

    @Test func nonPositiveDeadlineFailsWithoutRunning() async throws {
        let session = MockRefinementSession(work: .seconds(30))
        await #expect(throws: RefinementError.deadlineExceeded(.zero)) {
            _ = try await session.refine(samples: Self.samples(seconds: 1), context: "", deadline: .zero)
        }
    }

    // MARK: Cancellation

    @Test func cancellingTheCallerCancelsThePass() async throws {
        let session = MockRefinementSession(work: .seconds(30))
        let audio = Self.samples(seconds: 1)
        let task = Task {
            try await session.refine(samples: audio, context: "", deadline: .seconds(60))
        }
        // Give the child task a moment to reach the sleep, then cancel.
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let start = ContinuousClock.now
        do {
            _ = try await task.value
            Issue.record("a cancelled refinement returned a result")
        } catch is CancellationError {
            // expected
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    // MARK: Error paths

    @Test func emptyAudioIsRejected() async throws {
        let session = MockRefinementSession()
        await #expect(throws: RefinementError.emptyAudio) {
            _ = try await session.refine(samples: [], context: "", deadline: .seconds(5))
        }
    }

    @Test func backendFailurePropagates() async throws {
        let session = MockRefinementSession(failure: .backendFailure("decoder said no"))
        await #expect(throws: RefinementError.backendFailure("decoder said no")) {
            _ = try await session.refine(samples: Self.samples(seconds: 1), context: "", deadline: .seconds(5))
        }
    }

    @Test func errorsReadLikeSentences() {
        #expect(RefinementError.deadlineExceeded(.seconds(1)).errorDescription?.isEmpty == false)
        #expect(RefinementError.unavailableOnThisSystem("it needs macOS 15 or later").errorDescription
            == "Refinement isn\u{2019}t available on this Mac: it needs macOS 15 or later")
        #expect(RefinementError.weightsIncomplete(path: "/tmp/x", problems: ["a", "b"]).errorDescription?
            .contains("2 files") == true)
    }
}

/// Collects progress callbacks from a `@Sendable` closure without tripping concurrency checking.
final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []
    func append(_ value: Double) { lock.lock(); storage.append(value); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return storage }
}

/// Weights resolution: on-disk first, download only when asked, integrity before use.
@Suite("Qwen3 weights store")
struct Qwen3WeightsStoreTests {
    /// A directory shaped like the real weights folder. `bytes == nil` writes the recorded size
    /// as a sparse file (cheap: no 1.2 GB of zeros), otherwise the size given.
    static func makeWeightsTree(
        in parent: URL, exactSizes: Bool = false, omitting: Set<String> = [], scratch: Bool = false
    ) throws -> URL {
        let folder = parent.appendingPathComponent(Qwen3WeightsLayout.folderName, isDirectory: true)
        for file in Qwen3WeightsLayout.files where !omitting.contains(file.path) {
            let url = folder.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: Data([0x01]))
            if exactSizes {
                let handle = try FileHandle(forWritingTo: url)
                try handle.truncate(atOffset: UInt64(file.bytes))   // sparse: no real bytes written
                try handle.close()
            }
        }
        if scratch {
            let url = folder.appendingPathComponent("qwen3_asr_embeddings.bin.partial")
            FileManager.default.createFile(atPath: url.path, contents: Data([0x02]))
        }
        return folder
    }

    static func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("r51-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func defaultSearchPathsPreferVoicePlusThenFluidAudio() {
        let paths = Qwen3WeightsStore.defaultSearchPaths()
        #expect(paths.count == 2)
        #expect(paths[0].path.contains("/VoicePlus/Models/qwen3-asr-0.6b/int8"))
        #expect(paths[1].path.contains("/FluidAudio/Models/qwen3-asr-0.6b/int8"))
    }

    @Test func completeTreeIsFoundAndIncompleteOneIsNot() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try Self.makeWeightsTree(in: root)
        let store = Qwen3WeightsStore(searchPaths: [folder])
        #expect(store.problems(at: folder).isEmpty)
        #expect(store.locate() == folder)

        let missing = try Self.makeWeightsTree(in: try Self.tempRoot(), omitting: ["vocab.json"])
        let missingStore = Qwen3WeightsStore(searchPaths: [missing])
        #expect(missingStore.problems(at: missing) == ["vocab.json is missing"])
        #expect(missingStore.locate() == nil)
    }

    /// A `.mlmodelc` directory exists from the first byte a download writes, so leftover scratch
    /// is the only evidence that a folder is mid-download. `ModelIntegrity` learned this the hard
    /// way (the 1.7.9 `weight.bin.partial` report); this store must not un-learn it.
    @Test func scratchFilesMarkTheFolderUnfinished() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try Self.makeWeightsTree(in: root, scratch: true)
        let store = Qwen3WeightsStore(searchPaths: [folder])
        #expect(store.problems(at: folder) == ["qwen3_asr_embeddings.bin.partial is an unfinished download"])
        #expect(store.locate() == nil)
    }

    @Test func verifyComparesRecordedByteCounts() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let truncated = try Self.makeWeightsTree(in: root)
        let store = Qwen3WeightsStore(searchPaths: [truncated])
        #expect(store.verify(at: truncated).count == Qwen3WeightsLayout.files.count)

        let exact = try Self.makeWeightsTree(in: try Self.tempRoot(), exactSizes: true)
        defer { try? FileManager.default.removeItem(at: exact.deletingLastPathComponent().deletingLastPathComponent()) }
        #expect(Qwen3WeightsStore(searchPaths: [exact]).verify(at: exact).isEmpty)
    }

    @Test func recordedLayoutMatchesThePublishedSize() {
        // 1.2 GB, the figure V3 §5.4 quotes. If the layout table is edited, this is the guard.
        #expect(Qwen3WeightsLayout.approxBytes > 1_200_000_000)
        #expect(Qwen3WeightsLayout.approxBytes < 1_400_000_000)
        #expect(Qwen3WeightsCatalogEntry.remoteFiles.count == Qwen3WeightsLayout.files.count)
        #expect(Qwen3WeightsCatalogEntry.hfRepo == "FluidInference/qwen3-asr-0.6b-coreml")
    }

    @Test func resolveNeverDownloadsUnlessAsked() async throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = root.appendingPathComponent("nothing-here", isDirectory: true)
        let provisioner = ClosureQwen3WeightsProvisioner { _ in
            Issue.record("resolve(downloadIfMissing: false) hit the network path")
            throw RefinementError.emptyAudio
        }
        let store = Qwen3WeightsStore(searchPaths: [empty], provisioner: provisioner)
        await #expect(throws: RefinementError.weightsMissing(searched: [empty.path])) {
            _ = try await store.resolve()
        }
    }

    @Test func provisionedFolderIsIntegrityCheckedBeforeUse() async throws {
        let good = try Self.makeWeightsTree(in: try Self.tempRoot())
        let bad = try Self.makeWeightsTree(in: try Self.tempRoot(), omitting: ["vocab.json"])
        defer {
            try? FileManager.default.removeItem(at: good)
            try? FileManager.default.removeItem(at: bad)
        }
        let missing = try Self.tempRoot().appendingPathComponent("absent", isDirectory: true)

        let progressSeen = ProgressBox()
        let okStore = Qwen3WeightsStore(searchPaths: [missing], provisioner: ClosureQwen3WeightsProvisioner { report in
            report(0.5); report(1.0)
            return good
        })
        let resolved = try await okStore.resolve(downloadIfMissing: true) { progressSeen.append($0) }
        #expect(resolved == good)
        #expect(progressSeen.values == [0.5, 1.0])

        let badStore = Qwen3WeightsStore(searchPaths: [missing], provisioner: ClosureQwen3WeightsProvisioner { _ in bad })
        await #expect(throws: RefinementError.weightsIncomplete(path: bad.path, problems: ["vocab.json is missing"])) {
            _ = try await badStore.resolve(downloadIfMissing: true)
        }
    }

    @Test func defaultProvisionerRefusesInsteadOfDownloading() async throws {
        await #expect(throws: RefinementError.self) {
            _ = try await UnavailableQwen3WeightsProvisioner().provisionQwen3Weights(progress: nil)
        }
    }
}

/// The macOS-15 gate and the context tokenizer.
@Suite("Qwen3 refinement availability")
struct Qwen3RefinementAvailabilityTests {
    @Test func availabilityAndFactoryAgree() throws {
        if RefinementAvailability.isAvailable {
            #expect(RefinementAvailability.unavailableReason == nil)
            // Construction alone must not touch weights or the network.
            _ = try RefinementAvailability.makeQwen3Session()
        } else {
            let reason = try #require(RefinementAvailability.unavailableReason)
            #expect(!reason.isEmpty)
            #expect(throws: RefinementError.unavailableOnThisSystem(reason)) {
                _ = try RefinementAvailability.makeQwen3Session()
            }
        }
    }

    @Test func languageHintResolves() {
        guard #available(macOS 15, *) else {
            print("SKIPPED languageHintResolves: Qwen3AsrConfig is macOS 15+.")
            return
        }
        #expect(Qwen3AsrLanguageHint.automatic.resolved == nil)
        #expect(Qwen3AsrLanguageHint.english.resolved == .english)
        #expect(Qwen3AsrLanguageHint.named("German").resolved == .german)
        #expect(Qwen3AsrLanguageHint.named("klingon").resolved == nil)
    }

    /// Greedy longest match over the byte-escaped vocabulary. "Ġ" (U+0120) is how the vocabulary
    /// spells a leading space — the same escape the port's decoder undoes.
    @Test func contextTokenizerEncodesAgainstTheVocabulary() {
        guard #available(macOS 15, *) else {
            print("SKIPPED contextTokenizerEncodesAgainstTheVocabulary: macOS 15+ only.")
            return
        }
        let vocab: [Int: String] = [1: "hello", 2: "\u{0120}world", 3: "\u{0120}wor", 4: "ld"]
        let tokenizer = Qwen3ContextTokenizer(vocabulary: vocab)
        #expect(tokenizer.encode("hello world", limit: 16) == [1, 2])       // longest match wins
        #expect(tokenizer.encode("hello world", limit: 1) == [1])           // budget respected
        #expect(tokenizer.encode("", limit: 16) == [])
        #expect(tokenizer.encode("   ", limit: 16) == [])
        #expect(tokenizer.encode("hello world", limit: 0) == [])
        // Nothing in the vocabulary for these bytes: dropped, never a stall.
        #expect(tokenizer.encode("zzz", limit: 16) == [])
    }

    /// The output language is decided in the *assistant* turn, not the system message: the model
    /// writes `language <Name>` there before it transcribes, and whatever it names is the script it
    /// answers in. Prefilling that header is the only lever (`Backend.transcribe` records the
    /// measurement). Wrong header text = a transcription in the wrong language, which no
    /// weights-free test would otherwise catch.
    @Test func assistantHeaderNamesTheOutputLanguage() {
        guard #available(macOS 15, *) else {
            print("SKIPPED assistantHeaderNamesTheOutputLanguage: macOS 15+ only.")
            return
        }
        #expect(Qwen3RefinementPrompt.assistantHeader(language: .english) == "language English")
        #expect(Qwen3RefinementPrompt.assistantHeader(language: .german) == "language German")
        // Automatic means "no header": the model detects the language, which is the port's default.
        #expect(Qwen3RefinementPrompt.assistantHeader(language: nil) == nil)
    }

    /// The header is encoded against the vocabulary and terminated by `<|asr_text|>`. The ids below
    /// are the ones the real `vocab.json` gives (`language` = 11528, `ĠEnglish` = 6364); the mock
    /// vocabulary here only has to prove the shape.
    @Test func assistantHeaderTokensEndWithTheAsrTextToken() {
        guard #available(macOS 15, *) else {
            print("SKIPPED assistantHeaderTokensEndWithTheAsrTextToken: macOS 15+ only.")
            return
        }
        let asrText = Int32(Qwen3AsrConfig.asrTextTokenId)
        let tokenizer = Qwen3ContextTokenizer(vocabulary: [11_528: "language", 6_364: "\u{0120}English"])
        #expect(Qwen3RefinementPrompt.assistantHeaderTokens(language: .english, tokenizer: tokenizer)
            == [11_528, 6_364, asrText])
        // No language, no tokenizer, or nothing encodable: no forced header at all, never a lone
        // terminator (which would be a header claiming an empty language).
        #expect(Qwen3RefinementPrompt.assistantHeaderTokens(language: nil, tokenizer: tokenizer) == [])
        #expect(Qwen3RefinementPrompt.assistantHeaderTokens(language: .english, tokenizer: nil) == [])
        let empty = Qwen3ContextTokenizer(vocabulary: [:])
        #expect(Qwen3RefinementPrompt.assistantHeaderTokens(language: .english, tokenizer: empty) == [])
    }

    @Test func contextBudgetShrinksAsAudioGrows() {
        guard #available(macOS 15, *) else {
            print("SKIPPED contextBudgetShrinksAsAudioGrows: macOS 15+ only.")
            return
        }
        // 13 audio tokens per second of audio (100 mel frames per window, 8x conv downsample).
        #expect(Qwen3RefinementBudget.audioTokenCount(sampleCount: 16_000) == 13)
        #expect(Qwen3RefinementBudget.audioTokenCount(sampleCount: 0) == 0)
        let short = Qwen3RefinementBudget.contextTokenBudget(sampleCount: 16_000)
        let long = Qwen3RefinementBudget.contextTokenBudget(sampleCount: 16_000 * 25)
        #expect(short > long)
        #expect(long >= 0)
        // The KV cache is fixed: prompt + reserved output must always fit.
        #expect(Qwen3RefinementBudget.contextTokenBudget(sampleCount: 16_000 * 30) >= 0)
    }
}
