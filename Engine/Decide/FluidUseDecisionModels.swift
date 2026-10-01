import Foundation
import FluidUse
import Shared

// V5 O4 · the three Layer 1 implementations over FluidUse (Apache-2.0), each loaded only through
// `ModelResidency` (§10, HW1).
//
// A `ResidentDecisionModel` is the `DecisionModel` the arbiter calls: every `decide` runs inside
// `residency.withModel(key)`, so the weights load on first use, stay pinned for the call, count against
// the one budget, idle out after 5 min (D5) and are dropped under memory pressure (HW3). The backend
// actor holds the FluidUse manager and nothing else.
//
// Nothing downloads implicitly: `load` reads the FluidUse cache and throws `.notInstalled` when the
// snapshot is missing. `install()` (the user's click in Settings) is the only path that fetches.

/// What a FluidUse family must do: load from the cache, answer, unload.
protocol DecisionBackend: Actor {
    var isLoaded: Bool { get }
    func load() async throws
    func unload()
    func answer(state: String, questions: [DecisionQuestion]) async throws -> DecisionAnswers
}

/// A decision model that lives in `ModelResidency`.
public final class ResidentDecisionModel: DecisionModel, @unchecked Sendable {
    public let choice: DecisionModelChoice
    public var id: String { choice.rawValue }
    public let residencyKey: String
    private let residency: ModelResidency
    private let backend: any DecisionBackend

    init(choice: DecisionModelChoice, backend: any DecisionBackend, residency: ModelResidency) {
        self.choice = choice
        self.residencyKey = choice.residencyKey
        self.backend = backend
        self.residency = residency
    }

    /// The FluidUse-backed model for `choice`, reading weights from `cacheDirectory` (default: the
    /// FluidUse cache under Application Support).
    public static func fluidUse(_ choice: DecisionModelChoice, residency: ModelResidency = .shared,
                                cacheDirectory: URL? = nil) -> ResidentDecisionModel {
        let root = cacheDirectory ?? LayaModelStore.defaultCacheDirectory()
        let backend: any DecisionBackend
        switch choice {
        case .kev: backend = KevBackend(root: root)
        case .intern: backend = InternBackend(root: root)
        case .laya: backend = LayaBackend(root: root)
        }
        return ResidentDecisionModel(choice: choice, backend: backend, residency: residency)
    }

    /// HW1 — register with the residency under the plan's tier (HW2) and lighter alternative (HW3).
    public func register(plan: ResidencyPlan) async {
        let tier: ResidencyTier = choice.residencyKey == plan.decisionKey
            ? (plan.tier(for: .decision) ?? .onDemand) : .onDemand
        let backend = self.backend
        await residency.register(residencyKey, tier: tier, estimatedBytes: choice.estimatedBytes,
                                 lighterAlternative: plan.lighterAlternative(for: residencyKey),
                                 owner: DecisionModelRegistry.owner,
                                 load: { try await backend.load() },
                                 unload: { await backend.unload() })
    }

    public func decide(state: String, questions: [DecisionQuestion]) async throws -> DecisionAnswers {
        let backend = self.backend
        return try await residency.withModel(residencyKey) {
            try await backend.answer(state: state, questions: questions)
        }
    }
}

/// The decision models of one app: registers the chosen model and its lighter alternative, and hands
/// the arbiter whichever one the residency currently prefers (HW3 swap).
public final class DecisionModelRegistry: @unchecked Sendable {
    public static let owner = "decide"
    private let residency: ModelResidency
    private let lock = NSLock()
    private var models: [String: any DecisionModel] = [:]
    private var chosenKey: String

    public init(residency: ModelResidency = .shared, chosen: DecisionModelChoice) {
        self.residency = residency
        self.chosenKey = chosen.residencyKey
    }

