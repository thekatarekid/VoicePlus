import Foundation
import Shared
#if canImport(llama)
import llama
#endif

// MARK: - V5 D2 · llama.cpp provider (on-device cleanup LLM)
//
// One local-LLM runtime for the app: the prebuilt llama.cpp XCFramework (MIT, `Package.swift`
// binary target `llama`). D2's cleanup stage uses it today; CU8 reuses it later.
//
// §10 contracts:
// - The model is loaded ONLY through `ModelResidency` (HW1): the provider registers its key once with
//   `load`/`unload` closures and runs every generation inside `withModel`, so the residency can
//   evict, idle out (D5) and prewarm it like any other model. Nothing here calls the llama loader
//   outside those closures.
// - It is a `Provider` (a `TextGenerator`), so it is called through `RoutingTable` like every other
//   generative model (stage `cleanup`).
//
// The engine sits behind `LocalLLMEngine` so tests drive the provider with a scripted engine and
// never download a GGUF.

/// The text-in/text-out runtime under `LlamaCppProvider`. `load`/`unload` are only ever called from
/// the `ModelResidency` closures.
public protocol LocalLLMEngine: AnyObject, Sendable {
    func load(modelPath: URL) async throws
    func unload() async
    /// One greedy completion of a system + user chat. Must stop at `maxTokens` and throw
    /// `ProviderError.timeout` once `deadline` passes.
    func generate(system: String, user: String, maxTokens: Int, deadline: Date) async throws -> String
    /// H14 — the same with an explicit sampler. Default: greedy (the original path).
    func generate(system: String, user: String, maxTokens: Int, deadline: Date, sampling: LlamaSampling) async throws -> String
}

public extension LocalLLMEngine {
    func generate(system: String, user: String, maxTokens: Int, deadline: Date, sampling: LlamaSampling) async throws -> String {
        try await generate(system: system, user: user, maxTokens: maxTokens, deadline: deadline)
    }
}

/// H14 — how tokens are picked. Cleanup stays greedy (as the cleanup models were evaluated); the
/// shared Qwen3.5 model uses Qwen's published non-thinking settings plus a mild repetition penalty
/// over the generated tokens only (the prompt is never penalised, so copying source words is free).
public enum LlamaSampling: Equatable, Sendable {
    case greedy
    case qwenNonThinking

    public struct Parameters: Equatable, Sendable {
        public var temperature: Float, topP: Float, topK: Int32, minP: Float
        public var repeatPenalty: Float, presencePenalty: Float, penaltyLastN: Int32, seed: UInt32
    }

    /// Qwen3.x non-thinking: temperature 0.7, top-p 0.8, top-k 20, min-p 0; repeat 1.05 over the last
    /// 64 generated tokens. Fixed seed so the same edit gives the same answer.
    public var parameters: Parameters? {
        switch self {
        case .greedy: return nil
        case .qwenNonThinking:
            return Parameters(temperature: 0.7, topP: 0.8, topK: 20, minP: 0, repeatPenalty: 1.05,
                              presencePenalty: 0, penaltyLastN: 64, seed: 42)
        }
    }
}

/// H16 — the on-device model refused to load because the Mac is under critical memory pressure.
public enum LocalLLMRefusal: Error, Equatable, Sendable {
    case notEnoughMemory

    public var message: String {
        switch self { case .notEnoughMemory: return "Not enough memory for this edit right now" }
    }
}

public struct LlamaCppConfig: Sendable, Equatable {
    /// The GGUF on disk.
    public var modelPath: URL
    /// The residency key (`ResidencyKey.cleanup` = "cleanup.llm" for D2).
    public var residencyKey: String
    public var tier: ResidencyTier
    /// RAM in use when loaded (weights + KV cache); the residency budgets with it.
    public var estimatedBytes: Int64
    /// Upper bound on generated tokens. `nil` = derived from the prompt length (SpeakoFlow asks for
    /// no hard cap: a truncated transcript counts as lost content).
    public var maxTokens: Int?
    /// Wall-clock budget for one generation (D2: 500 ms p95 on the cleanup path).
    public var deadline: TimeInterval
    public var lighterAlternative: String?
    /// H14 — token picking (greedy for cleanup, Qwen non-thinking for the shared model).
    public var sampling: LlamaSampling
    /// H16 — unload this model once it has been idle this long (nil = the residency's global sweep).
    public var idleUnloadAfter: TimeInterval?
    /// H16 — refuse to *load* while the residency reports critical memory pressure.
    public var refuseUnderCriticalPressure: Bool
    /// Stages this provider answers (nil = any). The cleanup specialist serves `cleanup` only, so an
    /// edit routed through the table never lands on it.
    public var servedStages: Set<StageID>?

