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

    public init(frame: CGRect, topInset: CGFloat = 0, notchWidth: CGFloat? = nil, menuBarHeight: CGFloat = 24) {
        self.frame = frame
        self.topInset = topInset
        self.notchWidth = notchWidth
        self.menuBarHeight = menuBarHeight
    }

    public var hasNotch: Bool { topInset > 0 }
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
        case .preview, .warning: return expandedSize
        default: return defaultSize
        }
    }

    /// Centers the pill under the notch (or at the top-center of the screen below the menu bar when there is
    /// no notch). With a notch the pill is at least as wide as the notch so it visually "grows" out of it.
    public static func layout(for metrics: ScreenMetrics, size requested: CGSize = defaultSize) -> Layout {
        var size = requested
        if let notchWidth = metrics.notchWidth, metrics.hasNotch {
            size.width = max(size.width, notchWidth + 24)
        }
        let centerX = metrics.frame.midX
        let top = metrics.frame.maxY
        let yOffset: CGFloat = metrics.hasNotch ? 0 : metrics.menuBarHeight
        let shown = CGRect(x: centerX - size.width / 2, y: top - yOffset - size.height, width: size.width, height: size.height)
        let retracted = CGRect(x: shown.minX, y: top, width: size.width, height: size.height)
        return Layout(shown: shown, retracted: retracted, cornerRadius: metrics.hasNotch ? 18 : 12)
    }

    /// Pick the screen that should host the pill: the one containing the mouse, else the main screen.
    public static func hostScreen(screens: [ScreenMetrics], mouse: CGPoint, main: ScreenMetrics?) -> ScreenMetrics? {
        screens.first { $0.frame.contains(mouse) } ?? main ?? screens.first
    }
}
