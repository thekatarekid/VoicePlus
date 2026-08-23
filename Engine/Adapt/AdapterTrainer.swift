import Foundation
import Shared

/// What the learner produces: weighted personal vocabulary + misheard→correct variant map.
public struct PersonalLexicon: Codable, Equatable, Sendable {
    public struct Term: Codable, Equatable, Sendable {
        public var text: String
        /// 0…1, saturating with the number of corrections (never forgets).
        public var weight: Double
        public var corrections: Int
        public var lastSeen: Date
    }
    public struct Variant: Codable, Equatable, Sendable {
        /// Lowercased misheard form as the decoder produced it.
        public var heard: String
        public var corrected: String
        public var count: Int
    }

    public var terms: [String: Term] = [:]        // keyed by lowercased text
    public var variants: [String: Variant] = [:]  // keyed by lowercased heard form
    public var trainedAt: Date = .distantPast
    public var pairCount = 0

    public init() {}

    public func weight(of term: String) -> Double { terms[term.lowercased()]?.weight ?? 0 }

    /// Entries for the Biasing `Ranker` (source `.corrections`, timeless, salience = weight).
    public func contextEntries() -> [ContextEntry] {
        terms.values.map { ContextEntry(text: $0.text, source: .corrections, observedAt: $0.lastSeen, salience: $0.weight) }
    }
}

public enum AdapterFeasibility: String, Codable, Sendable { case trained, infeasible }

/// Output of any trainer; the Lab records `decision` into a `LabRunRecord`.
public struct AdapterTrainingResult: Codable, Sendable {
    public var backend: String
    public var feasibility: AdapterFeasibility
    public var lexicon: PersonalLexicon
    public var decision: String
    public var durationMs: Double

    public func labRunRecord(hardware: String = ProcessInfo.processInfo.hostName, started: Date = Date()) -> LabRunRecord {
        let metrics: [String: Any] = ["feasibility": feasibility.rawValue, "terms": lexicon.terms.count, "variants": lexicon.variants.count,
                                      "pairs": lexicon.pairCount, "durationMs": durationMs, "decision": decision]
        let config = ["backend": backend]
        func json(_ v: Any) -> String { (try? JSONSerialization.data(withJSONObject: v)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}" }
        return LabRunRecord(startedAt: started, finishedAt: Date(), name: "adapt.train.\(backend)", configJSON: json(config), metricsJSON: json(metrics), hardware: hardware)
    }
}

public protocol AdapterTrainer: Sendable {
    var name: String { get }
    func train(pairs: [TrainingPair], previous: PersonalLexicon?) -> AdapterTrainingResult
}

/// Default backend: learns weighted personal vocabulary + pronunciation-variant mapping from
/// pairs. Weight saturates as `1 - exp(-n / k)`; multi-word corrections contribute each
/// entity-like word as well as the phrase.
public struct BiasListLearner: AdapterTrainer {
    public let name = "biasList"
    public var saturation: Double
    public init(saturation: Double = 2) { self.saturation = max(0.1, saturation) }

