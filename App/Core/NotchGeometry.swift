import CoreGraphics
import Foundation

/// Screen facts needed to place the pill, decoupled from `NSScreen` so tests can cover it.
public struct ScreenMetrics: Equatable, Sendable {
    /// Full screen frame in global (bottom-left origin) coordinates.
    public var frame: CGRect
    /// Height of the top safe-area inset (the notch) — 0 on notch-less displays.
    public var topInset: CGFloat
    /// Width of the notch cut-out if known (auxiliaryTopLeft/Right areas), else `nil`.
    public var notchWidth: CGFloat?
    /// Menu bar height (visibleFrame delta) for notch-less displays.
    public var menuBarHeight: CGFloat
    /// The screen's `visibleFrame` (menu bar, notch and Dock excluded) when known.
    public var visibleFrame: CGRect?

    public init(frame: CGRect, topInset: CGFloat = 0, notchWidth: CGFloat? = nil, menuBarHeight: CGFloat = 24,
                visibleFrame: CGRect? = nil) {
        self.frame = frame
        self.topInset = topInset
        self.notchWidth = notchWidth
        self.menuBarHeight = menuBarHeight
        self.visibleFrame = visibleFrame
    }

    public var hasNotch: Bool { topInset > 0 }

    /// Area a regular window may occupy: the real `visibleFrame` when known, else the frame minus
    /// the forbidden top band (better than nothing — a window placed here still clears the notch).
    public var usableFrame: CGRect {
        visibleFrame ?? CGRect(x: frame.minX, y: frame.minY, width: frame.width,
                               height: max(0, frame.height - topBand))
    }

    /// Band at the top of the display nothing may be drawn into: the camera-housing safe area on a
    /// notched built-in display, the menu bar otherwise. `max` matters — with the menu bar auto-hidden
    /// (or in a full-screen space) the visibleFrame delta collapses to 0 while `safeAreaInsets.top`
    /// stays at the housing height, and on an external display there is no inset but there is a menu bar.
    public var topBand: CGFloat { max(max(topInset, menuBarHeight), 0) }

    /// The physical camera housing in global coordinates; `nil` on notch-less displays.
    /// Nothing drawn inside this rect is visible — there is no panel behind it.
    public var notchRect: CGRect? {
        guard hasNotch, let width = notchWidth, width > 0 else { return nil }
        return CGRect(x: frame.midX - width / 2, y: frame.maxY - topInset, width: width, height: topInset)
    }
}

/// Pure placement math for the pill (T2 "notch-aware placement").
public enum NotchGeometry {
    public struct Layout: Equatable, Sendable {
        /// Pill frame when fully shown (global coordinates).
        public var shown: CGRect
        /// Pill frame when retracted (slides up behind the notch / menu bar).
        public var retracted: CGRect
        /// Corner radius for the bottom corners.
        public var cornerRadius: CGFloat
    }

    public static let defaultSize = CGSize(width: 320, height: 44)
    public static let expandedSize = CGSize(width: 420, height: 64)

    public static func size(for state: PillState) -> CGSize {
        switch state {
        case .preview, .warning, .unavailable, .transform: return expandedSize
        default: return defaultSize
        }
    }

    /// Chrome around the pill's text: icon column + horizontal padding + the script badge's slot.
    static let textChrome: CGFloat = 76

    /// Content-aware size: never narrower than `size(for:)`, widened to fit the state's own
    /// sentences, and clamped to the display. Without this a notice longer than the fixed 420 pt
    /// (a long "no speech model" reason, a localised string) is clipped with no state in which the
    /// user can read the end of it.
    public static func size(for state: PillState, on metrics: ScreenMetrics,
                            measure: (String) -> CGFloat) -> CGSize {
        var size = self.size(for: state)
        guard let widest = state.messageLines.map(measure).max() else { return size }
        let limit = max(64, metrics.frame.width - 2 * edgeMargin)
        size.width = min(max(size.width, widest + textChrome), limit)
        return size
    }

    /// Horizontal margin kept between the pill and the edges of a narrow display.
    static let edgeMargin: CGFloat = 8

    /// Centers the pill horizontally and hangs it off the bottom edge of the display's forbidden top
    /// band (`ScreenMetrics.topBand`), so it is never drawn beneath the camera housing on a notched
    /// MacBook and sits just below the menu bar everywhere else. The pill still spans at least the
    /// notch width so it reads as "attached to" the notch rather than floating under it.
    public static func layout(for metrics: ScreenMetrics, size requested: CGSize = defaultSize) -> Layout {
        var size = requested
        if let notchWidth = metrics.notchWidth, metrics.hasNotch {
            size.width = max(size.width, notchWidth + 24)
        }
        size.width = min(size.width, max(64, metrics.frame.width - 2 * edgeMargin))
        size.height = min(size.height, max(1, metrics.frame.height - metrics.topBand - edgeMargin))

        // The one rule: the pill's top edge is the bottom of the forbidden band.
        let topBoundary = metrics.frame.maxY - metrics.topBand
        var x = metrics.frame.midX - size.width / 2
        let minX = metrics.frame.minX + edgeMargin
        let maxX = metrics.frame.maxX - size.width - edgeMargin
        if maxX >= minX { x = min(max(x, minX), maxX) }

        let shown = CGRect(x: x, y: topBoundary - size.height, width: size.width, height: size.height)
        // Retract by rolling up to the band boundary rather than translating off the top of the screen:
        // a retracted frame above `topBoundary` would drag the pill straight through the camera housing
        // on every slide in/out.
        let retracted = CGRect(x: x, y: topBoundary - 1, width: size.width, height: 1)
        return Layout(shown: shown, retracted: retracted, cornerRadius: metrics.hasNotch ? 18 : 12)
    }

    /// Pick the screen that should host the pill: the one containing the mouse, else the main screen.
    public static func hostScreen(screens: [ScreenMetrics], mouse: CGPoint, main: ScreenMetrics?) -> ScreenMetrics? {
        screens.first { $0.frame.contains(mouse) } ?? main ?? screens.first
    }
}
