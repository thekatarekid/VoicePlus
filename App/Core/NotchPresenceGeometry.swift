import CoreGraphics
import Foundation

/// P5 — pure placement math for the persistent presence indicator ("the notch chin").
///
/// ONE RULE, shared verbatim with the pill: the indicator's **top edge is the bottom of the
/// display's forbidden top band** (`ScreenMetrics.topBand`). That single invariant is what keeps it
/// out from under the camera housing on a notched MacBook — there is no panel behind the housing,
/// so anything drawn there is simply never seen — and hangs it just below the menu bar everywhere
/// else. `NotchPresenceTests.sharesTheTopBoundaryWithThePill` asserts
/// `presence.maxY == NotchGeometry.layout(for:).shown.maxY` on every fixture, so the two surfaces
/// can never drift apart.
///
/// Deliberately *not* `NotchGeometry.layout(for:size:)`: that one widens the pill to at least
/// `notchWidth + 24` so it reads as attached to the notch. The indicator wants the opposite — at
/// rest it is a 4 pt hairline narrower than the housing, so it reads as a shadow of the bezel
/// rather than as a piece of UI.
public enum PresenceGeometry {
    public struct Layout: Equatable, Sendable {
        /// Where the panel goes (global, bottom-left origin coordinates).
        public var frame: CGRect
        /// Pointer inside this rect counts as hovering (see `PresenceInteraction`).
        public var hoverRect: CGRect
        /// Bottom corners only, like the pill.
        public var cornerRadius: CGFloat
        /// False when the state is `.off` — nothing is ordered in at all.
        public var visible: Bool
    }

    // MARK: - Sizes (measured against real hardware, 2026-09-06; see NotchPresenceTests)

    /// Idle: a hairline chin hanging off the bottom of the band. Unobtrusive by construction.
    public static let restSize = CGSize(width: 76, height: 4)
    /// Mic open / processing: tall enough to carry a level bar.
    public static let activeSize = CGSize(width: 120, height: 10)
    /// Muted: a persistent, legible badge. A hidden hot mic is the one thing that must never ship,
    /// so this state is never shrunk and never suppressed.
    public static let mutedSize = CGSize(width: 84, height: 16)
    /// Blocked: room for a short reason — "Mic off", "Relaunch", "42%".
    public static let blockedSize = CGSize(width: 132, height: 16)
    /// Pointer is on it: the full "VoicePlus · Ready — hold Right ⌥" row.
    public static let hoverSize = CGSize(width: 190, height: 24)

    /// Horizontal margin kept from the edges of a narrow display (same value as the pill's).
    static let edgeMargin: CGFloat = 8
    /// Slop around the resting chin that still counts as "pointing at it".
    public static let hoverSlop: CGFloat = 8

    public static func size(for state: PresenceState, hovered: Bool = false) -> CGSize {
        if hovered { return hoverSize }
        switch state {
        case .off: return .zero
        case .ready: return restSize
        case .listening, .processing: return activeSize
        case .muted: return mutedSize
        case .paused, .blocked: return blockedSize
        }
    }

    /// The one rule, applied. Centres `size` horizontally, hangs it off the bottom of the top band,
    /// and clamps it inside the display (a display narrower than the indicator shrinks it rather
    /// than letting it hang off an edge).
    public static func frame(size requested: CGSize, on metrics: ScreenMetrics) -> CGRect {
        var size = requested
        size.width = min(size.width, max(16, metrics.frame.width - 2 * edgeMargin))
        size.height = min(size.height, max(1, metrics.frame.height - metrics.topBand - edgeMargin))

        let topBoundary = metrics.frame.maxY - metrics.topBand
        var x = metrics.frame.midX - size.width / 2
        let minX = metrics.frame.minX + edgeMargin
        let maxX = metrics.frame.maxX - size.width - edgeMargin
        if maxX >= minX { x = min(max(x, minX), maxX) }
        return CGRect(x: x, y: topBoundary - size.height, width: size.width, height: size.height)
    }

    /// Hover target: the resting chin unioned with the expanded row (so the pointer does not fall
    /// out of the region the instant the panel grows and start a collapse/expand flicker), inflated
    /// by `hoverSlop`, unioned with the camera housing itself — pointing at the notch reveals it.
    public static func hoverRect(on metrics: ScreenMetrics) -> CGRect {
        var rect = frame(size: restSize, on: metrics)
            .union(frame(size: hoverSize, on: metrics))
            .insetBy(dx: -hoverSlop, dy: -hoverSlop)
        if let notch = metrics.notchRect { rect = rect.union(notch) }
        return rect
    }

    public static func layout(for metrics: ScreenMetrics, state: PresenceState, hovered: Bool = false) -> Layout {
        guard state != .off else {
            return Layout(frame: .zero, hoverRect: hoverRect(on: metrics), cornerRadius: 0, visible: false)
        }
        return Layout(frame: frame(size: size(for: state, hovered: hovered), on: metrics),
                      hoverRect: hoverRect(on: metrics),
                      cornerRadius: hovered ? 10 : min(6, size(for: state, hovered: hovered).height / 2),
                      visible: true)
    }

    /// True when `rect` is drawable: on the display, and not behind the camera housing.
    public static func clearsHousing(_ rect: CGRect, on metrics: ScreenMetrics) -> Bool {
        guard metrics.frame.contains(rect) else { return false }
        guard let housing = metrics.notchRect else { return true }
        return !rect.intersects(housing)
    }

    /// Every frame the indicator can ever occupy on this display — what the startup diagnostic logs
    /// and what the housing guard checks.
    public static func allFrames(on metrics: ScreenMetrics) -> [(name: String, rect: CGRect)] {
        [("rest", frame(size: restSize, on: metrics)),
         ("active", frame(size: activeSize, on: metrics)),
         ("muted", frame(size: mutedSize, on: metrics)),
         ("blocked", frame(size: blockedSize, on: metrics)),
         ("hover", frame(size: hoverSize, on: metrics))]
    }
}

/// Click/focus policy, pulled out as pure logic so the "it can never swallow a click" guarantee is
/// a unit test rather than a claim in a comment.
public enum PresenceInteraction {
    /// The panel ignores the mouse at all times except while the pointer is actually on it.
    public static func ignoresMouse(hovering: Bool) -> Bool { !hovering }

    public static func isHovering(mouse: CGPoint, on metrics: ScreenMetrics) -> Bool {
        PresenceGeometry.hoverRect(on: metrics).contains(mouse)
    }

    /// Full-screen detection with no private API: the menu bar's `visibleFrame` delta collapses to
    /// 0 in a full-screen Space. A display that has *never* shown a menu bar (a secondary display
    /// with "Displays have separate Spaces" off) is not full screen — it simply has no menu bar, so
    /// a zero delta there means nothing and must not be read as one.
    public static func menuBarPresent(current: CGFloat, everObserved: CGFloat) -> Bool {
        current > 0 || everObserved <= 0
    }
}
