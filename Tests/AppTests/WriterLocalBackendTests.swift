import Engine
import Foundation
import Pipeline
import Providers
import Shared
import Testing
@testable import VoicePlusApp

/// Context Writer — the local backend on the hot path: the key-up call never starts a model load
/// (a cold model is a quick `notResident` skip; an in-flight key-down load is waited for only within
/// `loadWait`), the key-down prewarm respects the device's `ResidencyPlan` (no `.exclusive` load for a
/// guess), and the model the writer runs is the one the plan allows. A scripted engine stands in for
/// llama.cpp: no weights are loaded.
@Suite("Context Writer local backend")
struct WriterLocalBackendTests {
    final class FakeEngine: LocalLLMEngine, @unchecked Sendable {
        private let lock = NSLock()
        private let loadDelay: TimeInterval
        private var loads = 0
        private var generations = 0
        init(loadDelay: TimeInterval = 0) { self.loadDelay = loadDelay }
        func load(modelPath: URL) async throws {
            lock.withLock { loads += 1 }
            if loadDelay > 0 { try await Task.sleep(nanoseconds: UInt64(loadDelay * 1_000_000_000)) }
        }
        func unload() async {}
        func generate(system: String, user: String, maxTokens: Int, deadline: Date) async throws -> String {
            lock.withLock { generations += 1 }
            return "Send it to Kothari."
        }
        var loadCount: Int { lock.withLock { loads } }
        var generationCount: Int { lock.withLock { generations } }
    }

    static func backend(_ engine: FakeEngine, model: LocalLLMModel = LocalLLMCatalog.qwen35_2B,
                        plan: ResidencyPlan = .for(.roomy), loadWait: TimeInterval? = nil,
                        residency: ModelResidency = ModelResidency(budgetBytes: 64 << 30)) -> LocalWriterBackend {
        LocalWriterBackend(model: model, residency: residency, plan: plan, engine: engine, loadWait: loadWait,
                           fileExists: { _ in true })
    }

    static func write(_ backend: LocalWriterBackend) async throws -> String {
        try await backend.write(system: "s", user: "send it to cotari", context: StageContext())
    }

    @Test func aColdModelIsNeverLoadedAtKeyUp() async throws {
        let engine = FakeEngine(loadDelay: 1)
        let backend = Self.backend(engine)
        let start = Date()
        #expect(await !backend.readyForLanding())
        await #expect(throws: WriterBackendSkip.notResident) { try await Self.write(backend) }
        #expect(engine.loadCount == 0 && engine.generationCount == 0)
        #expect(Date().timeIntervalSince(start) < 0.5, "returns at once, not after a load")
    }

    @Test func theKeyUpCallWaitsForTheKeyDownLoad() async throws {
        let engine = FakeEngine(loadDelay: 0.2)
        let backend = Self.backend(engine)
        let prewarm = Task { await backend.prewarm() }
        for _ in 0..<200 where engine.loadCount == 0 { try await Task.sleep(nanoseconds: 2_000_000) }
        #expect(engine.loadCount == 1)
        #expect(try await Self.write(backend) == "Send it to Kothari.")
        #expect(engine.loadCount == 1 && engine.generationCount == 1, "one load, the key-down's")
        await prewarm.value
        // Resident now: the next landing runs straight away.
        #expect(await backend.readyForLanding())
    }

    @Test func aKeyDownLoadOutlivingTheWaitIsSkipped() async throws {
        let engine = FakeEngine(loadDelay: 2)
        let backend = Self.backend(engine, loadWait: 0.1)
        _ = Task { await backend.prewarm() }
        for _ in 0..<200 where engine.loadCount == 0 { try await Task.sleep(nanoseconds: 2_000_000) }
        let start = Date()
        await #expect(throws: WriterBackendSkip.notResident) { try await Self.write(backend) }
        #expect(Date().timeIntervalSince(start) < 1 && engine.generationCount == 0)
    }

    @Test func theWriterOwnsItsModelAsOnDemandOnEveryPlan() async throws {
        // 16 GB: CUA-S1's rule makes the planner's 4B `.exclusive`, but dictation runs the writer every
        // turn — it registers the model `.onDemand` and loads it at key-down.
        let engine = FakeEngine()
        let standard = Self.backend(engine, model: LocalLLMCatalog.qwen35_4B, plan: .for(.standard))
        #expect(standard.provider.config.tier == .onDemand)
        #expect(WriterWiring.writerTier(plan: .for(.standard)) == .onDemand)
        await standard.prewarm()
        #expect(engine.loadCount == 1)
        #expect(await standard.readyForLanding())
        // 24 GB: on-demand as well.
        let roomy = FakeEngine()
        let onDemand = Self.backend(roomy, model: LocalLLMCatalog.qwen35_4B, plan: .for(.roomy))
        await onDemand.prewarm()
        #expect(roomy.loadCount == 1)
    }