    public func train(pairs: [TrainingPair], previous: PersonalLexicon? = nil) -> AdapterTrainingResult {
        let t0 = Date()
        var lex = PersonalLexicon()
        for p in pairs.sorted(by: { $0.createdAt < $1.createdAt }) {
            let corrected = p.corrected.trimmingCharacters(in: .whitespacesAndNewlines)
            let heard = p.original.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !corrected.isEmpty else { continue }
            var candidates = [corrected]
            let words = corrected.split(separator: " ").map(String.init)
            if words.count > 1 { candidates += words.filter { EntityExtractor.isEntityLike($0) || $0.count >= 4 } }
            for c in candidates {
                let k = c.lowercased()
                var t = lex.terms[k] ?? .init(text: c, weight: 0, corrections: 0, lastSeen: p.createdAt)
                t.corrections += 1; t.lastSeen = max(t.lastSeen, p.createdAt)
                t.weight = 1 - exp(-Double(t.corrections) / saturation)
                if c.first?.isUppercase == true { t.text = c }
                lex.terms[k] = t
            }
            if !heard.isEmpty, heard.lowercased() != corrected.lowercased() {
                let hk = heard.lowercased()
                var v = lex.variants[hk] ?? .init(heard: hk, corrected: corrected, count: 0)
                // Most recent correction wins if the user changed their mind.
                v.count += 1; v.corrected = corrected
                lex.variants[hk] = v
            }
            lex.pairCount += 1
        }
        lex.trainedAt = Date()
        return AdapterTrainingResult(backend: name, feasibility: .trained, lexicon: lex,
                                     decision: "bias-list learning: \(lex.terms.count) terms, \(lex.variants.count) variants from \(pairs.count) pairs",
                                     durationMs: Date().timeIntervalSince(t0) * 1000)
    }
}

/// LoRA-style adapter fine-tune on the decoder/joint network. Interface only: on-device
/// training is infeasible with the frozen CoreML runtime (no backward pass, no trainable
/// weights exported by the FluidAudio fork), so the Lab records an `infeasible` decision and
/// the app falls back to `BiasListLearner`.
public struct LoRAAdapterStub: AdapterTrainer {
    public let name = "lora"
    public var rank: Int
    public init(rank: Int = 8) { self.rank = rank }

    public static let infeasibilityReason = "LoRA fine-tune infeasible on-device: CoreML decoder/joint are compiled inference-only graphs (no gradients); FluidAudio exports no trainable weights; fallback = biasList"

    public func train(pairs: [TrainingPair], previous: PersonalLexicon? = nil) -> AdapterTrainingResult {
        AdapterTrainingResult(backend: name, feasibility: .infeasible, lexicon: previous ?? PersonalLexicon(),
                              decision: "\(Self.infeasibilityReason); rank=\(rank); pairs=\(pairs.count)", durationMs: 0)
    }
}

/// Picks the backend the Lab decided on (LoRA if ever feasible, else bias list) and persists
/// the lexicon as JSON under the store root.
public final class AdaptationLoop: @unchecked Sendable {
    public let store: TrainingPairStore
    public let trainers: [AdapterTrainer]
    public private(set) var lexicon: PersonalLexicon
    public private(set) var lastResults: [AdapterTrainingResult] = []
    private var file: URL { store.root.appendingPathComponent("lexicon.json") }
    private let lock = NSLock()

    public init(store: TrainingPairStore, trainers: [AdapterTrainer] = [LoRAAdapterStub(), BiasListLearner()]) {
        self.store = store; self.trainers = trainers
        let file = store.root.appendingPathComponent("lexicon.json")
        lexicon = (try? Data(contentsOf: file)).flatMap { d in let j = JSONDecoder(); j.dateDecodingStrategy = .iso8601; return try? j.decode(PersonalLexicon.self, from: d) } ?? PersonalLexicon()
    }

    /// Runs every backend; the first that reports `.trained` wins. Returns all results so the
    /// Lab can log the infeasible decisions too.
    @discardableResult
    public func retrain() -> [AdapterTrainingResult] {
        let pairs = store.all()
        var results: [AdapterTrainingResult] = []
        for t in trainers {
            let r = t.train(pairs: pairs, previous: lexicon)
            results.append(r)
            if r.feasibility == .trained {
                lock.lock(); lexicon = r.lexicon; lock.unlock()
                let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
                try? enc.encode(r.lexicon).write(to: file)
                break
            }
        }
        lock.lock(); lastResults = results; lock.unlock()
        return results
    }
}

/// Feeds the learned lexicon into the Biasing ranker.
public final class LearnedLexiconSource: ContextSource, @unchecked Sendable {
    public let kind = ContextSourceKind.corrections
    private let loop: AdaptationLoop
    public init(loop: AdaptationLoop) { self.loop = loop }
    public func harvest(now: Date) -> [ContextEntry] { loop.lexicon.contextEntries() }
}
