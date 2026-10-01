import Foundation
import CoreGraphics
#if canImport(ApplicationServices)
import ApplicationServices
import Shared
#endif

/// G3 — text inside a drawn box, read from the accessibility tree (V4.29).
///
/// The live reader takes the element under the box, its visible character range
/// (`kAXVisibleCharacterRangeAttribute`), narrows it to the characters at the box's corners
/// (`kAXRangeForPositionParameterizedAttribute`) and reads that range with
/// `kAXStringForRangeParameterizedAttribute`. nil means the element exposes no text range (Docs,
/// canvas apps, images) — the caller falls back to recognising the screenshot.
public protocol AXRegionTextReading: AnyObject {
    func text(in rect: CGRect, displayID: UInt32) -> String?
}

/// Fixed answers by rect intersection, counting calls.
public final class MockAXRegionTextReader: AXRegionTextReading {
    public var texts: [(rect: CGRect, text: String)]
    public private(set) var calls: [CGRect] = []
    public init(texts: [(rect: CGRect, text: String)] = []) { self.texts = texts }

    public func text(in rect: CGRect, displayID: UInt32) -> String? {
        calls.append(rect)
        return texts.first { $0.rect.intersects(rect) }?.text
    }
}

/// Character-range arithmetic kept pure so it is testable without an AX tree.
public enum AXTextRange {
    /// The span from the character at the box's top-left corner to the one at its bottom-right,
    /// clipped to what is visible. nil when the corners fall outside the visible range entirely.
    public static func boxed(visible: CFRange, topLeft: CFRange?, bottomRight: CFRange?) -> CFRange? {
        guard visible.length > 0 else { return nil }
        let visibleEnd = visible.location + visible.length
        guard let a = topLeft, let b = bottomRight else { return visible }
        let lo = max(visible.location, min(a.location, b.location))
        let hi = min(visibleEnd, max(a.location + max(a.length, 1), b.location + max(b.length, 1)))
        guard hi > lo else { return nil }
        return CFRange(location: lo, length: hi - lo)
    }
}

#if canImport(ApplicationServices)
/// Live reader. Requires Accessibility trust; returns nil otherwise. Untested on CI (no AX permission).
public final class LiveAXRegionTextReader: AXRegionTextReading {
    private let normalizer: () -> DisplayNormalizer
    /// How far up the tree to look for an element that exposes a text range (a static-text run
    /// inside a text area answers the hit-test; the text area owns the range).
    public var ancestorDepth = 3

    public init(normalizer: @escaping () -> DisplayNormalizer = { DisplayNormalizer.current() }) {
        self.normalizer = normalizer
    }

    public func text(in rect: CGRect, displayID: UInt32) -> String? {
        guard AXIsProcessTrusted(), rect.width > 0, rect.height > 0 else { return nil }
        let n = normalizer()
        let centre = n.quartzPoint(fromCocoa: CGPoint(x: rect.midX, y: rect.midY))
        // K18 — hit-test through the guard (an element of ours off-main → refuse).
        guard var element = AXGuard.element(atX: Float(centre.x), y: Float(centre.y)) else { return nil }
        var visible = Self.range(element, kAXVisibleCharacterRangeAttribute)
        var depth = 0
        while visible == nil, depth < ancestorDepth, let parent: AXUIElement = Self.attribute(element, kAXParentAttribute) {
            element = parent
            visible = Self.range(element, kAXVisibleCharacterRangeAttribute)
            depth += 1
        }
        guard let visible else { return nil }
        // Quartz: the box's top-left is Cocoa (minX, maxY).
        let topLeft = n.quartzPoint(fromCocoa: CGPoint(x: rect.minX + 1, y: rect.maxY - 1))
        let bottomRight = n.quartzPoint(fromCocoa: CGPoint(x: rect.maxX - 1, y: rect.minY + 1))
        guard let range = AXTextRange.boxed(visible: visible,
                                            topLeft: Self.range(element, at: topLeft),
                                            bottomRight: Self.range(element, at: bottomRight)),
              let text = Self.string(element, range) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func attribute<T>(_ e: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success else { return nil }
        return v as? T
    }

    private static func range(_ e: AXUIElement, _ name: String) -> CFRange? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success, let value = v,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &r) ? r : nil
    }

    private static func range(_ e: AXUIElement, at quartz: CGPoint) -> CFRange? {
        var p = quartz
        guard let point = AXValueCreate(.cgPoint, &p) else { return nil }
        var v: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(e, kAXRangeForPositionParameterizedAttribute as CFString, point, &v) == .success,
              let value = v, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &r) ? r : nil
    }

    private static func string(_ e: AXUIElement, _ range: CFRange) -> String? {
        var r = range
        guard let param = AXValueCreate(.cfRange, &r) else { return nil }
        var v: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(e, kAXStringForRangeParameterizedAttribute as CFString, param, &v) == .success else { return nil }
        return v as? String
    }
}
#endif
