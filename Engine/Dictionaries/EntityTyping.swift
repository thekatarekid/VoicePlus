import Foundation
import Shared
import FluidUse

/// V5 P7 — what kind of thing a context entity is. Carried beside the `.screen` tier term so the
/// cleanup prompt can say "Priya (person)", "Linear (product)".
public enum EntityType: String, Sendable, CaseIterable, Codable {
    case person
    case organization
    case product
    case place
    case technology
    case other

    /// The label text a zero-shot classifier sees.
    public var label: String {
        switch self {
        case .person: return "person"
        case .organization: return "organization"
        case .product: return "product or app"
        case .place: return "place"
        case .technology: return "technology or code"
        case .other: return "other"
        }
    }
}

/// Types candidate entities found in context text.
///
/// `cachedType` is synchronous (harvest is synchronous); `prepare` does the expensive work off the
/// harvest path and fills the cache for the next harvest.
public protocol EntityTypeClassifier: Sendable {
    var isAvailable: Bool { get }
    func cachedType(for candidate: String) -> EntityType?
    func prepare(_ candidates: [String], context: String) async
}

/// Process-wide term → type map the screen-context consumers read (`RankedContextTerm.entityType`).
public final class EntityTypeRegistry: @unchecked Sendable {
    public static let shared = EntityTypeRegistry()
    private let lock = NSLock()
    private var types: [String: EntityType] = [:]
    public init() {}
    public func set(_ type: EntityType, for term: String) { lock.withLock { types[term.lowercased()] = type } }
    public func type(of term: String) -> EntityType? { lock.withLock { types[term.lowercased()] } }
    public func removeAll() { lock.withLock { types.removeAll() } }
}

public extension RankedContextTerm {
    /// V5 P7 — the entity type `TypedEntitySource` found for this term, if any.
    var entityType: EntityType? { EntityTypeRegistry.shared.type(of: text) }
}

/// Deterministic typing from shape and the local name lists (no model): contact → person, app →
/// product, corporate suffix → organization, code-shaped → technology. The fallback whenever no
/// model is loaded, and the prior a model's answer must beat.
public struct HeuristicEntityTyper: EntityTypeClassifier, Sendable {
    public var people: Set<String>
    public var products: Set<String>
    public init(people: [String] = [], products: [String] = []) {
        self.people = Set(people.map { $0.lowercased() })
        self.products = Set(products.map { $0.lowercased() })
    }

    public var isAvailable: Bool { true }
    public func prepare(_ candidates: [String], context: String) async {}

    static let orgSuffixes = ["inc", "inc.", "ltd", "ltd.", "llc", "corp", "corp.", "gmbh", "ag", "labs", "university", "foundation", "bank", "group"]

    public func cachedType(for candidate: String) -> EntityType? {
        let lower = candidate.lowercased()
        if people.contains(lower) || lower.split(separator: " ").contains(where: { people.contains(String($0)) }) { return .person }
        if products.contains(lower) { return .product }
        if let last = lower.split(separator: " ").last, Self.orgSuffixes.contains(String(last)) { return .organization }
        if candidate.contains(where: { $0.isNumber || $0 == "_" || $0 == "." || $0 == "-" }) { return .technology }
        let letters = candidate.filter(\.isLetter)
        if candidate.dropFirst().contains(where: \.isUppercase), candidate.contains(where: \.isLowercase), !candidate.contains(" ") {
            return .technology // camelCase / PascalCase identifiers
        }
        if letters.count >= 2, letters.allSatisfy(\.isUppercase) { return .organization } // acronyms
        return nil
    }
}

/// Model answer first, heuristic second.
public struct LayeredEntityTyper: EntityTypeClassifier {
    public let model: EntityTypeClassifier?
    public let heuristic: HeuristicEntityTyper
    public init(model: EntityTypeClassifier?, heuristic: HeuristicEntityTyper) {
        self.model = model
        self.heuristic = heuristic
    }
    public var isAvailable: Bool { true }
    public func cachedType(for candidate: String) -> EntityType? {
        if let model, model.isAvailable, let t = model.cachedType(for: candidate) { return t }
        return heuristic.cachedType(for: candidate)
    }
    public func prepare(_ candidates: [String], context: String) async {
        guard let model, model.isAvailable else { return }
        await model.prepare(candidates.filter { heuristic.cachedType(for: $0) == nil }, context: context)
    }
}

/// V5 P7 — GLiNER2-small (Core ML, FluidUse, Apache-2.0) as a zero-shot entity typer: each
/// candidate (found by `EntityExtractor`) is classified among `EntityType` labels with a snippet of
/// its context. FluidUse's published GLiNER2 packages are classification heads, not span
/// extractors, so candidates come from the extractor and the model decides the type.
///
/// Loads only from weights already on disk (never downloads on its own) and only once asked;
/// until then `isAvailable` is false and the heuristic answers. §10: when `ModelResidency` (HW1)
/// lands, `load` moves behind it — it is the single place this file touches Core ML.
public final class GLiNER2EntityTyper: EntityTypeClassifier, @unchecked Sendable {
    public typealias Classify = @Sendable (_ text: String, _ labels: [String]) async throws -> (label: String, probability: Float)

