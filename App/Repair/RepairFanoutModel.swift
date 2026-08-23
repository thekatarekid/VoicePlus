import Foundation
import Shared

/// Pure state for the repair fan-out (T4): which word is focused, its numbered alternates,
/// and where the panel goes relative to the word's screen rect. No AppKit so it is fully
/// testable; `RepairFanoutPanel` renders it.
public struct RepairFanoutModel: Equatable, Sendable {
    public struct Item: Equatable, Sendable, Identifiable {
        public var id: Int { number }
        /// 1-based, what the user says ("number two").
        public var number: Int
        public var text: String
        public var source: Alternate.Source
    }

    public static let maxItems = 5
    public static let rowHeight: CGFloat = 24
    public static let minWidth: CGFloat = 120
    public static let gap: CGFloat = 4

    public var spanIndex: Int
    public var word: String
    public var confidence: Float
    public var items: [Item]
    public var highlighted: Int?

    public init(spanIndex: Int, word: String, confidence: Float, items: [Item], highlighted: Int? = nil) {
        self.spanIndex = spanIndex
        self.word = word
        self.confidence = confidence
        self.items = items
        self.highlighted = highlighted
    }

    /// Build from a landed utterance's span. Returns nil when there is nothing to fan out.
    public init?(span: TranscriptSpan, index: Int) {
        guard !span.alternates.isEmpty else { return nil }
        var seen = Set<String>()
        let alts = span.alternates.filter { seen.insert($0.text.lowercased()).inserted }.prefix(Self.maxItems)
        self.init(spanIndex: index, word: span.text, confidence: span.confidence,
                  items: alts.enumerated().map { Item(number: $0.offset + 1, text: $0.element.text, source: $0.element.source) })
    }

    /// Pick the span to fan out for a point (screen-space mouse position) given the per-span
    /// word rects; falls back to the lowest-confidence span that has alternates.
    public static func spanIndex(under point: CGPoint?, wordRects: [Int: CGRect], spans: [TranscriptSpan]) -> Int? {
        if let p = point, let hit = wordRects.first(where: { $0.value.insetBy(dx: -2, dy: -2).contains(p) }) { return hit.key }
        return spans.indices.filter { !spans[$0].alternates.isEmpty }.min { spans[$0].confidence < spans[$1].confidence }
    }

    /// Panel size for this many rows.
    public var size: CGSize {
        let width = max(Self.minWidth, CGFloat(items.map(\.text.count).max() ?? 0) * 8 + 44)
        return CGSize(width: width, height: CGFloat(items.count) * Self.rowHeight + 8)
    }

    /// Position beneath the word rect (AppKit coordinates: origin bottom-left, y up). Flips
    /// above the word when there is no room below, and clamps horizontally to the screen.
    public func frame(anchoredTo wordRect: CGRect, in screen: CGRect) -> CGRect {
        let s = size
        var x = wordRect.minX
        var y = wordRect.minY - Self.gap - s.height
        if y < screen.minY { y = wordRect.maxY + Self.gap }
        x = min(max(x, screen.minX), screen.maxX - s.width)
        y = min(max(y, screen.minY), screen.maxY - s.height)
        return CGRect(x: x, y: y, width: s.width, height: s.height)
    }

    /// Convert an AX bounds rect (Quartz: origin top-left, y down, relative to the primary
    /// screen) into AppKit screen coordinates.
    public static func appKitRect(fromAX rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// A spoken/clicked pick: returns the 0-based alternate index, or nil if out of range.
    public func alternateIndex(forNumber n: Int) -> Int? {
        items.indices.contains(n - 1) ? n - 1 : nil
    }
}
