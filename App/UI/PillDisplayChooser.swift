import AppKit
import ApplicationServices
import Shared

/// V5 Q6 — the pill follows the work. Which display hosts the pill for a turn is decided by where
/// the user is working, in this order: the screen holding the text caret, the screen holding the
/// focused window, the active (key-window) screen, and only then the screen under the mouse.
public enum PillDisplayChooser {
    /// Pure rule: the first non-nil rung wins.
    public static func choose(caretScreen: ScreenMetrics?, focusedWindowScreen: ScreenMetrics?,
                              activeScreen: ScreenMetrics?, mouseScreen: ScreenMetrics?) -> ScreenMetrics? {
        caretScreen ?? focusedWindowScreen ?? activeScreen ?? mouseScreen
    }

    /// The screen holding a global (bottom-left origin) point, with inclusive top/right edges so a
    /// pointer pinned to the very top of the laptop (`y == maxY`) resolves to the laptop. A display
    /// that strictly contains the point always wins over one that only touches it on an edge.
    public static func screen(containing point: CGPoint, in screens: [ScreenMetrics]) -> ScreenMetrics? {
        if let strict = screens.first(where: { $0.frame.contains(point) }) { return strict }
        return screens.first { f in
            let r = f.frame
            return point.x >= r.minX && point.x <= r.maxX && point.y >= r.minY && point.y <= r.maxY
        }
    }

    /// The screen holding most of a rect (a focused window may straddle two displays); its centre's
    /// display when nothing overlaps (zero-size caret rects).
    public static func screen(containing rect: CGRect, in screens: [ScreenMetrics]) -> ScreenMetrics? {
        guard rect.width > 0, rect.height > 0 else {
            return screen(containing: CGPoint(x: rect.midX, y: rect.midY), in: screens)
        }
        var best: ScreenMetrics?
        var bestArea: CGFloat = 0
        for candidate in screens {
            let overlap = candidate.frame.intersection(rect)
            guard !overlap.isNull else { continue }
            let area: CGFloat = overlap.width * overlap.height
            if area > bestArea { best = candidate; bestArea = area }
        }
        return best ?? screen(containing: CGPoint(x: rect.midX, y: rect.midY), in: screens)
    }

    /// AX geometry is top-left origin relative to the primary display; AppKit is bottom-left.
    public static func appKitRect(fromAX rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Resolve every rung from raw global rects (AppKit coordinates) and choose.
    public static func choose(caretRect: CGRect?, focusedWindowFrame: CGRect?, activeScreen: ScreenMetrics?,
                              mouse: CGPoint, screens: [ScreenMetrics], main: ScreenMetrics?) -> ScreenMetrics? {
        choose(caretScreen: caretRect.flatMap { screen(containing: $0, in: screens) },
               focusedWindowScreen: focusedWindowFrame.flatMap { screen(containing: $0, in: screens) },
               activeScreen: activeScreen,
               mouseScreen: screen(containing: mouse, in: screens) ?? main ?? screens.first)
    }
}

/// Live probe for the chooser's rungs. Accessibility reads are bounded (50 ms messaging timeout) and
/// skip our own process; without the Accessibility grant the caret / window rungs are simply nil.
enum PillWorkLocator {
    static let messagingTimeout: Float = 0.05

    /// Caret and focused-window rects of the frontmost (non-VoicePlus) app, in AppKit coordinates.
    static func workRects() -> (caret: CGRect?, window: CGRect?) {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let primary = NSScreen.screens.first else { return (nil, nil) }
        let height = primary.frame.maxY
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, messagingTimeout)
        var caret: CGRect?
        if let element: AXUIElement = copy(axApp, kAXFocusedUIElementAttribute) {
            AXUIElementSetMessagingTimeout(element, messagingTimeout)
            caret = caretRect(of: element).map { PillDisplayChooser.appKitRect(fromAX: $0, primaryHeight: height) }
        }
        var window: CGRect?
        if let w: AXUIElement = copy(axApp, kAXFocusedWindowAttribute) {
            AXUIElementSetMessagingTimeout(w, messagingTimeout)
            window = frame(of: w).map { PillDisplayChooser.appKitRect(fromAX: $0, primaryHeight: height) }
        }
        return (caret, window)
    }

    private static func copy<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! T)
    }

    private static func caretRect(of element: AXUIElement) -> CGRect? {
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
        var bounds: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         rangeValue, &bounds) == .success,
              let bounds, CFGetTypeID(bounds) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(bounds as! AXValue, .cgRect, &rect), rect != .zero else { return nil }
        return rect
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        var pos: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
              let pos, let size, CFGetTypeID(pos) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(pos as! AXValue, .cgPoint, &p), AXValueGetValue(size as! AXValue, .cgSize, &s),
              s.width > 1, s.height > 1 else { return nil }
        return CGRect(origin: p, size: s)
    }
}
