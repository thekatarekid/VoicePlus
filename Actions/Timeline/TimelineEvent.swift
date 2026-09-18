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

/// G1 — one box drawn with the dictation key held (V4.27). Written to the timeline when the drag
/// starts (`isComplete == false`, zero-size rect) and again when it ends as a box. A drag too small
/// to be a box (a click) never gets its closing sample, so it never binds.
public struct RegionSample: Equatable, Hashable, Sendable {
    public var regionID: UUID
    /// Cocoa global points, clamped to the display the drag started on.
    public var rect: CGRect
    public var displayID: UInt32
    public var isComplete: Bool

    public init(regionID: UUID, rect: CGRect, displayID: UInt32, isComplete: Bool) {
        self.regionID = regionID; self.rect = rect; self.displayID = displayID; self.isComplete = isComplete
    }
}

public enum TimelineEventKind: Equatable, Hashable, Sendable {
    case pointerMove(GlobalPoint)
    case click(GlobalPoint, button: MouseButton, down: Bool)
    /// A free-hand ink point. Live capture no longer produces these (G1 replaced ink with boxes);
    /// the kind stays so recorded timelines and replay fixtures still bind.
    case strokePoint(strokeID: UUID, GlobalPoint, pressure: Float)
    case selectionChange(SelectionSnapshot)
    /// A drawn box (G1). Not positional: the drag that drew it is already in the pointer path.
    case region(RegionSample)

    public var point: GlobalPoint? {
        switch self {
        case .pointerMove(let p), .click(let p, _, _), .strokePoint(_, let p, _): return p
        case .selectionChange, .region: return nil
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
