import Actions
import CoreGraphics
import Foundation
import Injection

// S4 — the mouth-to-caret tape flight (design §4 "Mouth-to-caret tape path", §5 step 6): the pure half.
// Which destination the flight may aim at, and where the ribbon runs on screen. The maths of the ribbon
// itself is S1's `SpoolFlight` (the prototype's `flight()`); this file only supplies its `from`, `to`,
// `w` and `h`.

/// Why no flight is drawn. In every case the insertion, its label and its outcome are unchanged: the
/// flight only ever subscribes to the pill, it never delays or triggers the write.
enum TapeFlightSuppression: String, CaseIterable, Equatable, Sendable, Error {
    /// Reduce Motion (macOS, or Settings › Appearance): still Spool, no travel.
    case unconfirmed
    /// The measured line layout changed after settling or cannot be joined continuously.
    case geometryChanged
    case reduceMotion
    /// No verified caret rectangle at the pre-insertion point: no Accessibility, no selection, a range
    /// the app will not measure, a rect off every display, or no preview sample to start from.
    case caretUnavailable
    /// The destination is no longer the element and caret the final preview was aimed at.
    case targetChanged
    /// A password field.
    case secureField
    /// The caret is on another display than Spool's mouth.
    case otherDisplay
    /// Spool's mouth is not on screen (the pill is not drawn in a window).
    case mouthUnavailable
}

/// One read of the destination, as the flight sees it: which element, where its selection is, and
/// whether it is a password field.
struct TapeFlightProbe: Equatable, Sendable {
    var focus: FocusSnapshot?
    /// UTF-16 units, as AX reports it.
    var selection: Range<Int>?
    var isSecure: Bool

    init(focus: FocusSnapshot?, selection: Range<Int>?, isSecure: Bool = false) {
        self.focus = focus
        self.selection = selection
        self.isSecure = isSecure
    }
}

/// The pre-insertion destination, sampled while the final preview is up (before any write): the
/// element and the caret the text will go in at.
struct TapeFlightTarget: Equatable, Sendable {
    var pid: Int32
    var bundleID: String
    var elementToken: String?
    /// The selection when sampled; the text goes in at its lower bound (a selection is replaced).
    var selection: Range<Int>

    var insertionIndex: Int { selection.lowerBound }
}

/// What the preview sample found.
enum TapeFlightArming: Equatable, Sendable {
    case armed(TapeFlightTarget)
    case refused(TapeFlightSuppression)
}

enum TapeFlightPlanner {
    /// The final preview's sample. A password field or an element with no readable caret refuses the
    /// flight up front; nothing is aimed at a guessed point later.
    static func arm(_ probe: TapeFlightProbe) -> TapeFlightArming {
        if probe.isSecure { return .refused(.secureField) }
        guard let focus = probe.focus, let selection = probe.selection, selection.lowerBound >= 0 else {
            return .refused(.caretUnavailable)
        }
        return .armed(TapeFlightTarget(pid: focus.pid, bundleID: focus.bundleID, elementToken: focus.elementToken,
                                       selection: selection))
    }

    /// Is `now` still the destination the preview armed? Same app, process and element; not secure; and
    /// the caret either untouched (the write has not landed yet) or inside the text this very write put
    /// there (it has). Anything else is a changed target: the flight is suppressed, never re-aimed.
    static func verify(_ arming: TapeFlightArming?, now: TapeFlightProbe, insertedLength: Int)
        -> Result<TapeFlightTarget, TapeFlightSuppression> {
        let target: TapeFlightTarget
        switch arming {
        case .none: return .failure(.caretUnavailable)
        case .refused(let reason)?: return .failure(reason)
        case .armed(let armed)?: target = armed
        }
        if now.isSecure { return .failure(.secureField) }
        guard let focus = now.focus, focus.pid == target.pid, focus.bundleID == target.bundleID,
              focus.elementToken == target.elementToken else { return .failure(.targetChanged) }
        guard let selection = now.selection else { return .failure(.caretUnavailable) }
        if selection == target.selection { return .success(target) }
        let written = target.insertionIndex ... target.insertionIndex + Swift.max(0, insertedLength)
        if selection.isEmpty, written.contains(selection.lowerBound) { return .success(target) }
        return .failure(.targetChanged)
    }
}

/// Where the ribbon runs, in one display's overlay space: points, top-left origin, y down — the
/// prototype's `#desktop` space, which `SpoolFlight.frame(t:from:to:width:height:)` is written in.
struct TapeFlightPath: Equatable, Sendable {
    var display: DisplayFrame
    /// Spool's mouth.
    var from: CGPoint
    /// The centre of the verified caret rectangle (the prototype aims at the caret's centre).
    var to: CGPoint
    /// Verified line underlines in overlay coordinates; no guessed wrapping.
    var lines: [SpoolFlight.Line] = []
    var verified = false

