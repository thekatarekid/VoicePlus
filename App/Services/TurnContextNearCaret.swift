import Foundation
import Injection
import Shared

// MARK: - H21 — the turn snapshot reads outward from the caret first
//
// The N7 window walk is top-down under ~800 nodes: in a long chat it runs out before it reaches
// the messages next to the composer, which are the ones a dictation is most likely about. So the
// snapshot first reads outward from the focused element — its siblings nearest first, then its
// parent's siblings, and so on — and only then walks the window. The focused field's own text is
// not read here (that is H17's caret window); a secure field or a secure neighbour gives nothing.
// Screen text is data, never instructions; it stays in memory.

/// Node access the outward read needs on top of `AXNodeAccess`: the focused element and parents.
public protocol CaretNeighbourhoodAccess: AnyObject {
    func focusedElement(pid: Int32) -> AXNodeRef?
    func parent(of node: AXNodeRef) -> AXNodeRef?
    func children(of node: AXNodeRef) -> [AXNodeRef]
    func role(of node: AXNodeRef) -> String
    func subrole(of node: AXNodeRef) -> String?
    /// The node's text (`AXValue` when a string, else its title). nil = none.
    func text(of node: AXNodeRef) -> String?
}

/// What the outward read found. `blocks` are nearest first; a block's `depth` is its outward rank
/// (1 = a sibling of the focused element, 2 = a sibling of its parent, …).
public struct CaretNeighbourhood: Equatable, Sendable {
    public var blocks: [TextBlock]
    /// Per block: whether it sits before the caret in reading order.
    public var isBefore: [Bool]
    public var nodesVisited: Int
    public var interrupted: Bool
    /// The focused element is a secure field: nothing was read.
    public var secure: Bool

    public init(blocks: [TextBlock] = [], isBefore: [Bool] = [], nodesVisited: Int = 0,
                interrupted: Bool = false, secure: Bool = false) {
        self.blocks = blocks; self.isBefore = isBefore; self.nodesVisited = nodesVisited
        self.interrupted = interrupted; self.secure = secure
    }

    /// The blocks back in reading order (before-caret blocks reversed, then after-caret blocks).
    public var readingOrderText: String {
        var before: [String] = [], after: [String] = []
        for (i, b) in blocks.enumerated() where !b.text.isEmpty {
            if i < isBefore.count, isBefore[i] { before.append(b.text) } else { after.append(b.text) }
        }
        return (before.reversed() + after).joined(separator: "\n\n")
    }
}

/// The outward walk itself (pure over `CaretNeighbourhoodAccess`; mocked in tests).
public enum CaretOutwardWalker {
    static let secureRole = "AXSecureTextField"
    static let stopRoles: Set<String> = ["AXWindow", "AXApplication", "AXSheet", "AXDrawer"]

    public static func read(access: CaretNeighbourhoodAccess, pid: Int32, deadline: Date?,
                            cancellation: AXReadCancellation? = nil, maxNodes: Int = 300, maxLevels: Int = 8,
                            maxCharacters: Int = 8_000, maxBlockCharacters: Int = 600,
                            now: () -> Date = Date.init) -> CaretNeighbourhood {
        var out = CaretNeighbourhood()
        guard let focused = access.focusedElement(pid: pid) else { return out }
        if isSecure(access, focused) { out.secure = true; return out }
        var chars = 0
        var stopped = false

        func expired() -> Bool {
            if cancellation?.isCancelled == true || deadline.map({ now() >= $0 }) == true {
                out.interrupted = true; stopped = true
            }
            return stopped
        }

        func walk(_ node: AXNodeRef, rank: Int, before: Bool) {
            if stopped || expired() { return }
            guard out.nodesVisited < maxNodes, chars < maxCharacters else { stopped = true; return }
            out.nodesVisited += 1
            let role = access.role(of: node)
            if AXWindowReader.skippedRoles.contains(role) || isSecure(access, node, role: role) { return }
            if AXWindowReader.textRoles.contains(role) {
                if let raw = access.text(of: node)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
                    let window = min(maxBlockCharacters, maxCharacters - chars)
                    // Before the caret the end of a long block is nearest; after it, the start.
                    let text = before ? CaretWindow.tail(of: raw, window: window) : CaretWindow.head(of: raw, window: window)
                    chars += text.utf16.count
                    out.blocks.append(TextBlock(role: role, text: text, visibleRange: nil,
                                                totalCharacters: raw.utf16.count, depth: rank))
                    out.isBefore.append(before)
                }
                return
            }
            let kids = access.children(of: node)
            for kid in (before ? kids.reversed() : kids) {
                walk(kid, rank: rank, before: before)
                if stopped { return }
            }
        }

