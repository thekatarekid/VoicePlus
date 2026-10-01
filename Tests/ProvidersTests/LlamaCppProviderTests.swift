import Foundation
import Testing
import Shared
@testable import Providers

// V5 D2 — the llama.cpp provider against a scripted engine (no GGUF is downloaded in tests): it loads
// only through ModelResidency, enforces the deadline, routes as stage `cleanup`, and the catalog /
// downloader verify what they fetch. The real engine is exercised only by the opt-in smoke test
// (`VOICEPLUS_LLAMA_GGUF=/path/to/model.gguf`).

final class ScriptedEngine: LocalLLMEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var _loads = 0, _unloads = 0
    private var _calls: [(system: String, user: String, maxTokens: Int)] = []
    var delay: UInt64 = 0
    var reply: (String) -> String = { $0 }
    var loads: Int { lock.withLock { _loads } }
    var unloads: Int { lock.withLock { _unloads } }
    var calls: [(system: String, user: String, maxTokens: Int)] { lock.withLock { _calls } }

    func load(modelPath: URL) async throws { lock.withLock { _loads += 1 } }
    func unload() async { lock.withLock { _unloads += 1 } }
    func generate(system: String, user: String, maxTokens: Int, deadline: Date) async throws -> String {
        lock.withLock { _calls.append((system, user, maxTokens)) }
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        if Date() > deadline { throw ProviderError.timeout }
        return reply(user)
    }
}

private func provider(_ engine: ScriptedEngine, residency: ModelResidency, deadline: TimeInterval = 0.5,
                      installed: Bool = true) -> LlamaCppProvider {
    LlamaCppProvider(config: LlamaCppConfig(modelPath: URL(fileURLWithPath: "/tmp/none.gguf"), residencyKey: "cleanup.llm",
                                            estimatedBytes: 700_000_000, deadline: deadline),
                     residency: residency, engine: engine, fileExists: { _ in installed })
}

@Suite struct LlamaCppProviderTests {
    @Test func identityIsLocalPipelineOnly() async {
        let p = provider(ScriptedEngine(), residency: ModelResidency(budgetBytes: 4 << 30))
        #expect(p.id == "local.llamacpp")
        #expect(p.privacyClass == .onDevice && p.costClass == .free && p.capabilities == [.pipeline])
        #expect(await p.isAvailable() == LlamaCppEngine.runtimeAvailable)
        #expect(LlamaCppEngine.runtimeAvailable)   // the XCFramework is linked
    }

    @Test func notInstalledIsUnavailableAndNeverLoads() async {
        let engine = ScriptedEngine()
        let residency = ModelResidency(budgetBytes: 4 << 30)
        let p = provider(engine, residency: residency, installed: false)
        #expect(await p.isAvailable() == false)
        await #expect(throws: ProviderError.self) { _ = try await p.generate(prompt: "x", system: "s", stage: "cleanup") }
        #expect(engine.loads == 0)
        #expect(await residency.isRegistered("cleanup.llm") == false)
    }

    @Test func loadsThroughResidencyOnceAndUnloadsWhenEvicted() async throws {
        let engine = ScriptedEngine()
        let residency = ModelResidency(budgetBytes: 4 << 30)
        let p = provider(engine, residency: residency)
        _ = try await p.generate(prompt: "a", system: "s", stage: "cleanup")
        _ = try await p.generate(prompt: "b", system: "s", stage: "cleanup")
        #expect(engine.loads == 1)
        #expect(await residency.isResident("cleanup.llm"))
        let snap = await residency.snapshot()
        #expect(snap.entries.first { $0.key == "cleanup.llm" }?.tier == .onDemand)
        await residency.unload("cleanup.llm")
        #expect(engine.unloads == 1)
    }

    @Test func registersForPrewarmWithoutLoading() async {
        let engine = ScriptedEngine()
        let residency = ModelResidency(budgetBytes: 4 << 30)
        await provider(engine, residency: residency).registerWithResidency()
        #expect(await residency.isRegistered("cleanup.llm"))
        #expect(engine.loads == 0)
    }

    @Test func deadlineBecomesTimeout() async {
        let engine = ScriptedEngine(); engine.delay = 300_000_000
        let p = provider(engine, residency: ModelResidency(budgetBytes: 4 << 30), deadline: 0.05)
        await #expect(throws: ProviderError.timeout) { _ = try await p.generate(prompt: "a", system: "s", stage: "cleanup") }
    }

