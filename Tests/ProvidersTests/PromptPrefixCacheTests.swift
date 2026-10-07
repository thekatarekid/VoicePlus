import Foundation
import Shared
import Testing
@testable import Providers

// Context Writer latency (plan §4.1) — the local prompt-prefix cache against a scripted KV memory:
// which part of a new prompt is reused (extend / trim / restore / cold), where the checkpoint is
// saved, what a recurrent (hybrid) memory can and cannot do, room, interruption, invalidation.
// The live model is exercised by `PrefixCacheBenchmarkTests` below (skipped without the GGUF).

/// Seq 0 / seq 1 as token arrays. `recurrent` models a hybrid memory (Qwen3.5): a sequence cannot
/// be cut part-way, only emptied.
final class ScriptedPrefixMemory: PromptPrefixMemory {
    struct DecodeFailure: Error {}
    let recurrent: Bool
    var seq0: [Int32] = []
    var seq1: [Int32] = []
    var decodes: [[Int32]] = []
    var ops: [String] = []
    var failNextDecode = false

    init(recurrent: Bool = false) { self.recurrent = recurrent }

    var decoded: Int { decodes.map(\.count).reduce(0, +) }

    func trimWorking(from position: Int) -> Bool {
        if recurrent, position < seq0.count { ops.append("trim-refused"); return false }
        ops.append("trim")
        seq0 = Array(seq0.prefix(position))
        return true
    }
    func clearWorking() { ops.append("clear0"); seq0 = [] }
    func saveCheckpoint() { ops.append("save"); seq1 = seq0 }
    func restoreCheckpoint() { ops.append("restore"); seq0 = seq1 }
    func clearCheckpoint() { ops.append("clear1"); seq1 = [] }
    func clearAll() { ops.append("clearAll"); seq0 = []; seq1 = [] }
    func decode(_ tokens: ArraySlice<Int32>) throws {
        if failNextDecode { failNextDecode = false; throw DecodeFailure() }
        decodes.append(Array(tokens))
        seq0 += tokens
    }
    func workingLength() -> Int { seq0.count }
}

private let system: [Int32] = Array(1...6)            // system turn + user header
private let prefix: [Int32] = system + Array(7...20)  // + the stable prefix (20 tokens)
private func tail(_ base: Int32, _ n: Int = 4) -> [Int32] { (0..<Int32(n)).map { base + $0 } }

@Suite struct PromptPrefixCacheTests {

    @Test func prewarmThenGenerateDecodesOnlyTheTail() throws {
        let memory = ScriptedPrefixMemory()
        var cache = PromptPrefixCache()
        let warm = try cache.prepare(prefix, needsLogits: false, memory: memory, chunk: 8, checkpointAt: prefix.count)
        #expect(warm == .cold && memory.decoded == 20)
        #expect(cache.checkpoint == prefix && memory.seq1 == prefix)
        let prompt = prefix + tail(100)
        let reuse = try cache.prepare(prompt, needsLogits: true, memory: memory, chunk: 8, checkpointAt: prefix.count)
        #expect(reuse == .extend(reused: 20))
        #expect(memory.decoded == 24 && memory.decodes.last == tail(100))
        #expect(memory.seq0 == prompt && cache.working == prompt)
        #expect(memory.ops.filter { $0 == "save" }.count == 1)   // the prewarm's; the call adds none
    }

    @Test func attentionModelTrimsTheDivergingTail() throws {
        let memory = ScriptedPrefixMemory(recurrent: false)
        var cache = PromptPrefixCache()
        try cache.prepare(prefix + tail(100), needsLogits: true, memory: memory, chunk: 512, checkpointAt: system.count)
        cache.appendDecoded([900, 901]); memory.seq0 += [900, 901]   // the generated answer
        let before = memory.decoded
        let next = prefix + tail(200)
        let reuse = try cache.prepare(next, needsLogits: true, memory: memory, chunk: 512, checkpointAt: system.count)
        #expect(reuse == .trim(reused: 20))
        #expect(memory.decoded - before == 4)
        #expect(memory.seq0 == next && cache.working == next)
    }