    private let lock = NSLock()
    private var cache: [String: EntityType] = [:]
    private var classify: Classify?
    public let minProbability: Float

    /// Injected classifier (tests, or a residency-managed model).
    public init(classify: Classify?, minProbability: Float = 0.5) {
        self.classify = classify
        self.minProbability = minProbability
    }

    /// Where FluidUse keeps the small variant's weights.
    public static func defaultDirectory() -> URL {
        LayaModelStore.defaultCacheDirectory().appendingPathComponent("gliner2-5-small-coreml")
    }

    public static func weightsPresent(at directory: URL = defaultDirectory()) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(GLiNER2Variant.small.packageName).path)
            || FileManager.default.fileExists(atPath: directory.appendingPathComponent(
                GLiNER2Variant.small.packageName.replacingOccurrences(of: ".mlpackage", with: ".mlmodelc")).path)
    }

    /// Loads GLiNER2-small from `directory` when its weights are there; nil otherwise.
    public static func load(from directory: URL = defaultDirectory()) async -> GLiNER2EntityTyper? {
        guard weightsPresent(at: directory),
              let manager = try? await GLiNER2Manager.load(from: directory, variant: .small) else { return nil }
        return GLiNER2EntityTyper(classify: { text, labels in
            let answer = try await manager.classify(text: text, task: "entity type", labels: labels)
            return (answer.selectedLabel, answer.probabilities[answer.selectedIndex])
        })
    }

    public var isAvailable: Bool { lock.withLock { classify != nil } }

    public func cachedType(for candidate: String) -> EntityType? { lock.withLock { cache[candidate.lowercased()] } }

    public func prepare(_ candidates: [String], context: String) async {
        guard let classify = lock.withLock({ classify }) else { return }
        let labels = EntityType.allCases.filter { $0 != .other }.map(\.label)
        for candidate in candidates where cachedType(for: candidate) == nil {
            let snippet = Self.snippet(around: candidate, in: context)
            guard let answer = try? await classify("\(candidate): \(snippet)", labels),
                  answer.probability >= minProbability,
                  let type = EntityType.allCases.first(where: { $0.label == answer.label }) else { continue }
            lock.withLock { cache[candidate.lowercased()] = type }
        }
    }

    /// ≤ 160 characters of context centred on the candidate (the model's window is 128 tokens).
    static func snippet(around candidate: String, in context: String, radius: Int = 70) -> String {
        guard let range = context.range(of: candidate) else { return String(context.prefix(2 * radius)) }
        let start = context.index(range.lowerBound, offsetBy: -radius, limitedBy: context.startIndex) ?? context.startIndex
        let end = context.index(range.upperBound, offsetBy: radius, limitedBy: context.endIndex) ?? context.endIndex
        return String(context[start..<end])
    }
}

/// V5 P7 — entity terms from context text into the `.screen` tier, typed. Candidates are
/// `EntityExtractor`'s entity-strength terms; each is typed by the classifier (model when loaded,
/// heuristic otherwise) and recorded in `EntityTypeRegistry`. Screen text is data, never
/// instructions: nothing here acts on what it reads.
public final class TypedEntitySource: ContextSource, @unchecked Sendable {
    public let kind = ContextSourceKind.axTree
    private let text: FocusedWindowTextProvider
    private let classifier: EntityTypeClassifier
    private let registry: EntityTypeRegistry
    public static let maxCandidates = 64

    public init(text: FocusedWindowTextProvider, classifier: EntityTypeClassifier,
                registry: EntityTypeRegistry = .shared) {
        self.text = text
        self.classifier = classifier
        self.registry = registry
    }

    public func harvest(now: Date) -> [ContextEntry] {
        let strings = text.visibleStrings()
        guard !strings.isEmpty else { return [] }
        let context = strings.map(\.0).joined(separator: "\n")
        let candidates = Array(EntityExtractor.extract(from: context).prefix(Self.maxCandidates))
        var out: [ContextEntry] = []
        var untyped: [String] = []
        for candidate in candidates {
            guard let type = classifier.cachedType(for: candidate) else { untyped.append(candidate); continue }
            registry.set(type, for: candidate)
            out.append(ContextEntry(text: candidate, source: .axTree, observedAt: now, salience: Self.salience(type)))
        }
        if !untyped.isEmpty, classifier.isAvailable {
            let classifier = classifier
            Task.detached(priority: .utility) { await classifier.prepare(untyped, context: context) }
        }
        return out
    }

    /// People, organisations and products are what dictation misspells; "other" ranks lowest.
    static func salience(_ type: EntityType) -> Double {
        switch type {
        case .person, .organization, .product: return 0.9
        case .technology, .place: return 0.75
        case .other: return 0.5
        }
    }
}
