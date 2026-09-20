import Actions
import CoreGraphics
import Foundation

/// V3 destination underline: identical oxide/copper material and geometry to the flying tape.
/// Each measured text line gets a 2.4 pt strip at +7 pt; hold55%, fade over1 second.
/// Only verified delivery can create it. Uncertainty marks remain independent.
struct TapeFieldCue: Equatable {
    /// V3 `lineGeometry`: text bottom +7pt.
    static let offset: CGFloat = 7
    /// Same thickness as the flattened flight.
    static let height: CGFloat = 2.4
    static let edge: CGFloat = 0.5
    /// V3 `settledfade 1s`.
    static let lifetime: TimeInterval = 1.0
    /// `0%,55% { opacity:1 }`.
    static let holdFraction = 0.55
    /// Clearance kept below a mark's strip when the cue has to step under it.
    static let markClearance: CGFloat = 1

    let id = UUID()
    let display: DisplayFrame
    /// In the display's overlay space: points, top-left origin, y down.
    let rects: [CGRect]
    var rect: CGRect { rects.first ?? .zero }
    let start: Date
    let reduced: Bool

    init(display: DisplayFrame, rect: CGRect, start: Date) {
        self.init(display: display, rects: [rect], start: start)
    }
    init(display: DisplayFrame, rects: [CGRect], start: Date, reduced: Bool = false) {
        self.display = display; self.rects = rects; self.start = start; self.reduced = reduced
    }

    var end: Date { start.addingTimeInterval(Self.lifetime) }

    static func == (a: TapeFieldCue, b: TapeFieldCue) -> Bool {
        a.id == b.id
    }

    /// Still for55%, then fades to zero.
    static func opacity(at t: TimeInterval) -> Double {
        guard t >= 0 else { return 0 }
        let hold = lifetime * holdFraction
        if t <= hold { return 1 }
        if t >= lifetime { return 0 }
        return 1 - (t - hold) / (lifetime - hold)
    }

    func opacity(at date: Date) -> Double {
        let t = date.timeIntervalSince(start)
        return reduced ? (t >= 0 && t < Self.lifetime ? 1 : 0) : Self.opacity(at: t)
    }

    /// The cue under `text` (overlay space), stepped down below every mark strip it would cross.
    static func rect(under text: CGRect, avoiding strips: [CGRect]) -> CGRect {
        var cue = CGRect(x: text.minX, y: text.maxY + offset, width: text.width, height: height)
        // Strips are few (one per uncertain fragment); each step only moves the cue down.
        var moved = true
        while moved {
            moved = false
            for strip in strips where strip.intersects(cue) {
                cue.origin.y = strip.maxY + markClearance
                moved = true
            }
        }
        return cue
    }

    /// Where the cue goes for the landed text (AX rect) on the flight's display, or why it is not drawn.
    /// `strips` are the destination uncertainty marks on screen (AppKit screen coordinates).
    static func plan(textAX: CGRect?, flightDisplay: DisplayFrame, displays: [DisplayFrame],
                     strips: [CGRect]) -> Result<CGRect, TapeFlightSuppression> {
        guard let textAX, textAX.width > 0, textAX.height > 0,
              [textAX.minX, textAX.minY, textAX.width, textAX.height].allSatisfy(\.isFinite),
              let text = TapeFlightGeometry.appKitRect(fromAX: textAX, displays: displays) else {
            return .failure(.caretUnavailable)
        }
        guard let display = TapeFlightGeometry.display(containing: CGPoint(x: text.midX, y: text.midY), in: displays) else {
            return .failure(.caretUnavailable)
        }
        guard display.id == flightDisplay.id, display.frame == flightDisplay.frame else { return .failure(.otherDisplay) }
        let local = TapeFlightGeometry.localRect(text, in: display)
        let marks = strips.map { TapeFlightGeometry.localRect($0, in: display) }
        return .success(rect(under: local, avoiding: marks))
    }
}

extension TapeFlightGeometry {
    /// An AppKit screen rect in `display`'s overlay space (top-left origin, y down, points).
    static func localRect(_ rect: CGRect, in display: DisplayFrame) -> CGRect {
        CGRect(x: rect.minX - display.frame.minX, y: display.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
}
