#if canImport(AppKit)
import AppKit
#endif
import CoreGraphics
import Foundation

/// How tall the onboarding window is allowed to be.
///
/// Until 1.7.1 `OnboardingView` carried a hard `.frame(width: 520, height: 420)`. That size suits a
/// step at rest and nothing else: the moment a model download starts, the model step gains a bar, a
/// wrapping progress line, a Cancel button, an info line and a two-line amber warning, and the
/// content grew past the frame — the window does not scroll, so the *bottom* of the layout (the
/// Back / Skip / Continue row, the only way forward) was clipped in half.
///
/// The fix is to let each step report the height it actually needs and to size the window to that,
/// clamped to the display. This type owns the arithmetic so it can be tested without a window
/// server, which is the only way it can be tested at all on this toolchain.
public enum OnboardingWindowSizing {
    /// Fixed width. Wide enough that the option subtitles read in full rather than truncating
    /// mid-sentence, and the window never reflows horizontally while a step changes.
    public static let contentWidth: CGFloat = 600

    /// The step area never collapses below this, so short steps (welcome, done) still look like a
    /// wizard rather than a tooltip.
    public static let minimumStepHeight: CGFloat = 260

    /// The step area is the only part allowed to shrink when the display is short. It keeps at least
    /// this much — below it, the step scrolls. The chrome (progress bar + action row) is never
    /// squeezed, which is what guarantees Back / Skip / Continue stay on screen.
    public static let minimumScrollHeight: CGFloat = 80

    /// Outer padding (24 top + 24 bottom) plus the two 16pt gaps of the root `VStack`.
    public static let fixedChromeInsets: CGFloat = 24 * 2 + 16 * 2

    /// Reserved height for a row's download progress line. The text changes on every tick
    /// ("95 MB of 900 MB (11%), about 3 min left" → "96 MB…"), and a line that changes its own
    /// height would resize the window several times a second. Reserving space makes the tick a text
    /// change and nothing more.
    public static let downloadLineHeight: CGFloat = 46

    /// Height the window's *content view* should take.
    ///
    /// - Parameters:
    ///   - stepHeight: the fitting height the current step reported.
    ///   - chromeHeight: measured height of the progress bar plus the action row.
    ///   - usableHeight: the host screen's usable (visible) height.
    public static func contentHeight(stepHeight: CGFloat,
                                     chromeHeight: CGFloat,
                                     usableHeight: CGFloat) -> CGFloat {
        let chrome = max(chromeHeight, 0) + fixedChromeInsets
        let step = max(stepHeight, minimumStepHeight)
        let desired = (chrome + step).rounded(.up)
        // Never taller than the display — but never so short that the action row is squeezed out
        // either. On a display too small for both, the floor wins and the step scrolls.
        let ceiling = max(usableHeight, chrome + minimumScrollHeight)
        return min(desired, ceiling).rounded(.up)
    }

    /// Full content size for a step.
    public static func contentSize(stepHeight: CGFloat,
                                   chromeHeight: CGFloat,
                                   usableFrame: CGRect) -> CGSize {
        CGSize(width: min(contentWidth, max(usableFrame.width, 1)),
               height: contentHeight(stepHeight: stepHeight,
                                     chromeHeight: chromeHeight,
                                     usableHeight: usableFrame.height))
    }

    /// Whether a newly measured height is worth acting on. SwiftUI republishes geometry constantly
    /// (and progress text is re-laid-out on every tick); resizing the window for a sub-point
    /// difference is visible as jitter. Anything smaller than `tolerance` is noise.
    public static func shouldResize(from current: CGFloat, to proposed: CGFloat,
                                    tolerance: CGFloat = 1) -> Bool {
        abs(proposed - current) >= tolerance
    }

    /// Room the titled window's own chrome takes outside the content view, plus a little slack so a
    /// window that grows mid-step never ends up flush against the bottom of the display.
    public static let windowChromeAllowance: CGFloat = 28 + 12

    /// The area the *content view* may occupy on a given display. Pure, so the clamping can be
    /// tested without a window server: `usableFrame` minus the titlebar the content does not own.
    public static func contentArea(on screen: ScreenMetrics?) -> CGRect {
        guard let screen else {
            // No display info at all (headless test host): fall back to the pre-1.7.1 fixed height,
            // which at least cannot be *smaller* than what shipped.
            return CGRect(x: 0, y: 0, width: contentWidth, height: 420)
        }
        let area = screen.usableFrame
        return CGRect(x: area.minX, y: area.minY,
                      width: area.width,
                      height: max(area.height - windowChromeAllowance, minimumStepHeight))
    }

    #if canImport(AppKit)
    /// The content area on the display onboarding actually opens on. Deliberately the *same* screen
    /// choice `WindowPlacement` makes, so the height we size to and the display we are placed on can
    /// never disagree.
    @MainActor public static func usableFrame() -> CGRect {
        let screens = NSScreen.screens.map(PillPanelController.metrics(for:))
        let main = NSScreen.main.map(PillPanelController.metrics(for:))
        return contentArea(on: WindowPlacement.hostScreen(screens: screens, main: main))
    }
    #endif

    /// The step area's height once the window has been clamped: whatever is left after the chrome.
    /// Always ≥ `minimumScrollHeight`, which is the invariant "the action row is never clipped".
    public static func availableStepHeight(contentHeight: CGFloat, chromeHeight: CGFloat) -> CGFloat {
        let chrome = max(chromeHeight, 0) + fixedChromeInsets
        return max(contentHeight - chrome, minimumScrollHeight)
    }
}