    /// Registers `choice` (and, when the plan has one, its lighter alternative) with the residency.
    /// `make` builds a model for a choice (FluidUse in the app, a mock in tests).
    public func install(_ choice: DecisionModelChoice, plan: ResidencyPlan,
                        make: (DecisionModelChoice) -> ResidentDecisionModel) async {
        var choices = [choice]
        if let lighter = plan.lighterAlternative(for: choice.residencyKey),
           let c = DecisionModelChoice(residencyKey: lighter) { choices.append(c) }
        for c in choices {
            let m = make(c)
            await m.register(plan: plan)
            lock.withLock { models[c.residencyKey] = m }
        }
        lock.withLock { chosenKey = choice.residencyKey }
    }

    /// Adds an already-built model (tests, or a model registered elsewhere).
    public func add(_ model: any DecisionModel, key: String, chosen: Bool = false) {
        lock.withLock {
            models[key] = model
            if chosen { chosenKey = key }
        }
    }

    /// The model to ask now: the residency's preferred key for the chosen one (Laya under critical
    /// pressure), falling back to the chosen model if the lighter one is not registered here.
    public func current() async -> (any DecisionModel)? {
        let chosen = lock.withLock { chosenKey }
        let preferred = await residency.preferredKey(for: chosen)
        return lock.withLock { models[preferred] ?? models[chosen] }
    }
}

// MARK: - FluidUse families

/// Maps a two-way answer (`false/true` or `no/yes`) onto `no`/`yes`.
private func yesNo(_ labels: [String], _ probs: [Float]) -> [String: Double] {
    var out: [String: Double] = [:]
    for (l, p) in zip(labels, probs) {
        switch l {
        case "true", "yes": out["yes"] = Double(p)
        case "false", "no": out["no"] = Double(p)
        default: out[l] = Double(p)
        }
    }
    return out
}

private func cached(_ dir: URL, _ marker: String) -> Bool {
    FileManager.default.fileExists(atPath: dir.appendingPathComponent(marker).path)
}

@available(macOS 15.0, *)
actor KevBackend: DecisionBackend {
    let directory: URL
    private var manager: KevFastManager?
    init(root: URL) { directory = root.appendingPathComponent("kev-0.8b-coreml", isDirectory: true) }

    var isLoaded: Bool { manager != nil }

    func load() async throws {
        if manager != nil { return }
        guard cached(directory, "fused/config.json"), cached(directory, "tokenizer.json") else {
            throw DecisionModelError.notInstalled("kev")
        }
        manager = try await KevFastManager.load(from: directory)
    }

    func unload() { manager = nil }

    func answer(state: String, questions: [DecisionQuestion]) async throws -> DecisionAnswers {
        if manager == nil { try await load() }
        guard let manager else { throw DecisionModelError.notInstalled("kev") }
        let kq: [KevQuestion] = questions.map { q in
            switch q.kind {
            case .yesNo: return .noul(q.instruction)
            case .choice:
                return .choice(q.instruction, options: DecisionQuestion.capabilityOptions.map { ($0.key, $0.description) })
            }
        }
        let answers = try await manager.answer(state: state, questions: kq,
                                               maxStateTokens: DecisionStateRenderer.defaultMaxTokens)
        guard answers.count == questions.count else { throw DecisionModelError.invalidOutput("kev") }
        var out = DecisionAnswers()
        for (q, a) in zip(questions, answers) {
            out.distributions[q] = q.kind == .yesNo ? yesNo(a.keys, a.probabilities)
                : Dictionary(uniqueKeysWithValues: zip(a.keys, a.probabilities.map(Double.init)))
        }
        return out
    }
}

