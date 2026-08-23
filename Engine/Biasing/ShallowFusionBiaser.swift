import Foundation

/// Tunables for shallow fusion. Defaults tuned on the synthetic suite; the Lab sweeps them.
public struct BiasingConfig: Sendable, Equatable {
    /// Log-prob bonus per matched token (scaled by entry weight).
    public var boostPerToken: Float = 2.0
    /// Extra bonus when a token completes an entry (rewards finishing the entity).
    public var completionBonus: Float = 1.0
    /// Partial-match unbiasing: when at depth d and a candidate leaves the trie, penalise it by
    /// `unboostFactor × d × boostPerToken` so the boost already granted is taken back (NGPU-LM style).
    public var unboostFactor: Float = 1.0
    /// Hard clamp on |bonus| per candidate — the false-insertion guard: a candidate the acoustics
    /// rank far below the best can never be promoted by bias alone.
    public var maxBoost: Float = 4.0
    /// Minimum entry weight to receive any boost.
    public var minWeight: Float = 0.05
    public init() {}
}

/// `LogitBiaser` over a `BiasPrefixTree`: boosts candidates that extend the current
/// trie path (or start a new entry), penalises candidates that abandon a partial match.
public final class ShallowFusionBiaser: LogitBiaser, @unchecked Sendable {
    public let tree: BiasPrefixTree
    public let config: BiasingConfig
    private let lock = NSLock()
    // Cache of the last prefix → trie state so per-step cost is O(1) in the common case.
    private var cachedCount = 0
    private var cachedState = BiasPrefixTree.root
    private var cachedLastId: Int? = nil
    public private(set) var callCount = 0
    public private(set) var totalNanos: UInt64 = 0

    public init(tree: BiasPrefixTree, config: BiasingConfig = BiasingConfig()) {
        self.tree = tree
        self.config = config
    }

    public convenience init(entries: [BiasEntry], vocabulary: BiasVocabulary, config: BiasingConfig = BiasingConfig()) {
        self.init(tree: BiasPrefixTree(entries: entries, vocabulary: vocabulary), config: config)
    }

    public func boost(tokenIds: [Int], prefixState: PrefixState) -> [Int: Float] {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let node = state(for: prefixState.tokenIds)
        var out: [Int: Float] = [:]
        let depth = tree.depth(of: node)
        for id in tokenIds {
            var bonus: Float = 0
            if let next = tree.child(of: node, token: id) {
                let w = tree.weight(of: next)
                if w >= config.minWeight {
                    bonus = config.boostPerToken * w
                    if tree.isTerminal(next) { bonus += config.completionBonus * w }
                }
            } else if depth > 0, !tree.isTerminal(node) {
                // Leaving the trie mid-entry: take back what was granted.
                bonus = -config.unboostFactor * Float(depth) * config.boostPerToken * tree.weight(of: node)
            } else if let fresh = tree.child(of: BiasPrefixTree.root, token: id), node != BiasPrefixTree.root {
                let w = tree.weight(of: fresh)
                if w >= config.minWeight { bonus = config.boostPerToken * w }
            }
            bonus = min(max(bonus, -config.maxBoost), config.maxBoost)
            if bonus != 0 { out[id] = bonus }
        }
        lock.withLock {
            callCount += 1
            totalNanos &+= DispatchTime.now().uptimeNanoseconds &- t0
        }
        return out
    }

    /// Mean microseconds per `boost` call (Lab: added latency).
    public var meanMicrosPerCall: Double {
        lock.withLock { callCount == 0 ? 0 : Double(totalNanos) / Double(callCount) / 1_000 }
    }

    private func state(for ids: [Int]) -> Int {
        lock.lock(); defer { lock.unlock() }
        if ids.count == cachedCount, ids.last == cachedLastId { return cachedState }
        let s: Int
        if ids.count == cachedCount + 1, ids.dropLast().last == cachedLastId || cachedCount == 0 {
            s = tree.advance(cachedState, token: ids[ids.count - 1])
        } else {
            s = tree.state(after: ids)
        }
        cachedCount = ids.count; cachedLastId = ids.last; cachedState = s
        return s
    }
}
