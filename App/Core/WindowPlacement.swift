import AppKit
import CoreGraphics
import Shared

/// Where a *regular* (titled) window opens — onboarding, the permission pre-prompt, voice enrollment.
///
/// `NSWindow.center()` centres on `NSScreen.main`, which is "whichever screen had the key window
/// when the app launched", not the screen the user is looking at. On a machine with an AirPlay or
/// external display attached, a background-launched agent app could therefore put its onboarding
/// window on a display running a full-screen Space, where it is never composited: the app is up,
/// the window exists at some off-display origin with `isOnScreen == false`, and the user has no way
/// in. That is indistinguishable from "the app is broken".
///
/// The rule: pin app windows to the display that carries the menu bar / camera housing (the
/// built-in, primary display), clamp the frame fully inside that display's usable area, and order
/// front on whatever Space is active right now.
public enum WindowPlacement {
    /// Pick the display an app window must open on, in order:
    /// 1. a notched display — the built-in panel of a modern MacBook, always physically present;
    /// 2. the display at the global origin — the primary display, the one carrying the menu bar;
    /// 3. any attached display; only then 4. `main` (whatever had focus), which is the value that
    ///    caused the bug and so is the last resort rather than the first choice.
    public static func hostScreen(screens: [ScreenMetrics], main: ScreenMetrics? = nil) -> ScreenMetrics? {
        screens.first(where: \.hasNotch)
            ?? screens.first { $0.frame.origin == .zero }
            ?? screens.first
            ?? main
    }

    /// Centre `size` in the host screen's usable area (`visibleFrame` when known — menu bar, notch
    /// and Dock excluded) and clamp so the whole window is inside it. A window larger than the area
    /// is shrunk to fit rather than allowed to hang off an edge.
    public static func frame(size: CGSize, on screen: ScreenMetrics) -> CGRect {
        let area = screen.usableFrame
        let width = min(max(size.width, 0), area.width)
        let height = min(max(size.height, 0), area.height)
        let x = min(max(area.midX - width / 2, area.minX), area.maxX - width)
        let y = min(max(area.midY - height / 2, area.minY), area.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// AppKit glue: place `window` per the rule above and bring it forward on the active Space.
    /// Replaces `NSWindow.center()` + `makeKeyAndOrderFront` at every app-window call site.
    /// Main-thread only (every caller already is; `PrePromptWindow.present` is nonisolated).
    public static func place(_ window: NSWindow, label: String, activate: Bool = true) {
        let screens = NSScreen.screens.map(PillPanelController.metrics(for:))
        let main = NSScreen.main.map(PillPanelController.metrics(for:))
        guard let host = hostScreen(screens: screens, main: main) else {
            window.center()
            window.makeKeyAndOrderFront(nil)
            return
        }
        let placed = frame(size: intendedSize(of: window), on: host)
        window.setFrame(placed, display: true)
        // Without `.moveToActiveSpace` the window is ordered front on the Space it was created on;
        // if that Space is a full-screen app on another display the user never sees it.
        window.collectionBehavior.insert(.moveToActiveSpace)
        if activate { NSApp.activate(ignoringOtherApps: true) }
        window.makeKeyAndOrderFront(nil)
        // SwiftUI can resize the window when it is first displayed; keep it centred on the host
        // screen at whatever size it settled on (position only — never fight the content's size).
        if window.frame.size != placed.size {
            window.setFrameOrigin(frame(size: window.frame.size, on: host).origin)
        }
        Log.app.info("""
            window placement: \(label) frame=\(NSStringFromRect(window.frame)) \
            screen=\(window.screen?.localizedName ?? "none") visible=\(window.isVisible) \
            onscreen=\(window.occlusionState.contains(.visible)) \
            displays=\(NSScreen.screens.map { $0.localizedName }.joined(separator: ", "))
            """)
        // `occlusionState` is only meaningful once the window server has composited the window, so
        // the "is it actually on screen?" half of the diagnostic has to come a beat later. This is
        // the line that told us the 1.6.0 onboarding window was never visible.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak window] in
            guard let window else { return }
            Log.app.info("""
                window settled: \(label) frame=\(NSStringFromRect(window.frame)) \
                screen=\(window.screen?.localizedName ?? "none") visible=\(window.isVisible) \
                onscreen=\(window.occlusionState.contains(.visible)) key=\(window.isKeyWindow)
                """)
        }
    }

    /// The size to place. A window built from an `NSHostingController` has a 1x0 frame until it is
    /// first laid out, and blindly centring *that* is its own invisible-window bug — measure the
    /// content instead.
    static func intendedSize(of window: NSWindow) -> CGSize {
        let current = window.frame.size
        if current.width >= 2, current.height >= 2 { return current }
        let view = window.contentViewController?.view ?? window.contentView
        view?.layoutSubtreeIfNeeded()
        let fitting = view?.fittingSize ?? .zero
        guard fitting.width >= 2, fitting.height >= 2 else { return CGSize(width: 480, height: 320) }
        return window.frameRect(forContentRect: CGRect(origin: .zero, size: fitting)).size
    }
}
