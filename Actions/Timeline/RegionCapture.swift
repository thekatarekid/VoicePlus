import Foundation
import CoreGraphics

/// G1 — a box drawn by dragging with the dictation key held (V4.27). The box, not the free-hand
/// stroke, is the unit of deixis.
public struct DrawnRegion: Equatable, Hashable, Sendable {
    public let id: UUID
    /// Where the drag started (mouse-down).
    public var anchor: GlobalPoint
    /// Where the pointer is now (or was at mouse-up).
    public var corner: GlobalPoint
    /// Cocoa global points, normalised (any drag direction) and clamped to `displayID`'s frame.
    public var rect: CGRect
    /// The display the drag started on. A box never spans displays.
    public var displayID: UInt32
    /// `rect` in that display's own coordinates (origin at its bottom-left) — what the overlay
    /// window on that display draws.
    public var displayRect: CGRect
    public var began: TimelineInstant
    public var ended: TimelineInstant?
    public var isComplete: Bool

    public init(id: UUID = UUID(), anchor: GlobalPoint, corner: GlobalPoint, rect: CGRect, displayID: UInt32,
                displayRect: CGRect, began: TimelineInstant, ended: TimelineInstant? = nil, isComplete: Bool = false) {
        self.id = id; self.anchor = anchor; self.corner = corner; self.rect = rect; self.displayID = displayID
        self.displayRect = displayRect; self.began = began; self.ended = ended; self.isComplete = isComplete
    }

    public var sample: RegionSample {
        RegionSample(regionID: id, rect: rect, displayID: displayID, isComplete: isComplete)
    }
}

/// Anything that wants live boxes (the overlay). Called on the recorder's thread.
public protocol RegionSink: AnyObject {
    func regionBegan(_ region: DrawnRegion)
    func regionChanged(_ region: DrawnRegion)
    func regionEnded(_ region: DrawnRegion)
    /// The drag ended too small to be a box (a click, a nudge): nothing binds to it.
    func regionDiscarded(_ region: DrawnRegion)
}

/// Pure box geometry shared by the capture (Actions) and the overlay (App).
public enum RegionMath {
    /// The rect spanned by two corners, whichever way the drag went.
    public static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    /// `point` pulled inside `bounds` (inclusive of the far edge).
    public static func clamp(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY))
    }

    /// A drag counts as a box only when both sides reach `minimumSide` points; anything smaller is
    /// a click or a nudge.
    public static func isBox(_ rect: CGRect, minimumSide: CGFloat) -> Bool {
        rect.width >= minimumSide && rect.height >= minimumSide
    }
}

/// Turns a key-gated left drag into a `DrawnRegion`: begin at mouse-down, follow the pointer,
/// finish at mouse-up. Pure state machine — the recorder (or a test) feeds it down/drag/up.
/// Writes a sample to the timeline when the box starts and when it is finished, and mirrors
/// the live box to a sink.
public final class RegionCapture: @unchecked Sendable {
    public private(set) var current: DrawnRegion?
    public private(set) var completed: [DrawnRegion] = []
    public weak var sink: RegionSink?
    /// A finished box — the deixis service analyses it (AX, screenshot, OCR).
    public var onRegion: ((DrawnRegion) -> Void)?
    /// The drag just grew to box size (once per box): the press it happens in is a point.
    public var onBoxStarted: ((DrawnRegion) -> Void)?
    private var announced: Set<UUID> = []
    /// Both sides must reach this many points for the drag to be a box.
    public var minimumSide: CGFloat = 6
    /// Used to clamp the box to its display and express it in that display's coordinates.
    public var normalizer: DisplayNormalizer?
    private let timeline: InputTimeline
    private let lock = NSLock()

    public init(timeline: InputTimeline, normalizer: DisplayNormalizer? = nil, sink: RegionSink? = nil) {
        self.timeline = timeline; self.normalizer = normalizer; self.sink = sink
    }

    public var isDrawing: Bool { lock.lock(); defer { lock.unlock() }; return current != nil }

    public func begin(at p: GlobalPoint, time t: TimelineInstant) {
        if isDrawing { end(time: t) }
        let region = make(id: UUID(), anchor: p, corner: p, began: t)
        lock.lock(); current = region; lock.unlock()
        timeline.append(TimelineEvent(timestamp: t, kind: .region(region.sample)))
        sink?.regionBegan(region)
    }

