import Foundation
import CoreGraphics
#if canImport(AppKit)
import AppKit
#endif

/// One attached display, in Cocoa global coordinates (origin bottom-left of the *primary* display).
public struct DisplayFrame: Equatable, Hashable, Sendable {
    public var id: UInt32
    public var frame: CGRect
    public var scale: CGFloat

    public init(id: UInt32, frame: CGRect, scale: CGFloat = 2) {
        self.id = id; self.frame = frame; self.scale = scale
    }
}

/// Converts between Quartz event coordinates (`CGEvent.location`: origin top-left of primary,
/// y down) and `GlobalPoint` (Cocoa global, y up, tagged with display). Pure; screens are injected
/// so multi-display arrangements are unit-testable.
public struct DisplayNormalizer: Equatable, Sendable {
    public let displays: [DisplayFrame]
    public let primary: DisplayFrame

    public init(displays: [DisplayFrame]) {
        precondition(!displays.isEmpty, "need at least one display")
        self.displays = displays
        // The primary display is the one whose frame origin is (0,0) in Cocoa space.
        primary = displays.first { $0.frame.origin == .zero } ?? displays[0]
    }

    #if canImport(AppKit)
    /// Snapshot of the live `NSScreen` arrangement.
    public static func current() -> DisplayNormalizer {
        let frames = NSScreen.screens.map { screen -> DisplayFrame in
            let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return DisplayFrame(id: num?.uint32Value ?? 0, frame: screen.frame, scale: screen.backingScaleFactor)
        }
        return DisplayNormalizer(displays: frames.isEmpty ? [DisplayFrame(id: 0, frame: CGRect(x: 0, y: 0, width: 1, height: 1))] : frames)
    }
    #endif

    /// Quartz global (y down from top of primary) → Cocoa global (y up from bottom of primary).
    public func cocoaPoint(fromQuartz q: CGPoint) -> CGPoint {
        CGPoint(x: q.x, y: primary.frame.height - q.y)
    }

    public func quartzPoint(fromCocoa c: CGPoint) -> CGPoint {
        CGPoint(x: c.x, y: primary.frame.height - c.y)
    }

    public func display(containing cocoa: CGPoint) -> DisplayFrame {
        if let d = displays.first(where: { $0.frame.contains(cocoa) }) { return d }
        // Off every display (gap in arrangement or mid-transition): nearest by frame distance.
        return displays.min { distance($0.frame, cocoa) < distance($1.frame, cocoa) } ?? primary
    }

    public func normalize(cocoa: CGPoint) -> GlobalPoint {
        let d = display(containing: cocoa)
        let unit = CGPoint(x: d.frame.width > 0 ? (cocoa.x - d.frame.minX) / d.frame.width : 0,
                           y: d.frame.height > 0 ? (cocoa.y - d.frame.minY) / d.frame.height : 0)
        return GlobalPoint(x: cocoa.x, y: cocoa.y, displayID: d.id, unit: unit)
    }

    public func normalize(quartz: CGPoint) -> GlobalPoint { normalize(cocoa: cocoaPoint(fromQuartz: quartz)) }

    /// Point in a display's local window coordinates (origin at that display's bottom-left).
    public func local(_ p: GlobalPoint) -> CGPoint {
        guard let d = displays.first(where: { $0.id == p.displayID }) else { return p.cgPoint }
        return CGPoint(x: p.x - d.frame.minX, y: p.y - d.frame.minY)
    }

    private func distance(_ r: CGRect, _ p: CGPoint) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return hypot(dx, dy)
    }
}
