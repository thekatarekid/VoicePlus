import Foundation
import CoreGraphics
#if canImport(ApplicationServices)
import ApplicationServices
#endif

/// Hit-testing the accessibility tree at a global point. Live impl wraps
/// `AXUIElementCopyElementAtPosition`; tests use `MockAXHitTester`.
public protocol AXHitTesting: AnyObject {
    /// Deepest element containing `point`, or nil.
    func element(at point: GlobalPoint) -> ElementReference?
    /// Elements whose frame intersects `rect` on `displayID` (used for stroke regions and near-miss candidates).
    func elements(intersecting rect: CGRect, displayID: UInt32) -> [ElementReference]
}

/// Flat list of rectangles; hit = smallest frame containing the point on the same display.
public final class MockAXHitTester: AXHitTesting {
    public var elements: [ElementReference]
    public init(elements: [ElementReference]) { self.elements = elements }

    public func element(at point: GlobalPoint) -> ElementReference? {
        elements.filter { $0.displayID == point.displayID && $0.frame.contains(point.cgPoint) }.min { $0.area < $1.area }
    }

    public func elements(intersecting rect: CGRect, displayID: UInt32) -> [ElementReference] {
        elements.filter { $0.displayID == displayID && $0.frame.intersects(rect) }
    }
}

#if canImport(ApplicationServices)
/// Live AX hit-tester. Requires Accessibility trust; returns nil otherwise. Untested on CI (no AX permission).
public final class LiveAXHitTester: AXHitTesting {
    private let normalizer: () -> DisplayNormalizer
    public init(normalizer: @escaping () -> DisplayNormalizer = { DisplayNormalizer.current() }) { self.normalizer = normalizer }

    public static var isAvailable: Bool { AXIsProcessTrusted() }

    public func element(at point: GlobalPoint) -> ElementReference? {
        guard Self.isAvailable else { return nil }
        let q = normalizer().quartzPoint(fromCocoa: point.cgPoint)
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(q.x), Float(q.y), &el) == .success, let e = el else { return nil }
        return describe(e, displayID: point.displayID)
    }

    public func elements(intersecting rect: CGRect, displayID: UInt32) -> [ElementReference] {
        // Sample a 3×3 grid inside the rect; dedupe by element id.
        var seen: [String: ElementReference] = [:]
        for i in 0..<3 { for j in 0..<3 {
            let p = GlobalPoint(x: rect.minX + rect.width * (CGFloat(i) + 0.5) / 3, y: rect.minY + rect.height * (CGFloat(j) + 0.5) / 3, displayID: displayID)
            if let e = element(at: p), e.frame.intersects(rect) { seen[e.id] = e }
        } }
        return Array(seen.values)
    }

    private func describe(_ e: AXUIElement, displayID: UInt32) -> ElementReference? {
        func attr<T>(_ name: String) -> T? {
            var v: CFTypeRef?; AXUIElementCopyAttributeValue(e, name as CFString, &v); return v as? T
        }
        var pid: pid_t = 0; AXUIElementGetPid(e, &pid)
        let role: String = attr(kAXRoleAttribute) ?? "AXUnknown"
        let label: String = attr(kAXTitleAttribute) ?? attr(kAXDescriptionAttribute) ?? (attr(kAXValueAttribute) as String?).map { String($0.prefix(80)) } ?? ""
        var frame = CGRect.zero
        if let pv: AXValue = attr(kAXPositionAttribute), let sv: AXValue = attr(kAXSizeAttribute) {
            var p = CGPoint.zero, s = CGSize.zero
            AXValueGetValue(pv, .cgPoint, &p); AXValueGetValue(sv, .cgSize, &s)
            let n = normalizer()
            // AX frames are Quartz (top-left origin); convert to Cocoa global.
            let bottomLeft = n.cocoaPoint(fromQuartz: CGPoint(x: p.x, y: p.y + s.height))
            frame = CGRect(origin: bottomLeft, size: s)
        }
        let id = "\(pid):\(role):\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width))x\(Int(frame.height))"
        return ElementReference(id: id, role: role, label: label, frame: frame, displayID: displayID, pid: pid)
    }
}
#endif