    public func update(to p: GlobalPoint, time t: TimelineInstant) {
        lock.lock()
        guard let r = current else { lock.unlock(); return }
        let region = make(id: r.id, anchor: r.anchor, corner: p, began: r.began)
        current = region
        let firstTimeBox = RegionMath.isBox(region.rect, minimumSide: minimumSide) && announced.insert(region.id).inserted
        lock.unlock()
        sink?.regionChanged(region)
        if firstTimeBox { onBoxStarted?(region) }
    }

    /// Finish the drag. Returns the box, or nil when there was no drag or it was too small.
    @discardableResult
    public func end(at p: GlobalPoint? = nil, time t: TimelineInstant) -> DrawnRegion? {
        lock.lock()
        guard let r = current else { lock.unlock(); return nil }
        current = nil
        var region = make(id: r.id, anchor: r.anchor, corner: p ?? r.corner, began: r.began)
        region.ended = t
        guard RegionMath.isBox(region.rect, minimumSide: minimumSide) else {
            lock.unlock()
            sink?.regionDiscarded(region)
            return nil
        }
        region.isComplete = true
        completed.append(region)
        lock.unlock()
        timeline.append(TimelineEvent(timestamp: t, kind: .region(region.sample)))
        sink?.regionEnded(region)
        onRegion?(region)
        return region
    }

    /// Abandon the drag in progress without producing a box (capture stopped mid-drag on cancel).
    public func cancel() {
        lock.lock()
        let r = current
        current = nil
        lock.unlock()
        if let r { sink?.regionDiscarded(r) }
    }

    /// Forget the boxes of a finished turn (the timeline keeps its own 30 s copy).
    public func reset() {
        lock.lock(); current = nil; completed.removeAll(); announced.removeAll(); lock.unlock()
    }

    private func make(id: UUID, anchor: GlobalPoint, corner: GlobalPoint, began: TimelineInstant) -> DrawnRegion {
        var rect = RegionMath.rect(from: anchor.cgPoint, to: corner.cgPoint)
        var displayRect = rect
        if let n = normalizer, let d = n.displays.first(where: { $0.id == anchor.displayID }) {
            let c = RegionMath.clamp(corner.cgPoint, to: d.frame)
            rect = RegionMath.rect(from: RegionMath.clamp(anchor.cgPoint, to: d.frame), to: c)
            displayRect = rect.offsetBy(dx: -d.frame.minX, dy: -d.frame.minY)
        }
        return DrawnRegion(id: id, anchor: anchor, corner: corner, rect: rect, displayID: anchor.displayID,
                           displayRect: displayRect, began: began)
    }
}

// MARK: - Which drags draw (V4.28)

/// G1 — the rule that decides whether a left drag draws a box.
///
/// The trigger is the same in both modes: drag while the dictation key is physically down. In
/// hold mode the key is down anyway. In latch it is not, so a bare drag does nothing — unless the
/// user turned on "In Latch, draw without a key" (`deixis.drawWithoutKey`, default off), which
/// applies to latch only.
public enum RegionGesturePolicy {
    public static func drawsRegion(keyDown: Bool, latched: Bool, drawWithoutKey: Bool) -> Bool {
        keyDown || (latched && drawWithoutKey)
    }
}

/// The live inputs to `RegionGesturePolicy`, read when a drag starts. Closures so the recorder
/// (Actions) never learns what the hotkey service or the settings store are.
public struct RegionGate: Sendable {
    public var isDictationKeyDown: @Sendable () -> Bool
    public var isLatched: @Sendable () -> Bool
    public var drawWithoutKey: @Sendable () -> Bool

    public init(isDictationKeyDown: @escaping @Sendable () -> Bool,
                isLatched: @escaping @Sendable () -> Bool = { false },
                drawWithoutKey: @escaping @Sendable () -> Bool = { false }) {
        self.isDictationKeyDown = isDictationKeyDown
        self.isLatched = isLatched
        self.drawWithoutKey = drawWithoutKey
    }

    /// Nothing draws. The default until the app wires the key in.
    public static let closed = RegionGate(isDictationKeyDown: { false })

    public var isOpen: Bool {
        RegionGesturePolicy.drawsRegion(keyDown: isDictationKeyDown(), latched: isLatched(),
                                        drawWithoutKey: drawWithoutKey())
    }
}