    public init(modelPath: URL, residencyKey: String = "cleanup.llm", tier: ResidencyTier = .onDemand,
                estimatedBytes: Int64 = 700_000_000, maxTokens: Int? = nil, deadline: TimeInterval = 0.5,
                lighterAlternative: String? = nil, sampling: LlamaSampling = .greedy,
                idleUnloadAfter: TimeInterval? = nil, refuseUnderCriticalPressure: Bool = false,
                servedStages: Set<StageID>? = nil) {
        self.sampling = sampling
        self.idleUnloadAfter = idleUnloadAfter
        self.refuseUnderCriticalPressure = refuseUnderCriticalPressure
        self.servedStages = servedStages
        self.modelPath = modelPath
        self.residencyKey = residencyKey
        self.tier = tier
        self.estimatedBytes = estimatedBytes
        self.maxTokens = maxTokens
        self.deadline = deadline
        self.lighterAlternative = lighterAlternative
    }
}

public final class LlamaCppProvider: TextGenerator, @unchecked Sendable {
    public static let providerID: ProviderID = "local.llamacpp"
    public let id: ProviderID = LlamaCppProvider.providerID
    public let displayName: String
    public let capabilities: ProviderCapabilities = [.pipeline]
    public let costClass: CostClass = .free
    public let privacyClass: PrivacyClass = .onDevice

    public let config: LlamaCppConfig
    private let residency: ModelResidency
    private let engine: any LocalLLMEngine
    private let fileExists: @Sendable (URL) -> Bool
    private let idleLock = NSLock()
    private var generation = 0