    @Test func hybridModelRestoresTheCheckpointInsteadOfCutting() throws {
        let memory = ScriptedPrefixMemory(recurrent: true)
        var cache = PromptPrefixCache()
        try cache.prepare(prefix, needsLogits: false, memory: memory, chunk: 512, checkpointAt: prefix.count)
        try cache.prepare(prefix + tail(100), needsLogits: true, memory: memory, chunk: 512, checkpointAt: prefix.count)
        cache.appendDecoded([900]); memory.seq0 += [900]
        let before = memory.decoded
        let next = prefix + tail(200, 6)
        let reuse = try cache.prepare(next, needsLogits: true, memory: memory, chunk: 512, checkpointAt: prefix.count)
        #expect(reuse == .restore(reused: 20))
        #expect(memory.ops.suffix(2) == ["trim-refused", "restore"])
        #expect(memory.decoded - before == 6)
        #expect(memory.seq0 == next && memory.seq1 == prefix)
        #expect(cache.occupied == next.count)   // the restored prefix shares the checkpoint's cells
    }

    @Test func identicalPromptStillDecodesItsLastToken() throws {
        for recurrent in [false, true] {
            let memory = ScriptedPrefixMemory(recurrent: recurrent)
            var cache = PromptPrefixCache()
            let prompt = prefix + tail(100)
            try cache.prepare(prompt, needsLogits: true, memory: memory, chunk: 512, checkpointAt: prefix.count)
            let before = memory.decoded
            let reuse = try cache.prepare(prompt, needsLogits: true, memory: memory, chunk: 512, checkpointAt: prefix.count)
            // Attention: cut back one token and decode it again. Hybrid: back to the checkpoint.
            #expect(reuse == (recurrent ? .restore(reused: 20) : .trim(reused: prompt.count - 1)))
            #expect(memory.decoded - before == (recurrent ? 4 : 1))
            #expect(memory.seq0 == prompt)
        }
    }

    @Test func noPrewarmCheckpointsTheSystemTurn() throws {
        let memory = ScriptedPrefixMemory(recurrent: true)
        var cache = PromptPrefixCache()
        let first = prefix + tail(100)
        #expect(try cache.prepare(first, needsLogits: true, memory: memory, chunk: 512, checkpointAt: system.count) == .cold)
        #expect(cache.checkpoint == system)
        #expect(memory.decodes.map(\.count) == [system.count, first.count - system.count])   // split at the checkpoint
        // A different stable prefix behind the same system prompt: only the system turn is reused.
        let other = system + Array(50...70) + tail(200)
        let reuse = try cache.prepare(other, needsLogits: true, memory: memory, chunk: 512, checkpointAt: system.count)
        #expect(reuse == .restore(reused: system.count))
        #expect(memory.seq0 == other)
    }

    @Test func divergenceInsideTheCheckpointStartsCold() throws {
        let memory = ScriptedPrefixMemory(recurrent: true)
        var cache = PromptPrefixCache()
        try cache.prepare(prefix, needsLogits: false, memory: memory, chunk: 512, checkpointAt: prefix.count)
        // Another system prompt altogether: nothing reusable, and the old checkpoint is replaced at
        // the new system turn's end.
        let otherSystem: [Int32] = [1, 2, 99, 98, 97]
        let next = otherSystem + tail(300)
        let before = memory.decoded
        #expect(try cache.prepare(next, needsLogits: true, memory: memory, chunk: 512, checkpointAt: otherSystem.count) == .cold)
        #expect(memory.decoded - before == next.count)
        #expect(cache.checkpoint == otherSystem && memory.seq1 == otherSystem)
    }

    @Test func aCheckpointCoveringThePromptIsKept() throws {
        let memory = ScriptedPrefixMemory()
        var cache = PromptPrefixCache()
        try cache.prepare(prefix, needsLogits: false, memory: memory, chunk: 512, checkpointAt: prefix.count)
        let saves = memory.ops.filter { $0 == "save" }.count
        // The generation's own checkpoint position (the system turn) is inside the prewarmed one.
        try cache.prepare(prefix + tail(100), needsLogits: true, memory: memory, chunk: 512, checkpointAt: system.count)
        #expect(memory.ops.filter { $0 == "save" }.count == saves)
        #expect(cache.checkpoint == prefix)
    }

