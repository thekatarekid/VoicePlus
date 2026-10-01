import Foundation

// MARK: - V5 CU4 · Catalogue retrieval (§O-d Layer 2)
//
// Every catalogue phrasing is embedded once (the same on-device sentence encoder as the meeting
// Ask index, M16 — the App adapts `Engine.SentenceEmbedding` to `ActPhraseEmbedding`; Actions does
// not link Engine). Per utterance the top 3 entries by cosine are handed to `ActIntentParser` for a
// fuzzy confirm; a confirm score ≥ 0.8 executes the catalogue action directly. Below that the
// utterance goes to CUA-S1 (one step), and only then to the planner.
//
// Why both: the fuzzy matcher is exact about words and blind to meaning ("shut this tab" ≠ "close
// tab"); the embedding is the reverse. A paraphrase executes only when the two agree.

/// Sentence vectors for retrieval. Need not be normalised; the index normalises.
public protocol ActPhraseEmbedding: Sendable {
    /// Encoder id (reports and logs).
    var name: String { get }
    func embed(_ texts: [String]) async -> [[Float]]
}

/// One retrieved catalogue entry: its closest phrasing and the cosine to the utterance.
public struct CatalogCandidate: Equatable, Sendable {
    public let entry: CatalogEntry
    public let phrasing: String
    public let cosine: Double
}

/// The phrasing index. Built lazily on first use (or `prepare()` at launch), never rebuilt.
public actor CatalogRetrievalIndex {
    public static let topK = 3
    public let catalog: ActionCatalog
    public let embedder: any ActPhraseEmbedding
    private struct Row { let entry: CatalogEntry; let phrasing: String; let vector: [Float] }
    private var rows: [Row]?
    private var building: Task<[Row], Never>?

    public init(catalog: ActionCatalog, embedder: any ActPhraseEmbedding) {
        self.catalog = catalog
        self.embedder = embedder
    }

    /// The text embedded for a phrasing: a template's head ("open url {arg}" → "open url").
    public static func embeddingText(_ phrasing: String) -> String {
        let head = phrasing.hasSuffix("{arg}") ? String(phrasing.dropLast(5)) : phrasing
        return head.replacingOccurrences(of: "{arg}", with: "").trimmingCharacters(in: .whitespaces)
    }

    /// Embed every phrasing once. Idempotent; concurrent callers share one build.
    public func prepare() async {
        _ = await index()
    }

    public var isPrepared: Bool { rows != nil }
    public var phrasingCount: Int { rows?.count ?? 0 }

    private func index() async -> [Row] {
        if let rows { return rows }
        if let building { return await building.value }
        let pairs = catalog.entries.flatMap { e in e.phrasings.map { (e, $0) } }
        let embedder = self.embedder
        let task = Task { () -> [Row] in
            let vectors = await embedder.embed(pairs.map { Self.embeddingText($0.1) })
            guard vectors.count == pairs.count else { return [] }
            return zip(pairs, vectors).map { Row(entry: $0.0, phrasing: $0.1, vector: Self.normalised($1)) }
        }
        building = task
        let built = await task.value
        rows = built
        building = nil
        return built
    }

    /// The `k` best entries for `utterance` (one row per entry: its closest phrasing), best first.
    /// Scoped to `appKind` like the catalogue matcher.
    public func top(_ utterance: String, k: Int = CatalogRetrievalIndex.topK,
                    appKind: ActionCategory? = nil) async -> [CatalogCandidate] {
        let rows = await index()
        guard !rows.isEmpty, let q = await embedder.embed([utterance]).first else { return [] }
        let qn = Self.normalised(q)
        var best: [String: CatalogCandidate] = [:]
        for r in rows where appKind.map(r.entry.applies(to:)) ?? true {
            let c = Double(Self.dot(qn, r.vector))
            if c > (best[r.entry.id]?.cosine ?? -.infinity) {
                best[r.entry.id] = CatalogCandidate(entry: r.entry, phrasing: r.phrasing, cosine: c)
            }
        }
        return best.values.sorted { $0.cosine != $1.cosine ? $0.cosine > $1.cosine : $0.entry.id < $1.entry.id }
            .prefix(max(0, k)).map { $0 }
    }

    /// Cosine of `utterance` to `entry`'s closest phrasing (nil when the entry is not indexed).
    public func cosine(_ utterance: String, entryID: String) async -> Double? {
        let rows = await index().filter { $0.entry.id == entryID }
        guard !rows.isEmpty, let q = await embedder.embed([utterance]).first else { return nil }
        let qn = Self.normalised(q)
        return rows.map { Double(Self.dot(qn, $0.vector)) }.max()
    }

    static func normalised(_ v: [Float]) -> [Float] {
        let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return n > 0 ? v.map { $0 / n } : v
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var s: Float = 0
        for i in a.indices { s += a[i] * b[i] }
        return s
    }
}

/// Feature-hashed unigrams + bigrams (FNV-1a, stable across runs). No model; the deterministic
/// fallback when no sentence encoder is available, and the test embedder.
public struct HashingPhraseEmbedder: ActPhraseEmbedding {
    public let name = "hashing-512"
    public let dimensions: Int
    public init(dimensions: Int = 512) { self.dimensions = dimensions }

    public func embed(_ texts: [String]) async -> [[Float]] { texts.map(vector) }

    public func vector(_ text: String) -> [Float] {
        var v = [Float](repeating: 0, count: dimensions)
        let words = FuzzyMatch.tokens(text).filter { !FuzzyMatch.stopwords.contains($0) }
        func add(_ token: String, _ weight: Float) {
            var h: UInt64 = 1469598103934665603
            for b in token.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
            v[Int(h % UInt64(dimensions))] += weight
        }
        for w in words { add(w, 1) }
        if words.count > 1 { for i in 0..<(words.count - 1) { add(words[i] + " " + words[i + 1], 0.5) } }
        return v
    }
}
