import Foundation
import CoreGraphics

/// A point in Cocoa global coordinates (origin bottom-left of the primary display, points, y up),
/// tagged with the display it falls on and its unit position inside that display.
public struct GlobalPoint: Equatable, Hashable, Sendable {
    public var x: CGFloat
    public var y: CGFloat
    public var displayID: UInt32
    /// 0…1 inside the display's frame (x rightwards, y upwards). Lets a consumer compare positions
    /// across displays of different sizes/scales.
    public var unit: CGPoint

    public init(x: CGFloat, y: CGFloat, displayID: UInt32, unit: CGPoint = .zero) {
        self.x = x; self.y = y; self.displayID = displayID; self.unit = unit
    }

    public var cgPoint: CGPoint { CGPoint(x: x, y: y) }

    public func distance(to other: GlobalPoint) -> CGFloat { hypot(x - other.x, y - other.y) }
}

public enum MouseButton: String, Sendable, Hashable { case left, right, other }

/// Minimal description of a selection change. The AX-level detail (element, text) lives in
/// Injection's AX layer; the timeline only needs "when, where, which app".
public struct SelectionSnapshot: Equatable, Hashable, Sendable {
    public var bundleID: String?
    public var pid: pid_t
    public var bounds: CGRect?
    public var length: Int

    public init(bundleID: String?, pid: pid_t, bounds: CGRect?, length: Int) {
        self.bundleID = bundleID; self.pid = pid; self.bounds = bounds; self.length = length
    }
}

public enum TimelineEventKind: Equatable, Hashable, Sendable {
    case pointerMove(GlobalPoint)
    case click(GlobalPoint, button: MouseButton, down: Bool)
    case strokePoint(strokeID: UUID, GlobalPoint, pressure: Float)
    case selectionChange(SelectionSnapshot)

    public var point: GlobalPoint? {
        switch self {
        case .pointerMove(let p), .click(let p, _, _), .strokePoint(_, let p, _): return p
        case .selectionChange: return nil
        }
    }
}

public struct TimelineEvent: Equatable, Hashable, Sendable {
    public var timestamp: TimelineInstant
    public var kind: TimelineEventKind

    public init(timestamp: TimelineInstant, kind: TimelineEventKind) {
        self.timestamp = timestamp; self.kind = kind
    }
}
