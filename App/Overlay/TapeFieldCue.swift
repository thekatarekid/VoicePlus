import Actions
import CoreGraphics
import Foundation

/// S4 / design §13 scenario 4 — the ordinary destination tape cue: the prototype's `.field-line`, a flat
/// tape-coloured line drawn under the text that just landed, which fades while any uncertainty mark stays.
///
/// Prototype (`design/design_v1.html`): `.field-line{height:3px;background:var(--tape-face);
/// border-top:1px solid var(--tape-edge);width:100%;margin-top:6px;animation:linefade 1.2s forwards}`,
/// `@keyframes linefade{0%,65%{opacity:1}100%{opacity:0}}`, removed after 1200 ms. Here the width is the
/// landed text's own measured width (the prototype's field is exactly that text block), 6 pt below it.
///
/// Drawn only after a flight that finished on a verified `.landed` (so never under Reduce Motion, in a
/// secure field, on another display or without a caret rect — the flight's own suppressions), in the
/// same pointer-transparent overlay, and never over a destination uncertainty mark.
struct TapeFieldCue: Equatable {
    /// `margin-top: 6px`.
    static let offset: CGFloat = 6
    /// `height: 3px`, of which the top 1 px is the tape-edge border.
    static let height: CGFloat = 3
    static let edge: CGFloat = 1
    /// `linefade 1.2s`, and the prototype's `setTimeout(…remove(), 1200)`.
    static let lifetime: TimeInterval = 1.2
    /// `0%, 65% { opacity: 1 }`.
    static let holdFraction = 0.65
    /// Clearance kept below a mark's strip when the cue has to step under it.
    static let markClearance: CGFloat = 1

    let id = UUID()
    let display: DisplayFrame
    /// In the display's overlay space: points, top-left origin, y down.
    let rect: CGRect
    let start: Date

    var end: Date { start.addingTimeInterval(Self.lifetime) }

    static func == (a: TapeFieldCue, b: TapeFieldCue) -> Bool {
        a.id == b.id
    }

    /// `linefade`: fully opaque for the first 65 %, then linear to 0 at 1.2 s.
    static func opacity(at t: TimeInterval) -> Double {
        guard t >= 0 else { return 0 }
        let hold = lifetime * holdFraction
        if t <= hold { return 1 }
        if t >= lifetime { return 0 }
        return 1 - (t - hold) / (lifetime - hold)
    }

    func opacity(at date: Date) -> Double { Self.opacity(at: date.timeIntervalSince(start)) }

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