    @Test func roomDropsACheckpointThePromptDoesNotUse() throws {
        let memory = ScriptedPrefixMemory()
        var cache = PromptPrefixCache()
        try cache.prepare(prefix, needsLogits: false, memory: memory, chunk: 512, checkpointAt: prefix.count, capacity: 64)
        let unrelated: [Int32] = Array(500...529)
        try cache.prepare(unrelated, needsLogits: true, memory: memory, chunk: 512, checkpointAt: nil, reserve: 20, capacity: 64)
        #expect(cache.checkpoint.isEmpty && memory.seq1.isEmpty)
        // With room, the checkpoint stays.
        let roomy = ScriptedPrefixMemory()
        var kept = PromptPrefixCache()
        try kept.prepare(prefix, needsLogits: false, memory: roomy, chunk: 512, checkpointAt: prefix.count, capacity: 4096)
        try kept.prepare(unrelated, needsLogits: true, memory: roomy, chunk: 512, checkpointAt: nil, reserve: 20, capacity: 4096)
        #expect(kept.checkpoint == prefix)
    }

    @Test func anInterruptedPrefillKeepsWhatItDecoded() throws {
        let memory = ScriptedPrefixMemory(recurrent: true)
        var cache = PromptPrefixCache()
        var chunks = 0
        #expect(throws: PromptPrefixCache.Interrupted.self) {
            try cache.prepare(prefix, needsLogits: false, memory: memory, chunk: 8, checkpointAt: prefix.count) {
                chunks += 1
                if chunks > 2 { throw PromptPrefixCache.Interrupted() }
            }
        }
        #expect(cache.working == Array(prefix.prefix(16)) && memory.seq0 == cache.working)
        #expect(cache.checkpoint.isEmpty)
        // The generation that interrupted it extends what is there.
        let prompt = prefix + tail(100)
        let reuse = try cache.prepare(prompt, needsLogits: true, memory: memory, chunk: 512, checkpointAt: prefix.count)
        #expect(reuse == .extend(reused: 16))
        #expect(cache.checkpoint == prefix && memory.seq0 == prompt)
    }

    @Test func aFailedDecodeForgetsEverything() throws {
        let memory = ScriptedPrefixMemory()
        var cache = PromptPrefixCache()
        try cache.prepare(prefix, needsLogits: false, memory: memory, chunk: 512, checkpointAt: prefix.count)
        memory.failNextDecode = true
        #expect(throws: ScriptedPrefixMemory.DecodeFailure.self) {
            try cache.prepare(prefix + tail(100), needsLogits: true, memory: memory, chunk: 512, checkpointAt: prefix.count)
        }
        #expect(cache.working.isEmpty && cache.checkpoint.isEmpty)
        #expect(memory.seq0.isEmpty && memory.seq1.isEmpty && memory.ops.last == "clearAll")
    }

    @Test func unloadInvalidatesAndANewContextStartsCold() throws {
        let memory = ScriptedPrefixMemory()
        var cache = PromptPrefixCache()
        try cache.prepare(prefix, needsLogits: false, memory: memory, chunk: 512, checkpointAt: prefix.count)
        // ModelResidency unloads: the engine frees the context and resets the bookkeeping.
        cache.reset()
        let fresh = ScriptedPrefixMemory()
        let prompt = prefix + tail(100)
        #expect(try cache.prepare(prompt, needsLogits: true, memory: fresh, chunk: 512, checkpointAt: prefix.count) == .cold)
        #expect(fresh.decoded == prompt.count)
    }

    @Test func memoryThatDisagreesWithTheBookkeepingIsCleared() throws {
        let memory = ScriptedPrefixMemory()
        var cache = PromptPrefixCache()
        try cache.prepare(prefix, needsLogits: false, memory: memory, chunk: 512, checkpointAt: prefix.count)
        memory.seq0 = Array(memory.seq0.prefix(3))   // something else touched the memory
        let prompt = prefix + tail(100)
        #expect(try cache.prepare(prompt, needsLogits: true, memory: memory, chunk: 512, checkpointAt: prefix.count) == .cold)
        #expect(memory.ops.contains("clearAll") && memory.seq0 == prompt)
    }

    @Test func commonPrefix() {
        #expect(PromptPrefixCache.commonPrefix([], [1]) == 0)
        #expect(PromptPrefixCache.commonPrefix([1, 2, 3], [1, 2, 4]) == 2)
        #expect(PromptPrefixCache.commonPrefix([1, 2], [1, 2, 3]) == 2)
    }
}