actor InternBackend: DecisionBackend {
    let directory: URL
    private var manager: InternDecisionManager?
    init(root: URL) { directory = root.appendingPathComponent(InternDecisionModel.stock.rawValue, isDirectory: true) }

    var isLoaded: Bool { manager != nil }

    func load() async throws {
        if manager != nil { return }
        guard cached(directory, "config.json"), cached(directory, "tokenizer.json") else {
            throw DecisionModelError.notInstalled("intern")
        }
        manager = try await InternDecisionManager.load(from: directory)
    }

    func unload() { manager = nil }

    func answer(state: String, questions: [DecisionQuestion]) async throws -> DecisionAnswers {
        if manager == nil { try await load() }
        guard let manager else { throw DecisionModelError.notInstalled("intern") }
        let iq: [(name: String, question: InternDecisionQuestion)] = questions.map { q in
            switch q.kind {
            case .yesNo: return (q.rawValue, .noul(q.instruction))
            case .choice:
                return (q.rawValue, .choice(q.instruction,
                                            options: DecisionQuestion.capabilityOptions.map { ($0.key, $0.description) }))
            }
        }
        let result = try await manager.decide(state: .object([(key: "context", value: .string(state))]), questions: iq)
        guard result.answers.count == questions.count else { throw DecisionModelError.invalidOutput("intern") }
        var out = DecisionAnswers()
        for (q, a) in zip(questions, result.answers) {
            out.distributions[q] = q.kind == .yesNo ? yesNo(a.labels, a.probabilities)
                : Dictionary(uniqueKeysWithValues: zip(a.labels, a.probabilities.map(Double.init)))
        }
        return out
    }
}

actor LayaBackend: DecisionBackend {
    let directory: URL
    private var manager: LayaManager?
    static let configuration = LayaManager.Configuration(lengths: [128, 512], precision: "e8")
    init(root: URL) { directory = root.appendingPathComponent("laya-coreml", isDirectory: true) }

    var isLoaded: Bool { manager != nil }

    func load() async throws {
        if manager != nil { return }
        guard cached(directory, LayaModelStore.tokenizerFile) else { throw DecisionModelError.notInstalled("laya") }
        manager = try await LayaManager.load(from: directory, configuration: Self.configuration)
    }

    func unload() { manager = nil }

    func answer(state: String, questions: [DecisionQuestion]) async throws -> DecisionAnswers {
        if manager == nil { try await load() }
        guard let manager else { throw DecisionModelError.notInstalled("laya") }
        let lq: [LayaQuestion] = questions.map { q in
            switch q.kind {
            case .yesNo: return .noul(q.instruction)
            case .choice:
                return .choice(q.instruction, options: DecisionQuestion.capabilityOptions.map {
                    LayaQuestion.Choice($0.key, description: $0.description)
                })
            }
        }
        let answers = try await manager.answer(state: state, questions: lq)
        guard answers.count == questions.count else { throw DecisionModelError.invalidOutput("laya") }
        var out = DecisionAnswers()
        for (q, a) in zip(questions, answers) {
            out.distributions[q] = q.kind == .yesNo ? yesNo(a.question.labels, a.probabilities)
                : Dictionary(uniqueKeysWithValues: zip(a.question.labels, a.probabilities.map(Double.init)))
        }
        return out
    }
}

// MARK: - Install (explicit user action only)

public enum DecisionModelInstaller {
    /// Whether `choice`'s snapshot is already in the FluidUse cache (no network).
    public static func isInstalled(_ choice: DecisionModelChoice, cacheDirectory: URL? = nil) -> Bool {
        let root = cacheDirectory ?? LayaModelStore.defaultCacheDirectory()
        switch choice {
        case .kev:
            let d = root.appendingPathComponent("kev-0.8b-coreml")
            return cached(d, "fused/config.json") && cached(d, "tokenizer.json")
        case .intern:
            let d = root.appendingPathComponent(InternDecisionModel.stock.rawValue)
            return cached(d, "config.json") && cached(d, "tokenizer.json")
        case .laya:
            return cached(root.appendingPathComponent("laya-coreml"), LayaModelStore.tokenizerFile)
        }
    }

    /// Downloads `choice`'s pinned, checksummed snapshot. Call only from the user's click (Settings).
    public static func install(_ choice: DecisionModelChoice, cacheDirectory: URL? = nil) async throws {
        switch choice {
        case .kev: _ = try await KevModelStore.ensure(cacheDirectory: cacheDirectory)
        case .intern: _ = try await InternDecisionModelStore.ensure(.stock, cacheDirectory: cacheDirectory)
        case .laya:
            _ = try await LayaModelStore.ensure(lengths: LayaBackend.configuration.lengths,
                                                precision: LayaBackend.configuration.precision,
                                                cacheDirectory: cacheDirectory)
        }
    }
}
