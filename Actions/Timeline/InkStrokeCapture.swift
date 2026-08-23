import Foundation
import CoreGraphics

/// A stroke drawn while the hotkey is held: time-stamped points on the shared timeline.
public struct InkStroke: Equatable, Sendable {
    public let id: UUID
    public var points: [InkPoint]
    public var isComplete: Bool

    public struct InkPoint: Equatable, Sendable {
        public var point: GlobalPoint
        public var timestamp: TimelineInstant
        public var pressure: Float
        public init(point: GlobalPoint, timestamp: TimelineInstant, pressure: Float = 1) {
            self.point = point; self.timestamp = timestamp; self.pressure = pressure
        }
    }

    public init(id: UUID = UUID(), points: [InkPoint] = [], isComplete: Bool = false) {
        self.id = id; self.points = points; self.isComplete = isComplete
    }

    public var timeRange: ClosedRange<TimelineInstant>? {
        guard let f = points.first, let l = points.last else { return nil }
        return f.timestamp...l.timestamp
    }

    public var displayIDs: Set<UInt32> { Set(points.map(\.point.displayID)) }

    public var bounds: CGRect {
        guard let f = points.first else { return .null }
        return points.dropFirst().reduce(CGRect(origin: f.point.cgPoint, size: .zero)) {
            $0.union(CGRect(origin: $1.point.cgPoint, size: .zero))
        }
    }
}

/// Anything that wants live strokes (the ink overlay). Called on the recorder's thread.
public protocol InkStrokeSink: AnyObject {
    func strokeBegan(_ stroke: InkStroke)
    func strokeChanged(_ stroke: InkStroke)
    func strokeEnded(_ stroke: InkStroke)
}

/// Turns drag gestures into `InkStroke`s, writing every point into the timeline and mirroring the
/// stroke to a sink. Pure state machine — the recorder (or a test) feeds it down/drag/up.
public final class InkStrokeCapture: @unchecked Sendable {
    public private(set) var current: InkStroke?
    public private(set) var completed: [InkStroke] = []
    public weak var sink: InkStrokeSink?
    private let timeline: InputTimeline
    /// Points closer than this to the previous one are dropped (CGEvent can emit sub-point deltas).
    public var minimumSpacing: CGFloat = 1.5

    public init(timeline: InputTimeline, sink: InkStrokeSink? = nil) {
        self.timeline = timeline; self.sink = sink
    }

    public func begin(at p: GlobalPoint, time t: TimelineInstant, pressure: Float = 1) {
        if current != nil { end(time: t) }
        var s = InkStroke()
        s.points = [.init(point: p, timestamp: t, pressure: pressure)]
        current = s
        timeline.append(TimelineEvent(timestamp: t, kind: .strokePoint(strokeID: s.id, p, pressure: pressure)))
        sink?.strokeBegan(s)
    }

    public func extend(to p: GlobalPoint, time t: TimelineInstant, pressure: Float = 1) {
        guard var s = current else { return begin(at: p, time: t, pressure: pressure) }
        if let last = s.points.last, last.point.distance(to: p) < minimumSpacing, last.point.displayID == p.displayID { return }
        s.points.append(.init(point: p, timestamp: t, pressure: pressure))
        current = s
        timeline.append(TimelineEvent(timestamp: t, kind: .strokePoint(strokeID: s.id, p, pressure: pressure)))
        sink?.strokeChanged(s)
    }

    @discardableResult
    public func end(time t: TimelineInstant) -> InkStroke? {
        guard var s = current else { return nil }
        s.isComplete = true
        current = nil
        completed.append(s)
        sink?.strokeEnded(s)
        return s
    }

    /// Forget strokes from a finished utterance (the timeline keeps its own 30 s copy).
    public func reset() { current = nil; completed.removeAll() }
}