    @Test func promptOverridesReachTheEngineAndReasoningIsStripped() async throws {
        let engine = ScriptedEngine(); engine.reply = { _ in "<think>hmm</think>\nMeet at 5." }
        let p = provider(engine, residency: ModelResidency(budgetBytes: 4 << 30))
        var ctx = StageContext()
        ctx.extra[PromptBuilder.systemOverrideKey] = "SYSTEM"
        ctx.extra[PromptBuilder.userOverrideKey] = "<transcript>\nmeet at five\n</transcript>"
        let span = TranscriptSpan(text: "meet at five", confidence: 1, audioRange: 0...0, provenance: [.asr])
        let c = try await p.complete(stage: "cleanup", spans: [span], context: ctx)
        #expect(c.spans.map(\.text).joined(separator: " ") == "Meet at 5.")
        #expect(engine.calls.first?.system == "SYSTEM")
        #expect(engine.calls.first?.user == "<transcript>\nmeet at five\n</transcript>")
        #expect(c.bytesOut == 0 && c.bytesIn == 0)
        // Without overrides, the generic PromptBuilder is used (unchanged behaviour).
        _ = try await p.complete(stage: "cleanup", spans: [span], context: StageContext())
        #expect(engine.calls.last?.system.hasPrefix("You are a dictation post-processor") == true)
    }

    @Test func tokenCapScalesWithInput() {
        #expect(LlamaCppProvider.derivedMaxTokens(forCharacters: 0) == 64)
        #expect(LlamaCppProvider.derivedMaxTokens(forCharacters: 3000) == 2032)
    }

    @Test func routesAsCleanupStageLocalOnlyNoNetworkLog() async throws {
        let engine = ScriptedEngine(); engine.reply = { _ in "Cleaned." }
        let logger = InMemoryNetworkLogger()
        let table = RoutingTable(providers: [provider(engine, residency: ModelResidency(budgetBytes: 4 << 30))], logger: logger)
        table.setChoice(.localOnly, for: "cleanup")
        let span = TranscriptSpan(text: "cleaned", confidence: 1, audioRange: 0...0, provenance: [.asr])
        let out = try await table.complete(stage: "cleanup", spans: [span], context: StageContext())
        #expect(out.provider == LlamaCppProvider.providerID)
        #expect(logger.records.isEmpty)
    }
}

@Suite struct LocalLLMCatalogTests {
    @Test func cleanupPickIsSmallOnDemandAndPinned() {
        let m = LocalLLMCatalog.cleanupDefault
        #expect(m.fileName.hasSuffix(".gguf") && m.sha256.count == 64)
        #expect(m.bytes < 600_000_000)
        #expect(m.promptStyle == "speakoFlow")
        #expect(m.downloadURL.absoluteString == "https://huggingface.co/SpeakoFlow/speakoflow-mini/resolve/main/SpeakoFlow-Mini-0.8B-Q4_K_M.gguf")
        #expect(LocalLLMCatalog.all.allSatisfy { $0.license.hasPrefix("Apache-2.0") })
    }

    @Test func downloaderVerifiesChecksumBeforeInstalling() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vp-llm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("src.bin")
        try Data("tiny gguf stand-in".utf8).write(to: source)
        let sha = try LocalLLMDownloader.sha256(of: source)
        let root = dir.appendingPathComponent("models")
        let d = LocalLLMDownloader(root: root)

        var bad = LocalLLMCatalog.s1Mini; bad.fileName = "bad.gguf"
        await #expect(throws: LocalLLMDownloadError.self) { try await d.download(bad, from: source) }
        #expect(!d.isInstalled(bad))

        var good = LocalLLMCatalog.s1Mini; good.fileName = "good.gguf"; good.sha256 = sha
        let url = try await d.download(good, from: source)
        #expect(d.isInstalled(good) && url.lastPathComponent == "good.gguf")
    }
}

/// Opt-in: a real GGUF through the real engine (never downloaded by the suite).
@Suite struct LlamaCppEngineSmokeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOICEPLUS_LLAMA_GGUF"] != nil))
    func realModelGenerates() async throws {
        let path = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VOICEPLUS_LLAMA_GGUF"]!)
        let residency = ModelResidency(budgetBytes: 8 << 30)
        let p = LlamaCppProvider(config: LlamaCppConfig(modelPath: path, deadline: 30), residency: residency)
        let out = try await p.generate(prompt: "Once upon a time", system: "Continue the story.", stage: "cleanup")
        #expect(!out.text.isEmpty)
        // Warm second call: the model stays resident (one load), and the latency is reported.
        let t0 = Date()
        let again = try await p.generate(prompt: "meet at five, no, six", system: "Repeat the text.", stage: "cleanup")
        print("llama smoke: warm \(Int(Date().timeIntervalSince(t0) * 1000)) ms → \(again.text.prefix(80))")
        await residency.unload("cleanup.llm")
    }
}
