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

    public init(modelPath: URL, residencyKey: String = "cleanup.llm", tier: ResidencyTier = .onDemand,
                estimatedBytes: Int64 = 700_000_000, maxTokens: Int? = nil, deadline: TimeInterval = 0.5,
                lighterAlternative: String? = nil) {
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
        guard await isAvailable() else { throw ProviderError.unavailable("llama.cpp model not installed") }
        await registerWithResidency()
        let deadline = Date().addingTimeInterval(config.deadline)
        let maxTokens = config.maxTokens ?? Self.derivedMaxTokens(forCharacters: prompt.count)
        let engine = self.engine
        let text: String
        do {
            text = try await residency.withModel(config.residencyKey) {
                try await engine.generate(system: system, user: prompt, maxTokens: maxTokens, deadline: deadline)
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
        #if canImport(llama)
        return try await onQueue { [self] in try run(system: system, user: user, maxTokens: maxTokens, deadline: deadline) }
        #else
        throw LlamaCppError.runtimeMissing
        #endif
    }

    #if canImport(llama)
    private static let initBackend: Void = {
        llama_backend_init()
        llama_log_set({ _, _, _ in }, nil)   // llama.cpp logs every tensor at load; keep os_log clean
    }()

    private func run(system: String, user: String, maxTokens: Int, deadline: Date) throws -> String {
        guard let model, let context else { throw LlamaCppError.notLoaded }
        let vocab = llama_model_get_vocab(model)
        let prompt = Self.chatPrompt(model: model, system: system, user: user)
        llama_memory_clear(llama_get_memory(context), true)

        var tokens = try Self.tokenize(vocab, prompt)
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
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())

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

    /// The model's own chat template (ChatML for the Qwen family); hand-written ChatML when the
    /// template is not one llama.cpp knows without Jinja.
    static func chatPrompt(model: OpaquePointer, system: String, user: String) -> String {
        let roles = [strdup("system"), strdup("user")]
        let contents = [strdup(system), strdup(user)]
        defer { (roles + contents).forEach { free($0) } }
        var messages = [llama_chat_message(role: roles[0], content: contents[0]),
                        llama_chat_message(role: roles[1], content: contents[1])]
        let template = llama_model_chat_template(model, nil)
        var size = Int32(2 * (system.utf8.count + user.utf8.count) + 512)
        for _ in 0..<2 {
            var buf = [CChar](repeating: 0, count: Int(size))
            let n = llama_chat_apply_template(template, &messages, messages.count, true, &buf, size)
            if n < 0 { break }
            if n <= size { return String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self) }
            size = n + 1
        }
        return "<|im_start|>system\n\(system)<|im_end|>\n<|im_start|>user\n\(user)<|im_end|>\n<|im_start|>assistant\n"
    }

    static func tokenize(_ vocab: OpaquePointer?, _ text: String) throws -> [llama_token] {
        let count = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(count) + 16)
        var n = llama_tokenize(vocab, text, count, &tokens, Int32(tokens.count), true, true)
        if n < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-n))
            n = llama_tokenize(vocab, text, count, &tokens, Int32(tokens.count), true, true)
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
