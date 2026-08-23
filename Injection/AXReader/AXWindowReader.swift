import Foundation

/// Walks a window's AX tree and extracts every text-bearing node. Large text areas (documents, terminals)
/// are read by stitching `AXStringForRange` chunks across `0..<AXNumberOfCharacters`, which reaches scrollback
/// that `AXValue` alone may omit. Never takes screenshots; AX only.
public final class AXWindowReader: AXReading {
    public static let textRoles: Set<String> = [
        "AXTextArea", "AXTextField", "AXStaticText", "AXComboBox", "AXSearchField", "AXHeading", "AXLink",
    ]
    /// Subtrees that never contain user-relevant text; skipping them keeps node budgets for the real content.
    public static let skippedRoles: Set<String> = ["AXMenuBar", "AXScrollBar", "AXToolbar", "AXImage", "AXSplitter"]

    public let access: AXNodeAccess
    private let now: () -> Date

    public init(access: AXNodeAccess, now: @escaping () -> Date = Date.init) {
        self.access = access
        self.now = now
    }

    public func windows(pid: Int32) -> [AXWindowID] {
        access.windows(pid: pid).compactMap(access.windowID(of:))
    }

    public func readWindow(_ id: AXWindowID, options: AXReadOptions) throws -> WindowContent {
        guard access.isTrusted else { throw AXReadError.accessibilityNotTrusted }
        guard let node = access.windows(pid: id.pid).first(where: { access.windowID(of: $0) == id }) else {
            throw AXReadError.windowNotFound(id)
        }
        return read(node: node, id: id, options: options)
    }

    public func readFocusedWindow(pid: Int32, options: AXReadOptions) throws -> WindowContent {
        guard access.isTrusted else { throw AXReadError.accessibilityNotTrusted }
        guard let node = access.focusedWindow(pid: pid), let id = access.windowID(of: node) else {
            throw AXReadError.noFocusedWindow(pid: pid)
        }
        return read(node: node, id: id, options: options)
    }

    // MARK: Walking

    private struct Walk {
        var blocks: [TextBlock] = []
        var chars = 0
        var nodes = 0
        var truncated = false
    }

    private func read(node root: AXNodeRef, id: AXWindowID, options: AXReadOptions) -> WindowContent {
        var walk = Walk()
        if options.truncation == .keepTail {
            // Collect everything (bounded by node budget), then trim from the front so the tail survives.
            walkTree(root, depth: 0, options: options, budget: Int.max, into: &walk)
            trimHead(&walk, to: options.limits.maxCharacters)
        } else {
            walkTree(root, depth: 0, options: options, budget: options.limits.maxCharacters, into: &walk)
        }
        return WindowContent(window: id, title: access.title(of: root), blocks: walk.blocks,
                             truncated: walk.truncated, nodesVisited: walk.nodes, readAt: now())
    }

    private func walkTree(_ node: AXNodeRef, depth: Int, options: AXReadOptions, budget: Int, into walk: inout Walk) {
        guard walk.nodes < options.limits.maxNodes, depth <= options.limits.maxDepth else {
            walk.truncated = true
            return
        }
        walk.nodes += 1
        let role = access.role(of: node)
        if Self.skippedRoles.contains(role) { return }
        if Self.textRoles.contains(role), walk.chars < budget {
            if let block = extract(node, role: role, depth: depth, options: options, remaining: budget - walk.chars) {
                walk.chars += block.text.utf16.count
                if options.includeScrollback, block.text.utf16.count < block.totalCharacters { walk.truncated = true }
                walk.blocks.append(block)
            }
        } else if Self.textRoles.contains(role) {
            walk.truncated = true
        }
        for child in access.children(of: node) {
            if walk.chars >= budget { walk.truncated = true; return }
            walkTree(child, depth: depth + 1, options: options, budget: budget, into: &walk)
        }
    }

    /// Pulls text from one node. Prefers range walking when the node reports `AXNumberOfCharacters` and answers
    /// `AXStringForRange`; falls back to `AXValue`.
    private func extract(_ node: AXNodeRef, role: String, depth: Int, options: AXReadOptions, remaining: Int) -> TextBlock? {
        let total = access.numberOfCharacters(of: node)
        let visible = access.visibleCharacterRange(of: node)
        let wanted: Range<Int>? = options.includeScrollback ? total.map { 0..<$0 } : (visible ?? total.map { 0..<$0 })
        if let wanted, wanted.count > 0, let stitched = stitch(node, range: wanted, chunk: options.limits.rangeChunk, cap: remaining) {
            return TextBlock(role: role, text: stitched, visibleRange: visible, totalCharacters: total ?? stitched.utf16.count, depth: depth)
        }
        guard let value = access.value(of: node), !value.isEmpty else { return nil }
        let units = Array(value.utf16)
        var slice = units[...]
        if !options.includeScrollback, let visible, visible.upperBound <= units.count { slice = units[visible] }
        let capped = slice.prefix(remaining)
        return TextBlock(role: role, text: String(decoding: capped, as: UTF16.self), visibleRange: visible,
                         totalCharacters: total ?? units.count, depth: depth)
    }

    /// Stitches `AXStringForRange` pieces. Returns `nil` on the first failure so the caller can fall back to `AXValue`.
    private func stitch(_ node: AXNodeRef, range: Range<Int>, chunk: Int, cap: Int) -> String? {
        var out = ""
        var cursor = range.lowerBound
        let end = min(range.upperBound, range.lowerBound + cap)
        while cursor < end {
            var piece = cursor..<min(cursor + max(1, chunk), end)
            guard var s = access.string(of: node, range: piece) else { return cursor == range.lowerBound ? nil : out }
            // A boundary inside a surrogate pair yields U+FFFD at the edge; back off one unit and re-read.
            if piece.upperBound < end, piece.count > 1, s.unicodeScalars.last == "\u{FFFD}" {
                piece = cursor..<(piece.upperBound - 1)
                guard let shorter = access.string(of: node, range: piece) else { return out }
                s = shorter
            }
            out += s
            cursor = piece.upperBound
        }
        return out
    }

    private func trimHead(_ walk: inout Walk, to cap: Int) {
        var excess = walk.chars - cap
        guard excess > 0 else { return }
        walk.truncated = true
        while excess > 0, let first = walk.blocks.first {
            let len = first.text.utf16.count
            if len <= excess {
                walk.blocks.removeFirst()
                excess -= len
            } else {
                let units = Array(first.text.utf16)
                walk.blocks[0].text = String(decoding: units[excess...], as: UTF16.self)
                excess = 0
            }
        }
        walk.chars = min(walk.chars, cap)
    }
}