    public init(config: LlamaCppConfig, displayName: String = "On this Mac (llama.cpp)",
                residency: ModelResidency = .shared, engine: (any LocalLLMEngine)? = nil,
                fileExists: @escaping @Sendable (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) {
        self.config = config
        self.displayName = displayName
        self.residency = residency
        self.engine = engine ?? LlamaCppEngine.shared(for: config.modelPath)
        self.fileExists = fileExists
    }

    /// True when the runtime is linked and the GGUF is on disk. Never loads anything.
    public func isAvailable() async -> Bool {
        LlamaCppEngine.runtimeAvailable && fileExists(config.modelPath)
    }

    /// Register the model with the residency (idempotent: an existing registration is kept). Called
    /// before each generation and by the app when cleanup is on, so D5's prewarm finds the key. The
    /// engine is shared per GGUF path, so any provider instance's closures drive the same weights.
    public func registerWithResidency() async {
        if await residency.isRegistered(config.residencyKey) { return }
        let engine = self.engine, path = config.modelPath
        await residency.register(config.residencyKey, tier: config.tier, estimatedBytes: config.estimatedBytes,
                                 lighterAlternative: config.lighterAlternative, owner: "llamacpp",
                                 load: { try await engine.load(modelPath: path) },
                                 unload: { await engine.unload() })
    }

    /// Token cap for a prompt of `characters`: about one token per 3 characters, doubled, plus room
    /// for formatting. Long enough never to truncate a cleanup (output ≤ 1.5 × input, D3).
    public static func derivedMaxTokens(forCharacters characters: Int) -> Int {
        max(64, characters * 2 / 3 + 32)
    }

    public func generate(prompt: String, system: String, stage: StageID) async throws
        -> (text: String, bytesOut: Int, bytesIn: Int, host: String) {
        if let served = config.servedStages, !served.contains(stage) {
            throw ProviderError.unavailable("llama.cpp provider does not serve \(stage)")
        }
        guard await isAvailable() else { throw ProviderError.unavailable("llama.cpp model not installed") }
        await registerWithResidency()
        // H16 — never start a load under critical pressure; an already-resident model may still run.
        if config.refuseUnderCriticalPressure, await residency.isRunningLighter,
           await !residency.isResident(config.residencyKey) {
            throw LocalLLMRefusal.notEnoughMemory
        }
        let ticket = idleLock.withLock { generation += 1; return generation }
        defer { scheduleIdleUnload(after: ticket) }
        let deadline = Date().addingTimeInterval(config.deadline)
        let maxTokens = LocalLLMBudget.outputCap ?? config.maxTokens ?? Self.derivedMaxTokens(forCharacters: prompt.count)
        let engine = self.engine, sampling = config.sampling
        let text: String
        do {
            text = try await residency.withModel(config.residencyKey) {
                try await engine.generate(system: system, user: prompt, maxTokens: maxTokens, deadline: deadline,
                                          sampling: sampling)
            }
        } catch let e as ProviderError {
            throw e
        } catch let e as ResidencyError {
            throw ProviderError.unavailable("residency: \(e)")
        } catch {
            throw ProviderError.unavailable("llama.cpp: \(error)")
        }
        // Local: nothing crosses the network, so the byte counters stay 0.
        return (Self.stripReasoning(text), 0, 0, "on-device")
    }

    /// H16 — unload ~`idleUnloadAfter` after the last generation, unless another one started since.
    private func scheduleIdleUnload(after ticket: Int) {
        guard let idle = config.idleUnloadAfter else { return }
        let residency = self.residency, key = config.residencyKey
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, idle) * 1_000_000_000))
            guard let self, self.idleLock.withLock({ self.generation == ticket }) else { return }
            await residency.unload(key, reason: .idle)
        }
    }

    /// Qwen-family models may emit a `<think>…</think>` block; it is never part of the answer.
    public static func stripReasoning(_ text: String) -> String {
        var t = text
        while let open = t.range(of: "<think>") {
            if let close = t.range(of: "</think>", range: open.upperBound..<t.endIndex) {
                t.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                t.removeSubrange(open.lowerBound..<t.endIndex)
            }
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - The real engine

public enum LlamaCppError: Error, Equatable, Sendable {
    case runtimeMissing
    case loadFailed(String)
    case notLoaded
    case promptTooLong(tokens: Int, context: Int)
    case decodeFailed(Int32)
    case tokenizeFailed
}

/// llama.cpp over its C API. All calls run on one serial queue; one generation at a time. Greedy
/// sampling (temperature 0, as the cleanup models were evaluated).
public final class LlamaCppEngine: LocalLLMEngine, @unchecked Sendable {
    public static var runtimeAvailable: Bool {
        #if canImport(llama)
        return true
        #else
        return false
        #endif
    }

    public let contextTokens: UInt32
    public let batchTokens: UInt32
    public let gpuLayers: Int32
    private let queue = DispatchQueue(label: "in.adityakatare.voiceplus.llamacpp", qos: .userInitiated)
    #if canImport(llama)
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    #endif

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: LlamaCppEngine] = [:]

    /// One engine per GGUF: every provider for the same file shares its loaded weights.
    public static func shared(for modelPath: URL) -> LlamaCppEngine {
        registryLock.withLock {
            if let e = registry[modelPath.path] { return e }
            let e = LlamaCppEngine()
            registry[modelPath.path] = e
            return e
        }
    }

    public init(contextTokens: UInt32 = 4096, batchTokens: UInt32 = 512, gpuLayers: Int32 = 99) {
        self.contextTokens = contextTokens
        self.batchTokens = batchTokens
        self.gpuLayers = gpuLayers
    }

    deinit {
        #if canImport(llama)
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        #endif
    }

    private func onQueue<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async { cont.resume(with: Result { try body() }) }
        }
    }

    public func load(modelPath: URL) async throws {
        #if canImport(llama)
        try await onQueue { [self] in
            if model != nil, context != nil { return }
            Self.initBackend
            var mp = llama_model_default_params()
            mp.n_gpu_layers = gpuLayers
            guard let m = llama_model_load_from_file(modelPath.path, mp) else {
                throw LlamaCppError.loadFailed(modelPath.lastPathComponent)
            }
            var cp = llama_context_default_params()
            cp.n_ctx = contextTokens
            cp.n_batch = batchTokens
            let threads = Int32(max(2, ProcessInfo.processInfo.activeProcessorCount - 2))
            cp.n_threads = threads
            cp.n_threads_batch = threads
            cp.no_perf = true
            guard let c = llama_init_from_model(m, cp) else {
                llama_model_free(m)
                throw LlamaCppError.loadFailed("context")
            }
            model = m
            context = c
        }
        #else
        throw LlamaCppError.runtimeMissing
        #endif
    }

    public func unload() async {
        #if canImport(llama)
        _ = try? await onQueue { [self] in
            if let context { llama_free(context) }
            if let model { llama_model_free(model) }
            context = nil
            model = nil
        }
        #endif
    }

    public func generate(system: String, user: String, maxTokens: Int, deadline: Date) async throws -> String {
        try await generate(system: system, user: user, maxTokens: maxTokens, deadline: deadline, sampling: .greedy)
    }

    public func generate(system: String, user: String, maxTokens: Int, deadline: Date,
                         sampling: LlamaSampling) async throws -> String {
        #if canImport(llama)
        return try await onQueue { [self] in
            try run(system: system, user: user, maxTokens: maxTokens, deadline: deadline, sampling: sampling)
        }
        #else
        throw LlamaCppError.runtimeMissing
        #endif
    }

    #if canImport(llama)
    private static let initBackend: Void = {
        llama_backend_init()
        llama_log_set({ _, _, _ in }, nil)   // llama.cpp logs every tensor at load; keep os_log clean
    }()

    private func run(system: String, user: String, maxTokens: Int, deadline: Date, sampling: LlamaSampling) throws -> String {
        guard let model, let context else { throw LlamaCppError.notLoaded }
        let vocab = llama_model_get_vocab(model)
        llama_memory_clear(llama_get_memory(context), true)

        // H14 — ChatML built segment by segment: only the template's own markers are parsed as
        // special tokens; system/user content (screen text, the selection) is tokenized with
        // parse_special off, so a typed "<|im_start|>" stays plain text.
        var tokens: [llama_token] = []
        for (i, seg) in ChatMLSegments.render(system: system, user: user).enumerated() {
            tokens += try Self.tokenize(vocab, seg.text, addSpecial: i == 0, parseSpecial: seg.special)
        }
        let room = Int(contextTokens) - 8
        guard tokens.count < room - 16 else {
            throw LlamaCppError.promptTooLong(tokens: tokens.count, context: Int(contextTokens))
        }
        // Prompt in batch-sized chunks.
        var start = 0
        while start < tokens.count {
            if Date() >= deadline { throw ProviderError.timeout }
            let n = min(Int(batchTokens), tokens.count - start)
            let rc = tokens.withUnsafeMutableBufferPointer { buf in
                llama_decode(context, llama_batch_get_one(buf.baseAddress! + start, Int32(n)))
            }
            if rc != 0 { throw LlamaCppError.decodeFailed(rc) }
            start += n
        }

        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        defer { llama_sampler_free(sampler) }
        if let p = sampling.parameters {
            llama_sampler_chain_add(sampler, llama_sampler_init_penalties(llama_vocab_n_tokens(vocab), p.penaltyLastN,
                                                                          p.repeatPenalty, 0, p.presencePenalty))
            llama_sampler_chain_add(sampler, llama_sampler_init_top_k(p.topK))
            llama_sampler_chain_add(sampler, llama_sampler_init_top_p(p.topP, 1))
            llama_sampler_chain_add(sampler, llama_sampler_init_min_p(p.minP, 1))
            llama_sampler_chain_add(sampler, llama_sampler_init_temp(p.temperature))
            llama_sampler_chain_add(sampler, llama_sampler_init_dist(p.seed))
        } else {
            llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
        }

        var bytes: [UInt8] = []
        let limit = min(maxTokens, room - tokens.count)
        for _ in 0..<max(0, limit) {
            if Date() >= deadline { throw ProviderError.timeout }
            var token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            bytes += Self.piece(vocab, token)
            let rc = llama_decode(context, llama_batch_get_one(&token, 1))
            if rc != 0 { throw LlamaCppError.decodeFailed(rc) }
        }
        tokens.removeAll()
        return String(decoding: bytes, as: UTF8.self)
    }

    static func tokenize(_ vocab: OpaquePointer?, _ text: String, addSpecial: Bool, parseSpecial: Bool) throws -> [llama_token] {
        if text.isEmpty { return [] }
        let count = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(count) + 16)
        var n = llama_tokenize(vocab, text, count, &tokens, Int32(tokens.count), addSpecial, parseSpecial)
        if n < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-n))
            n = llama_tokenize(vocab, text, count, &tokens, Int32(tokens.count), addSpecial, parseSpecial)
        }
        guard n >= 0 else { throw LlamaCppError.tokenizeFailed }
        return Array(tokens.prefix(Int(n)))
    }

    static func piece(_ vocab: OpaquePointer?, _ token: llama_token) -> [UInt8] {
        var buf = [CChar](repeating: 0, count: 64)
        var n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, false)
        if n < 0 {
            buf = [CChar](repeating: 0, count: Int(-n))
            n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, false)
        }
        return n > 0 ? buf.prefix(Int(n)).map { UInt8(bitPattern: $0) } : []
    }
    #endif
}


// MARK: - H14 · ChatML with content kept out of the special-token parser

/// The Qwen-family chat prompt as segments. `special` segments are the template's own markers and
/// are tokenized with parse_special on; content segments (system text that may quote screen
/// context, the user's selection) with it off. Every catalogue model is Qwen-family ChatML, so the
/// template is written out here rather than applied without Jinja. The assistant turn opens with an
/// empty `<think></think>` block: Qwen3.x then answers directly (non-thinking), and
/// `LlamaCppProvider.stripReasoning` removes any think block that still appears.
public enum ChatMLSegments {
    public struct Segment: Equatable, Sendable {
        public var text: String
        public var special: Bool
    }

    public static let emptyThink = "<think>\n\n</think>\n\n"

    public static func render(system: String, user: String, prefillEmptyThink: Bool = true) -> [Segment] {
        [Segment(text: "<|im_start|>system\n", special: true),
         Segment(text: system, special: false),
         Segment(text: "<|im_end|>\n<|im_start|>user\n", special: true),
         Segment(text: user, special: false),
         Segment(text: "<|im_end|>\n<|im_start|>assistant\n" + (prefillEmptyThink ? emptyThink : ""), special: true)]
    }
}
