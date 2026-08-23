import Foundation

/// Token-id trie over the ranked bias list. Each node stores the best entry weight passing
/// through it so a partial match is boosted proportionally, and `terminalWeight` marks entry ends.
public struct BiasPrefixTree: Sendable {
    public struct Node: Sendable {
        public var children: [Int: Int] = [:]   // tokenId → node index
        public var weight: Float = 0             // max entry weight through this node
        public var terminalWeight: Float = 0     // > 0 if an entry ends here
        public var depth: Int = 0
    }

    public private(set) var nodes: [Node] = [Node()]
    public private(set) var entryCount = 0
    public private(set) var skipped: [String] = []   // entries the vocab couldn't encode

    public static let root = 0

    public init() {}

    public init(entries: [BiasEntry], vocabulary: BiasVocabulary) {
        self.init()
        for e in entries {
            guard let ids = vocabulary.encode(e.text) else { skipped.append(e.text); continue }
            insert(ids, weight: e.weight)
        }
    }

    public mutating func insert(_ tokenIds: [Int], weight: Float = 1) {
        guard !tokenIds.isEmpty else { return }
        var cur = Self.root
        for id in tokenIds {
            if let next = nodes[cur].children[id] {
                cur = next
            } else {
                var n = Node(); n.depth = nodes[cur].depth + 1
                nodes.append(n)
                nodes[cur].children[id] = nodes.count - 1
                cur = nodes.count - 1
            }
            nodes[cur].weight = max(nodes[cur].weight, weight)
        }
        nodes[cur].terminalWeight = max(nodes[cur].terminalWeight, weight)
        entryCount += 1
    }

    public func child(of node: Int, token: Int) -> Int? { nodes[node].children[token] }
    public func isTerminal(_ node: Int) -> Bool { nodes[node].terminalWeight > 0 }
    public func depth(of node: Int) -> Int { nodes[node].depth }
    public func weight(of node: Int) -> Float { nodes[node].weight }

    /// Match state after consuming `tokenIds` from the root, restarting at the root after a
    /// complete entry or on divergence (so a new entity can begin on any later token).
    public func state(after tokenIds: [Int]) -> Int {
        var cur = Self.root
        for id in tokenIds { cur = advance(cur, token: id) }
        return cur
    }

    /// One step: follow the child, else fall back to root (retrying the token from root).
    public func advance(_ node: Int, token: Int) -> Int {
        if let n = child(of: node, token: token) { return n }
        if node != Self.root, let n = child(of: Self.root, token: token) { return n }
        return Self.root
    }
}
