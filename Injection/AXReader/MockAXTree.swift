import Foundation

/// In-memory AX tree for tests and the app's mock engine. Build nodes, attach them to windows, fire events.
public final class MockAXNode {
    public var role: String
    public var title: String?
    public var value: String?
    public var children: [MockAXNode]
    /// When `false` the node answers neither `AXNumberOfCharacters` nor `AXStringForRange` (Electron-style).
    public var supportsRanges: Bool
    public var visibleRange: Range<Int>?
    /// When set, `AXStringForRange` fails for ranges at/after this offset (models apps that cut off scrollback).
    public var rangeFailsAfter: Int?
    public let id: String

    public init(role: String, value: String? = nil, title: String? = nil, children: [MockAXNode] = [],
                supportsRanges: Bool = true, visibleRange: Range<Int>? = nil, id: String = UUID().uuidString) {
        self.role = role
        self.value = value
        self.title = title
        self.children = children
        self.supportsRanges = supportsRanges
        self.visibleRange = visibleRange
        self.id = id
    }

    public var ref: AXNodeRef { AXNodeRef(id: id, raw: self) }
}

public final class MockAXTree: AXNodeAccess {
    public final class Token: AXObservationToken {
        weak var tree: MockAXTree?
        let window: AXWindowID
        init(tree: MockAXTree, window: AXWindowID) { self.tree = tree; self.window = window }
        public func cancel() { tree?.handlers[window] = nil }
    }

    public var isTrusted = true
    public var observersAvailable = true
    public private(set) var windows: [AXWindowID: MockAXNode] = [:]
    public var focused: [Int32: AXWindowID] = [:]
    /// Every `AXStringForRange` request, for asserting chunking/stitching.
    public private(set) var rangeRequests: [(node: String, range: Range<Int>)] = []
    fileprivate var handlers: [AXWindowID: (AXChangeEvent) -> Void] = [:]

    public init() {}

    @discardableResult
    public func addWindow(_ id: AXWindowID, root: MockAXNode, focused: Bool = true) -> MockAXNode {
        root.role = "AXWindow"
        windows[id] = root
        if focused { self.focused[id.pid] = id }
        return root
    }

    public func removeWindow(_ id: AXWindowID) {
        windows[id] = nil
        if focused[id.pid] == id { focused[id.pid] = nil }
        fire(.windowDestroyed(id))
    }

    public func fire(_ event: AXChangeEvent) {
        switch event {
        case .valueChanged(let w), .focusChanged(let w), .windowDestroyed(let w): handlers[w]?(event)
        }
    }

    public var observerCount: Int { handlers.count }

    // MARK: AXNodeAccess

    public func windows(pid: Int32) -> [AXNodeRef] {
        windows.filter { $0.key.pid == pid }.sorted { $0.key.windowNumber < $1.key.windowNumber }.map { $0.value.ref }
    }

    public func focusedWindow(pid: Int32) -> AXNodeRef? { focused[pid].flatMap { windows[$0]?.ref } }

    public func windowID(of node: AXNodeRef) -> AXWindowID? {
        windows.first { $0.value.id == node.id }?.key
    }

    public func role(of node: AXNodeRef) -> String { mock(node)?.role ?? "unknown" }
    public func title(of node: AXNodeRef) -> String? { mock(node)?.title }
    public func children(of node: AXNodeRef) -> [AXNodeRef] { mock(node)?.children.map(\.ref) ?? [] }
    public func value(of node: AXNodeRef) -> String? { mock(node)?.value }

    public func numberOfCharacters(of node: AXNodeRef) -> Int? {
        guard let m = mock(node), m.supportsRanges, let v = m.value else { return nil }
        return v.utf16.count
    }

    public func visibleCharacterRange(of node: AXNodeRef) -> Range<Int>? { mock(node)?.visibleRange }

    public func string(of node: AXNodeRef, range: Range<Int>) -> String? {
        rangeRequests.append((node.id, range))
        guard let m = mock(node), m.supportsRanges, let v = m.value else { return nil }
        let units = Array(v.utf16)
        guard range.lowerBound >= 0, range.upperBound <= units.count else { return nil }
        if let cut = m.rangeFailsAfter, range.upperBound > cut { return nil }
        return String(decoding: units[range], as: UTF16.self)
    }

    public func observe(window: AXWindowID, handler: @escaping (AXChangeEvent) -> Void) -> AXObservationToken? {
        guard observersAvailable else { return nil }
        handlers[window] = handler
        return Token(tree: self, window: window)
    }

    private func mock(_ node: AXNodeRef) -> MockAXNode? { node.raw as? MockAXNode }
}
