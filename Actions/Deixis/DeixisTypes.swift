import Foundation
import CoreGraphics

/// A concrete on-screen UI element found by AX hit-testing. `frame` is in Cocoa global coordinates.
public struct ElementReference: Equatable, Hashable, Sendable, Codable {
    public var id: String
    public var role: String
    public var label: String
    public var frame: CGRect
    public var displayID: UInt32
    public var pid: pid_t

    public init(id: String, role: String, label: String = "", frame: CGRect, displayID: UInt32, pid: pid_t = 0) {
        self.id = id; self.role = role; self.label = label; self.frame = frame; self.displayID = displayID; self.pid = pid
    }

    public var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }
    public var area: CGFloat { frame.width * frame.height }
}

/// A drawn/pointed region (stroke bundle bounding box) plus the elements it covers.
public struct RegionReference: Equatable, Hashable, Sendable {
    public var bounds: CGRect
    public var centroid: CGPoint
    public var displayID: UInt32
    public var strokeIDs: [UUID]
    public var elements: [ElementReference]

    public init(bounds: CGRect, centroid: CGPoint, displayID: UInt32, strokeIDs: [UUID] = [], elements: [ElementReference] = []) {
        self.bounds = bounds; self.centroid = centroid; self.displayID = displayID; self.strokeIDs = strokeIDs; self.elements = elements
    }
}

public enum ScreenReference: Equatable, Hashable, Sendable {
    case element(ElementReference)
    case region(RegionReference)

    public var displayID: UInt32 {
        switch self { case .element(let e): return e.displayID; case .region(let r): return r.displayID }
    }
    public var bounds: CGRect {
        switch self { case .element(let e): return e.frame; case .region(let r): return r.bounds }
    }
    public var label: String {
        switch self {
        case .element(let e): return e.label.isEmpty ? e.role : e.label
        case .region(let r): return r.elements.count == 1 ? (r.elements[0].label.isEmpty ? r.elements[0].role : r.elements[0].label) : "region (\(r.elements.count) items)"
        }
    }
}

public enum DeicticKind: String, Sendable, Codable { case proximal, distal, locative }

/// Result of binding one deictic word to the screen.
public struct DeixisBinding: Equatable, Sendable {
    public var word: String
    public var kind: DeicticKind
    public var spanIndex: Int
    public var audioRange: ClosedRange<TimeInterval>
    public var instant: TimelineInstant
    public var anchor: GlobalPoint?
    public var reference: ScreenReference?
    /// Ranked candidates (best first). More than one within threshold ⇒ `isAmbiguous`.
    public var candidates: [ScreenReference]
    public var confidence: Float
    public var isAmbiguous: Bool

    public init(word: String, kind: DeicticKind, spanIndex: Int, audioRange: ClosedRange<TimeInterval>, instant: TimelineInstant,
                anchor: GlobalPoint?, reference: ScreenReference?, candidates: [ScreenReference], confidence: Float, isAmbiguous: Bool) {
        self.word = word; self.kind = kind; self.spanIndex = spanIndex; self.audioRange = audioRange; self.instant = instant
        self.anchor = anchor; self.reference = reference; self.candidates = candidates; self.confidence = confidence; self.isAmbiguous = isAmbiguous
    }
}
