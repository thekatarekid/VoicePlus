import Foundation

// MARK: - Identity

/// Stable identity of one on-screen window: owning pid + CGWindowID (or a mock token).
public struct AXWindowID: Hashable, Sendable, Codable, CustomStringConvertible {
    public var pid: Int32
    public var windowNumber: Int
    public init(pid: Int32, windowNumber: Int) {
        self.pid = pid
        self.windowNumber = windowNumber
    }
    public var description: String { "\(pid):\(windowNumber)" }
}

/// Opaque handle to one AX node. `raw` is the live `AXUIElement` (or a mock node); `id` is the equality key.
public struct AXNodeRef: Hashable, @unchecked Sendable {
    public let id: String
    public let raw: AnyObject?
    public init(id: String, raw: AnyObject? = nil) {
        self.id = id
        self.raw = raw
    }
    public static func == (lhs: AXNodeRef, rhs: AXNodeRef) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Low-level tree access (mocked in tests, AXUIElement in production)

public enum AXChangeEvent: Equatable, Sendable {
    case valueChanged(AXWindowID)
    case focusChanged(AXWindowID)
    case windowDestroyed(AXWindowID)
}

public protocol AXObservationToken: AnyObject {
    func cancel()
}

/// Minimal per-node surface the reader needs. Everything returns `nil` when an app does not support the attribute.
public protocol AXNodeAccess: AnyObject {
    var isTrusted: Bool { get }
    func windows(pid: Int32) -> [AXNodeRef]
    func focusedWindow(pid: Int32) -> AXNodeRef?
    func windowID(of node: AXNodeRef) -> AXWindowID?
    func role(of node: AXNodeRef) -> String
    func title(of node: AXNodeRef) -> String?
    func children(of node: AXNodeRef) -> [AXNodeRef]
    /// `kAXValueAttribute` when it is a string.
    func value(of node: AXNodeRef) -> String?
    /// `kAXNumberOfCharactersAttribute` (UTF-16 units).
    func numberOfCharacters(of node: AXNodeRef) -> Int?
    /// `kAXVisibleCharacterRangeAttribute` (UTF-16 units).
    func visibleCharacterRange(of node: AXNodeRef) -> Range<Int>?
    /// `kAXStringForRangeParameterizedAttribute`. `nil` when unsupported or the range is rejected.
    func string(of node: AXNodeRef, range: Range<Int>) -> String?
    /// Registers for value / focus notifications on the window's app. `nil` when observers are unavailable.
    func observe(window: AXWindowID, handler: @escaping (AXChangeEvent) -> Void) -> AXObservationToken?
}

// MARK: - Reader API

public struct AXReadLimits: Equatable, Sendable {
    /// Hard cap on total extracted characters per window. Spec: 200k.
    public var maxCharacters: Int = 200_000
    /// Chunk size used when stitching `AXStringForRange` pieces.
    public var rangeChunk: Int = 8_192
    public var maxNodes: Int = 5_000
    public var maxDepth: Int = 64
    /// N7 — wall-clock deadline for one walk. Checked before every node: past it the walk stops,
    /// returns what it has and marks the content `interrupted`. `nil` = no deadline.
    public var deadline: Date?
    public init() {}