    var size: CGSize { display.frame.size }

    /// The prototype's `flight(t, from, to, w, h)`; `nil` before it starts and once the tail has fed in.
    /// `mouth` replaces `from` when the pill moved since the path was planned.
    func frame(t: Double, mouth: CGPoint? = nil) -> SpoolFlight.Frame? {
        let source = mouth ?? from
        if !lines.isEmpty {
            return SpoolFlight.frame(t: t, from: SpoolPoint(Double(source.x), Double(source.y)), lines: lines,
                                     width: Double(size.width), height: Double(size.height), verified: verified)
        }
        return SpoolFlight.frame(t: t, from: SpoolPoint(Double(source.x), Double(source.y)),
                                 to: SpoolPoint(Double(to.x), Double(to.y)),
                                 width: Double(size.width), height: Double(size.height))
    }
}

enum TapeFlightGeometry {
    /// The display a point is on; `nil` in a gap of the arrangement or off every display (untrustworthy
    /// geometry — never the nearest display, which would be a guess).
    static func display(containing point: CGPoint, in displays: [DisplayFrame]) -> DisplayFrame? {
        displays.first { $0.frame.contains(point) }
    }

    /// The display whose Cocoa frame starts at the global origin: AX's y axis runs down from its top.
    static func primary(_ displays: [DisplayFrame]) -> DisplayFrame? {
        displays.first { $0.frame.origin == .zero } ?? displays.first
    }

    /// An AX rect (Quartz global: top-left of the primary display, y down) in AppKit screen coordinates.
    static func appKitRect(fromAX rect: CGRect, displays: [DisplayFrame]) -> CGRect? {
        guard let primary = primary(displays) else { return nil }
        return RepairFanoutModel.appKitRect(fromAX: rect, primaryScreenHeight: primary.frame.height)
    }

    /// An AppKit screen point in `display`'s overlay space (top-left origin, y down, points). Backing
    /// scale plays no part: AppKit, AX and the overlay all measure in points.
    static func local(_ point: CGPoint, in display: DisplayFrame) -> CGPoint {
        CGPoint(x: point.x - display.frame.minX, y: display.frame.maxY - point.y)
    }

    /// Where the ribbon ends: the caret rectangle's centre.
    static func caretPoint(_ rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX, y: rect.midY)
    }

    /// The path from the mouth (AppKit screen point) to the caret (AX rect), or why there is none.
    static func path(mouth: CGPoint?, caretAX: CGRect?, displays: [DisplayFrame]) -> Result<TapeFlightPath, TapeFlightSuppression> {
        guard let caretAX, caretAX.height > 0, caretAX.width >= 0,
              [caretAX.minX, caretAX.minY, caretAX.width, caretAX.height].allSatisfy(\.isFinite),
              let caret = appKitRect(fromAX: caretAX, displays: displays) else { return .failure(.caretUnavailable) }
        let end = caretPoint(caret)
        guard let caretDisplay = display(containing: end, in: displays) else { return .failure(.caretUnavailable) }
        guard let mouth, mouth.x.isFinite, mouth.y.isFinite,
              let mouthDisplay = display(containing: mouth, in: displays) else { return .failure(.mouthUnavailable) }
        guard mouthDisplay.id == caretDisplay.id, mouthDisplay.frame == caretDisplay.frame else {
            return .failure(.otherDisplay)
        }
        return .success(TapeFlightPath(display: caretDisplay, from: local(mouth, in: caretDisplay),
                                       to: local(end, in: caretDisplay)))
    }
}

/// Prefer the measured insertion caret, preserving its RTL affinity. Apps without caret bounds fall
/// back to the following character's left edge, then the previous character's right edge. Every
/// returned rectangle comes from AX; missing or invalid geometry never creates a destination.
enum TapeFlightCaretLocator {
    static func locate(at index: Int, bounds: (Range<Int>) -> CGRect?) -> CGRect? {
        guard index >= 0 else { return nil }
        // A real insertion caret preserves RTL affinity; a character's left edge cannot.
        if let caret = measured(bounds(index ..< index)), caret.width <= 2 { return caret }
        if let after = measured(bounds(index ..< index + 1)), after.width > 0 {
            return CGRect(x: after.minX, y: after.minY, width: 0, height: after.height)
        }
        if index > 0, let before = measured(bounds(index - 1 ..< index)), before.width > 0 {
            return CGRect(x: before.maxX, y: before.minY, width: 0, height: before.height)
        }
        return nil
    }

    private static func measured(_ rect: CGRect?) -> CGRect? {
        guard let rect, rect.height > 0, rect.width >= 0,
              [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite) else { return nil }
        return rect
    }
}