    @Test func aNonResidentExclusiveRegistrationIsReplacedAndAResidentOneIsUsed() async throws {
        // The edit-command provider registered the shared key `.exclusive` first (same GGUF, same engine).
        let residency = ModelResidency(budgetBytes: 64 << 30)
        let key = ComputerUseSettings.residencyKey(for: LocalLLMCatalog.qwen35_4B)
        let engine = FakeEngine()
        await residency.register(key, tier: .exclusive, estimatedBytes: 1, load: { }, unload: { })
        let backend = Self.backend(engine, model: LocalLLMCatalog.qwen35_4B, plan: .for(.standard), residency: residency)
        await backend.prewarm()
        #expect(await residency.snapshot().entries.first { $0.key == key }?.tier == .onDemand)
        #expect(engine.loadCount == 1)
        // Resident under an exclusive registration (an edit command just ran): used as it is, no reload.
        let busy = ModelResidency(budgetBytes: 64 << 30)
        let other = FakeEngine()
        await busy.register(key, tier: .exclusive, estimatedBytes: 1, load: { }, unload: { })
        _ = try await busy.acquire(key)
        let reuse = Self.backend(other, model: LocalLLMCatalog.qwen35_4B, plan: .for(.standard), residency: busy)
        await reuse.prewarm()
        #expect(await busy.isResident(key))
        #expect(other.loadCount == 0)
    }

    @Test func prefixPrewarmNeverLoadsOnItsOwn() async throws {
        let engine = FakeEngine()
        let backend = Self.backend(engine)
        let packet = ContextPacket(destination: .init(profileID: "chat.message", appBundleID: "com.a"), heard: .init(raw: ""))
        await backend.prewarm(packet: packet)
        #expect(engine.loadCount == 0)
    }

    @Test func toolsMayStillLoadOnWrite() async throws {
        let engine = FakeEngine()
        let backend = LocalWriterBackend(model: LocalLLMCatalog.qwen35_2B, residency: ModelResidency(budgetBytes: 64 << 30),
                                         plan: .for(.roomy), engine: engine, loadsOnWrite: true, fileExists: { _ in true })
        #expect(try await Self.write(backend) == "Send it to Kothari.")
        #expect(engine.loadCount == 1)
    }

    // MARK: Which model the plan allows

    static func manager(onDisk: [LocalLLMModel], preferred: LocalLLMModel? = nil) throws -> LocalModelManager {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("writer-models-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for m in onDisk { try Data("gguf".utf8).write(to: m.localURL(root: root)) }
        let manager = LocalModelManager(root: root, residency: nil, persistence: .inMemory())
        manager.setPreferred(preferred?.id)
        return manager
    }

    @Test func installedLocalModelFollowsTheResidencyPlan() throws {
        let two = LocalLLMCatalog.qwen35_2B, four = LocalLLMCatalog.qwen35_4B
        let both = try Self.manager(onDisk: [two, four], preferred: four)
        // 8 GB: the plan hides the on-device LLM — Automatic is Off there.
        #expect(WriterWiring.installedLocalModel(manager: both, plan: .for(.compact), runtimeAvailable: true) == nil)
        #expect(WriterWiring.installedLocalModel(manager: both, plan: .for(.roomy), runtimeAvailable: false) == nil)
        // 24 GB: the user's pick.
        #expect(WriterWiring.installedLocalModel(manager: both, plan: .for(.roomy), runtimeAvailable: true)?.id == four.id)
        // 16 GB: the user's pick too (the writer registers it `.onDemand`; 3.2 GB fits the 4.5 GiB budget).
        #expect(WriterWiring.installedLocalModel(manager: both, plan: .for(.standard), runtimeAvailable: true)?.id == four.id)
        // Only the 4B on disk: offered.
        let onlyFour = try Self.manager(onDisk: [four])
        #expect(WriterWiring.installedLocalModel(manager: onlyFour, plan: .for(.standard), runtimeAvailable: true)?.id == four.id)
        let none = try Self.manager(onDisk: [])
        #expect(WriterWiring.installedLocalModel(manager: none, plan: .for(.roomy), runtimeAvailable: true) == nil)
    }
}
