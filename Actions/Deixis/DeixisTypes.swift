import Foundation
import CoreGraphics
import Shared

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

/// A drawn region — a box (G1) or a legacy ink bundle's bounding box — plus the elements it covers.
public struct RegionReference: Equatable, Hashable, Sendable {
    public var bounds: CGRect
    public var centroid: CGPoint
    public var displayID: UInt32
    /// Legacy free-hand strokes that made the region (replayed timelines only).
    public var strokeIDs: [UUID]
    public var elements: [ElementReference]
    /// The drawn box this region is (`DrawnRegion.id`), when it came from one.
    public var regionID: UUID?

    public init(bounds: CGRect, centroid: CGPoint, displayID: UInt32, strokeIDs: [UUID] = [], elements: [ElementReference] = [],
                regionID: UUID? = nil) {
        self.bounds = bounds; self.centroid = centroid; self.displayID = displayID; self.strokeIDs = strokeIDs; self.elements = elements
        self.regionID = regionID
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

// MARK: - G3 · a drawn box, resolved (V4.29, V4.30 data)

/// Where a box's text came from: the accessibility tree, or recognition over its screenshot.
/// A box whose screen text is unavailable (no Screen Recording) carries AX text only — `.ax`, even
/// when the tree had nothing to give.
public enum DeixisRegionSource: String, Sendable, Codable, Equatable { case ax, ocr }

/// One box drawn during a turn, with what the service found inside it. Held in memory for the
/// turn only; the screenshot itself stays in the service, named here by `imageID`.
public struct DeixisRegion: Equatable, Sendable, Identifiable {
    /// The drawn box (`DrawnRegion.id`).
    public var id: UUID
    /// Cocoa global points.
    public var rect: CGRect
    public var displayID: UInt32
    /// The element the box is on (AX hit-test): smallest element mostly inside the box, else the
    /// one under its centre.
    public var element: ElementReference?
    /// Text inside the box, AX first, OCR as the fallback. Empty when neither had any.
    public var text: String
    /// Recognised lines when `source == .ocr` (boxes in global points).
    public var lines: [ScreenTextLine]
    /// The crop kept for the turn, for the pill's chip. nil without Screen Recording.
    public var imageID: UUID?
    public var source: DeixisRegionSource
    /// Screen Recording is not granted, so no screenshot and no OCR: the pill says
    /// "Screen text isn't available".
    public var screenTextUnavailable: Bool
    /// The screenshot / recognition is still running.
    public var isPending: Bool
    /// When the box was finished, on the timeline clock.
    public var drawnAt: TimelineInstant

    public init(id: UUID, rect: CGRect, displayID: UInt32, element: ElementReference? = nil, text: String = "",
                lines: [ScreenTextLine] = [], imageID: UUID? = nil, source: DeixisRegionSource = .ax,
                screenTextUnavailable: Bool = false, isPending: Bool = false, drawnAt: TimelineInstant = 0) {
        self.id = id; self.rect = rect; self.displayID = displayID; self.element = element; self.text = text
        self.lines = lines; self.imageID = imageID; self.source = source
        self.screenTextUnavailable = screenTextUnavailable; self.isPending = isPending; self.drawnAt = drawnAt
    }

    /// Longest text quoted into a context line; the rest is elided with "…".
    public static let contextTextLimit = 160

    /// The pipeline / model context line for this box, numbered from 1:
    /// `region 1 = <role> "<title>" text: "<…>"`.
    public func contextLine(index: Int) -> String {
        let role = element?.role ?? "AXUnknown"
        let title = Self.quoted(element?.label ?? "", limit: 80)
        let body = Self.quoted(text, limit: Self.contextTextLimit)
        return "region \(index) = \(role) \"\(title)\" text: \"\(body)\""
    }

    /// Whitespace collapsed to single spaces (OCR lines become one line), quotes escaped, cut at
    /// `limit` characters with an ellipsis.
    static func quoted(_ s: String, limit: Int) -> String {
        let flat = s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        let cut = flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
        return cut.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