// MARK: - The provider's prewarm

final class PrewarmEngine: LocalLLMEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var _loads = 0
    private var _prewarms: [(system: String, prefix: String)] = []
    var fail = false
    var loads: Int { lock.withLock { _loads } }
    var prewarms: [(system: String, prefix: String)] { lock.withLock { _prewarms } }
    func load(modelPath: URL) async throws { lock.withLock { _loads += 1 } }
    func unload() async {}
    func generate(system: String, user: String, maxTokens: Int, deadline: Date) async throws -> String { user }
    func prewarm(system: String, prefix: String) async throws {
        lock.withLock { _prewarms.append((system, prefix)) }
        if fail { throw LlamaCppError.notLoaded }
    }
}

@Suite struct LlamaPrewarmProviderTests {
    private func provider(_ engine: any LocalLLMEngine, residency: ModelResidency, installed: Bool = true,
                          refuseUnderPressure: Bool = false) -> LlamaCppProvider {
        LlamaCppProvider(config: LlamaCppConfig(modelPath: URL(fileURLWithPath: "/tmp/writer.gguf"), residencyKey: "writer.llm",
                                                refuseUnderCriticalPressure: refuseUnderPressure),
                         residency: residency, engine: engine, fileExists: { _ in installed })
    }

    @Test func prewarmLoadsThroughTheResidencyAndReachesTheEngine() async {
        let engine = PrewarmEngine()
        let residency = ModelResidency(budgetBytes: 8 << 30)
        let p: any PromptPrefixPrewarming = provider(engine, residency: residency)
        await p.prewarm(system: "SYSTEM", prefix: "MODE: transcribe\n")
        #expect(engine.loads == 1)
        #expect(engine.prewarms.map(\.system) == ["SYSTEM"] && engine.prewarms.map(\.prefix) == ["MODE: transcribe\n"])
        #expect(await residency.isResident("writer.llm"))
    }

    @Test func prewarmWithoutTheModelDoesNothing() async {
        let engine = PrewarmEngine()
        let residency = ModelResidency(budgetBytes: 8 << 30)
        await provider(engine, residency: residency, installed: false).prewarm(system: "S", prefix: "P")
        #expect(engine.loads == 0 && engine.prewarms.isEmpty)
        #expect(await residency.isRegistered("writer.llm") == false)
    }

    @Test func prewarmNeverLoadsUnderCriticalPressure() async {
        let engine = PrewarmEngine()
        let residency = ModelResidency(budgetBytes: 8 << 30)
        await residency.handleMemoryPressure(.critical)
        await provider(engine, residency: residency, refuseUnderPressure: true).prewarm(system: "S", prefix: "P")
        #expect(engine.loads == 0 && engine.prewarms.isEmpty)
    }

    @Test func aFailingPrewarmIsSwallowed() async {
        let engine = PrewarmEngine(); engine.fail = true
        await provider(engine, residency: ModelResidency(budgetBytes: 8 << 30)).prewarm(system: "S", prefix: "P")
        #expect(engine.prewarms.count == 1)
    }

    @Test func anEngineWithoutPrewarmIsANoOp() async throws {
        // `ScriptedEngine` (LlamaCppProviderTests) has no prewarm: the protocol default runs.
        let engine = ScriptedEngine()
        let p = provider(engine, residency: ModelResidency(budgetBytes: 8 << 30))
        await p.prewarm(system: "S", prefix: "P")
        #expect(engine.calls.isEmpty)
    }
}