        var child = focused
        var level = 0
        while level < maxLevels, !stopped, let parent = access.parent(of: child) {
            level += 1
            let kids = access.children(of: parent)
            let index = kids.firstIndex(of: child) ?? kids.count
            // Nearest sibling first, the one before the caret ahead of the one after it.
            var d = 1
            while !stopped, index - d >= 0 || index + d < kids.count {
                if index - d >= 0 { walk(kids[index - d], rank: level, before: true) }
                if !stopped, index + d < kids.count { walk(kids[index + d], rank: level, before: false) }
                d += 1
            }
            if stopRoles.contains(access.role(of: parent)) { break }
            child = parent
        }
        return out
    }

    static func isSecure(_ access: CaretNeighbourhoodAccess, _ node: AXNodeRef, role: String? = nil) -> Bool {
        (role ?? access.role(of: node)) == secureRole || access.subrole(of: node) == secureRole
    }
}

/// Finds the outward-read access behind an `AXReading` (live AX in the app; nil for a mock tree
/// that does not model parents — those keep the window walk only).
public enum CaretNeighbourhoodResolver {
    public static func access(behind reader: AXReading) -> CaretNeighbourhoodAccess? {
        var inner: AXReading = reader
        if let cached = reader as? CachedAXReader { inner = cached.reader }
        guard let walker = inner as? AXWindowReader else { return nil }
        if let direct = walker.access as? CaretNeighbourhoodAccess { return direct }
        if walker.access is LiveAXNodeAccess { return LiveCaretNeighbourhoodAccess() }
        return nil
    }
}

// MARK: - Per-turn read facts for the turn row

/// H21 — the last turn's snapshot facts (node count, interrupted flag, per-source candidate
/// counts), kept in memory until `FinalPassTimingRecorder` writes them to `extras_json`.
public final class TurnContextDiagnostics: @unchecked Sendable {
    public static let shared = TurnContextDiagnostics()

    public struct Entry: Equatable, Sendable {
        public var stats: TurnContextSnapshot.Stats?
        /// The turn's candidates by `CandidateSource` (near-caret field, window, shell).
        public var turnCandidateCounts: [String: Int]?
    }

    private let lock = NSLock()
    private var entry = Entry()
    public init() {}

    /// Key-down: a new turn starts with nothing recorded.
    public func begin() { lock.withLock { entry = Entry() } }
    public func record(_ stats: TurnContextSnapshot.Stats) { lock.withLock { entry.stats = stats } }
    public func recordTurnCandidates(_ counts: [String: Int]) { lock.withLock { entry.turnCandidateCounts = counts } }
    public var current: Entry { lock.withLock { entry } }

    static let readMsKey = "ctx_read_ms"
    static let nodesKey = "ctx_nodes"
    static let nearNodesKey = "ctx_near_nodes"
    static let interruptedKey = "ctx_interrupted"
    static let timedOutKey = "ctx_timed_out"
    static let snapshotTermsPrefix = "ctx_terms_"
    static let turnCandidatesPrefix = "ctx_cand_"

    /// Writes `entry` through the existing `setStage` setter (flags as 0/1, counts as values).
    static func apply(_ entry: Entry, to extras: inout TurnRecordExtras) {
        if let s = entry.stats {
            extras.setStage(readMsKey, ms: s.readMs)
            extras.setStage(nodesKey, ms: s.nodes)
            extras.setStage(nearNodesKey, ms: s.nearNodes)
            extras.setStage(interruptedKey, ms: s.interrupted ? 1 : 0)
            extras.setStage(timedOutKey, ms: s.timedOutWaiting ? 1 : 0)
            for (source, n) in s.candidateCounts { extras.setStage(snapshotTermsPrefix + source, ms: n) }
        }
        for (source, n) in entry.turnCandidateCounts ?? [:] { extras.setStage(turnCandidatesPrefix + source, ms: n) }
    }
}