    /// N7 — the turn-snapshot budget: about 800 nodes, visible text only, a hard deadline.
    public static func turnSnapshot(deadline: Date, maxNodes: Int = 800, maxCharacters: Int = 20_000) -> AXReadLimits {
        var limits = AXReadLimits()
        limits.maxNodes = maxNodes
        limits.maxCharacters = maxCharacters
        limits.deadline = deadline
        return limits
    }
}

/// N7 — cooperative cancellation for a walk in flight. The walker checks it before every node, so a
/// discarded turn snapshot stops reading at the next node instead of running to the end.
public final class AXReadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

public enum TruncationPolicy: Equatable, Sendable {
    /// Keep the start (documents).
    case keepHead
    /// Keep the end (terminals: the latest output matters most).
    case keepTail
}

public struct AXReadOptions: Equatable, Sendable {
    /// When `true`, text nodes are read in full via range walking (scrollback). When `false`, only the visible range.
    public var includeScrollback: Bool
    public var limits: AXReadLimits
    public var truncation: TruncationPolicy
    /// N7 — checked per node; not part of equality.
    public var cancellation: AXReadCancellation?
    public init(includeScrollback: Bool = false, limits: AXReadLimits = AXReadLimits(), truncation: TruncationPolicy = .keepHead,
                cancellation: AXReadCancellation? = nil) {
        self.includeScrollback = includeScrollback
        self.limits = limits
        self.truncation = truncation
        self.cancellation = cancellation
    }
    public static func == (lhs: AXReadOptions, rhs: AXReadOptions) -> Bool {
        lhs.includeScrollback == rhs.includeScrollback && lhs.limits == rhs.limits && lhs.truncation == rhs.truncation
    }
    public static let visible = AXReadOptions()
    public static let full = AXReadOptions(includeScrollback: true)
}

/// One text-bearing node in reading order.
public struct TextBlock: Equatable, Sendable {
    public var role: String
    public var text: String
    /// Range of `text` (UTF-16, relative to the node's full content) that is on screen. `nil` if unknown.
    public var visibleRange: Range<Int>?
    /// Full length of the node's content, even when `text` was truncated or limited to the visible range.
    public var totalCharacters: Int
    public var depth: Int
    public init(role: String, text: String, visibleRange: Range<Int>?, totalCharacters: Int, depth: Int) {
        self.role = role
        self.text = text
        self.visibleRange = visibleRange
        self.totalCharacters = totalCharacters
        self.depth = depth
    }
}

public struct WindowContent: Equatable, Sendable {
    public var window: AXWindowID
    public var title: String?
    public var blocks: [TextBlock]
    public var truncated: Bool
    public var nodesVisited: Int
    public var readAt: Date
    /// N7 — the walk stopped early on its deadline or a cancellation (partial content; never cached).
    public var interrupted: Bool
    public init(window: AXWindowID, title: String?, blocks: [TextBlock], truncated: Bool, nodesVisited: Int, readAt: Date,
                interrupted: Bool = false) {
        self.window = window
        self.title = title
        self.blocks = blocks
        self.truncated = truncated
        self.nodesVisited = nodesVisited
        self.readAt = readAt
        self.interrupted = interrupted
    }
    /// All blocks joined by blank lines — what we hand to the deixis resolver / LLM context.
    public var text: String { blocks.map(\.text).joined(separator: "\n\n") }
    public var characterCount: Int { blocks.reduce(0) { $0 + $1.text.utf16.count } }
}

public enum AXReadError: Error, Equatable, Sendable {
    case accessibilityNotTrusted
    case windowNotFound(AXWindowID)
    case noFocusedWindow(pid: Int32)
}

/// The deep-reading facade. `AXWindowReader` is uncached; `CachedAXReader` adds `WindowContentCache`.
public protocol AXReading: AnyObject {
    func windows(pid: Int32) -> [AXWindowID]
    func readWindow(_ id: AXWindowID, options: AXReadOptions) throws -> WindowContent
    func readFocusedWindow(pid: Int32, options: AXReadOptions) throws -> WindowContent
}

public extension AXReading {
    /// Document / terminal content on demand: full text incl. scrollback, keeping the tail.
    func readDocument(_ id: AXWindowID) throws -> WindowContent {
        try readWindow(id, options: AXReadOptions(includeScrollback: true, truncation: .keepTail))
    }
}

/// Additive capability on top of `SystemAccess`: anything that can vend a deep AX reader.
/// Kept as a separate protocol so `SystemAccess` itself stays untouched.
public protocol AXReaderProviding: AnyObject {
    var axReader: AXReading { get }
}