// MARK: - Live: cold vs prefix-warm on the owner's model (skipped without the GGUF)

@Suite(.serialized) struct PrefixCacheBenchmarkTests {
    static let modelPath: URL = {
        if let env = ProcessInfo.processInfo.environment["VOICEPLUS_WRITER_GGUF"] { return URL(fileURLWithPath: env) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VoicePlus/Models/llm/Qwen3.5-4B-Q4_K_M.gguf")
    }()
    static var available: Bool { FileManager.default.fileExists(atPath: modelPath.path) }

    /// A writer-shaped prompt: ~900 tokens known at key-down (rules, profile, thread, field text,
    /// terms, recent dictations) and a ~60-token tail (vocab, heard, alternates).
    static let system: String = {
        let rules = (1...9).map { i in
            "Rule \(i): when the recogniser writes a word that sounds like a name, product or term on the screen, prefer the on-screen spelling only if it sounds the same and fits the sentence; otherwise keep the user's words exactly as they were heard."
        }
        return "You are the final step of a voice dictation app. Output only the final text, nothing else.\n"
            + rules.joined(separator: "\n")
            + "\nDESTINATION PROFILE: Chat message\nOutput: casual, no full stop on a one-liner, keep emoji words as words."
    }()
    static let prefix: String = {
        let thread = (1...9).map { i in
            "- \(i % 2 == 0 ? "Rahul" : "Priya"): message \(i) about the GRDB migration, the Parakeet streaming preview and the standup notes for Thursday"
        }
        return "MODE: transcribe\nDESTINATION: chat.message; app: Slack; surface: chatComposer; channel: #eng-platform; participants: Rahul, Priya\n"
            + "THREAD (oldest first):\n" + thread.joined(separator: "\n")
            + "\nBEFORE: sounds good,\nTERMS: GRDB, Parakeet, standup, FluidAudio, llama.cpp, Qwen\n"
            + "RECENT: will do, give me ten\nRECENT: pushed the fix\n"
    }()
    static func tail(_ heard: String) -> String {
        "VOCAB: Parakeet (heard \"para keet\")\nHEARD: \(heard)\nALT: keet -> kit | keat\nALT: para keet -> Parakeet (vocab)"
    }

    @Test(.enabled(if: PrefixCacheBenchmarkTests.available, "Qwen3.5-4B GGUF not on disk"))
    func coldVersusPrefixWarm() async throws {
        let engine = LlamaCppEngine(contextTokens: 4096)
        try await engine.load(modelPath: Self.modelPath)
        do { try await bench(engine) } catch { await engine.unload(); throw error }
        await engine.unload()
    }

    private func bench(_ engine: LlamaCppEngine) async throws {
        let far = Date().addingTimeInterval(120)
        func ms(_ t0: Date) -> Int { Int(Date().timeIntervalSince(t0) * 1000) }

        // Metal / graph warm-up on an unrelated prompt (not counted).
        _ = try await engine.generate(system: "Repeat the text.", user: "hello", maxTokens: 4, deadline: far)

        let heardA = "sending the ⟦para⟧ ⟦keet⟧ deck now, can you check slide four before standup"
        let heardB = "also the ⟦grdb⟧ migration is done, I will merge it after lunch"
        let heardC = "one more thing, the ⟦fluid⟧ audio bump needs a release note"

        // Cold: nothing reusable (another system prompt ran last).
        var t0 = Date()
        let coldA = try await engine.generate(system: Self.system, user: Self.prefix + Self.tail(heardA), maxTokens: 48, deadline: far)
        let coldMs = ms(t0)
        let cold = engine.lastPrefix
        // Prefix-only first token (prefill cost) cold: a fresh system variant so nothing is reused.
        t0 = Date()
        _ = try await engine.generate(system: Self.system + " ", user: Self.prefix + Self.tail(heardA), maxTokens: 1, deadline: far)
        let coldPrefillMs = ms(t0)

        // Key-down prewarm, then the call after key-up.
        t0 = Date()
        try await engine.prewarm(system: Self.system, prefix: Self.prefix)
        let prewarmMs = ms(t0)
        let warmedPrefix = engine.lastPrefix
        t0 = Date()
        let warmB = try await engine.generate(system: Self.system, user: Self.prefix + Self.tail(heardB), maxTokens: 48, deadline: far)
        let warmMs = ms(t0)
        let warm = engine.lastPrefix
        // A second call on the same prefix (hybrid model: restored from the checkpoint).
        t0 = Date()
        _ = try await engine.generate(system: Self.system, user: Self.prefix + Self.tail(heardC), maxTokens: 1, deadline: far)
        let warmPrefillMs = ms(t0)
        let restored = engine.lastPrefix
        t0 = Date()
        let warmA = try await engine.generate(system: Self.system, user: Self.prefix + Self.tail(heardA), maxTokens: 48, deadline: far)
        let warmAMs = ms(t0)

        print("prefix-cache bench: prompt \(cold?.decoded ?? -1) tokens cold (\(cold?.reuse.code ?? "?")), "
              + "prefix \(warmedPrefix?.decoded ?? -1) tokens prewarmed in \(prewarmMs) ms")
        print("prefix-cache bench: 48-token answer cold \(coldMs) ms vs prefix-warm \(warmMs) ms "
              + "(\(warm?.reuse.code ?? "?") reused \(warm?.reuse.reused ?? -1), decoded \(warm?.decoded ?? -1)); again \(warmAMs) ms")
        print("prefix-cache bench: first token cold \(coldPrefillMs) ms vs warm \(warmPrefillMs) ms "
              + "(\(restored?.reuse.code ?? "?") decoded \(restored?.decoded ?? -1))")

        #expect(cold?.reuse == .cold)
        #expect((warm?.decoded ?? 999) < 120)
        #expect((restored?.decoded ?? 999) < 120)
        // Greedy: the cached path must answer exactly what the cold path answered.
        #expect(warmA == coldA)

        // Unload (ModelResidency eviction) forgets the cache: the next call is cold again, and its
        // answer is the same.
        await engine.unload()
        try await engine.load(modelPath: Self.modelPath)
        let coldB = try await engine.generate(system: Self.system, user: Self.prefix + Self.tail(heardB), maxTokens: 48, deadline: far)
        #expect(engine.lastPrefix?.reuse == .cold)
        #expect(coldB == warmB)
    }

    @Test(.enabled(if: PrefixCacheBenchmarkTests.available, "Qwen3.5-4B GGUF not on disk"))
    func aQueuedGenerationStopsAPrewarmAndACancelStopsAGeneration() async throws {
        let engine = LlamaCppEngine(contextTokens: 4096, batchTokens: 64)
        try await engine.load(modelPath: Self.modelPath)
        do { try await interruptions(engine) } catch { await engine.unload(); throw error }
        await engine.unload()
    }

    private func interruptions(_ engine: LlamaCppEngine) async throws {
        let far = Date().addingTimeInterval(120)
        let longPrefix = String(repeating: Self.prefix, count: 3)
        async let warm: Void = engine.prewarm(system: Self.system, prefix: longPrefix)
        try? await Task.sleep(nanoseconds: 30_000_000)
        let out = try await engine.generate(system: Self.system, user: longPrefix + Self.tail("hello there"), maxTokens: 8, deadline: far)
        try await warm
        #expect(!out.isEmpty)
        // The generation reused whatever the interrupted prewarm had decoded.
        #expect((engine.lastPrefix?.reuse.reused ?? 0) > 0)

        let task = Task {
            try await engine.generate(system: "Write a long story.", user: "Once upon a time", maxTokens: 2000, deadline: far)
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        let t0 = Date()
        task.cancel()
        let result = await task.result
        #expect(Date().timeIntervalSince(t0) < 1.0)
        if case .success = result { Issue.record("a cancelled generation ran to its token limit") }
    }
}
