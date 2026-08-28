import CoreGraphics
import Testing
@testable import VoicePlusApp

/// FIX 2 regression cover: the meeting prompt positioned itself with `NSScreen.main` and
/// `screen.frame.maxY - height - 8`, so on a notched MacBook its top ~30 pt was drawn behind the
/// camera housing — the same class of bug as the pill's, fixed for the pill in 1.6.1 and still live
/// here. It must follow `ScreenMetrics.topBand` like everything else.
@Suite("Meeting prompt placement (FIX 2)")
struct MeetingPromptPlacementTests {
    let notched = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1800, height: 1169),
                                topInset: 38, notchWidth: 220, menuBarHeight: 39)
    /// Menu bar auto-hidden / full-screen Space: the visibleFrame delta collapses, the housing does not.
    let autoHiddenMenuBar = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1800, height: 1169),
                                          topInset: 38, notchWidth: 220, menuBarHeight: 0)
    /// Built-in panel placed to the right of an external display (not at the global origin).
    let notchedOffOrigin = ScreenMetrics(frame: CGRect(x: -1800, y: 200, width: 1800, height: 1169),
                                         topInset: 38, notchWidth: 220, menuBarHeight: 39)
    let external = ScreenMetrics(frame: CGRect(x: 1800, y: 89, width: 1920, height: 1080),
                                 topInset: 0, notchWidth: nil, menuBarHeight: 30)

    @Test func promptNeverIntersectsTheCameraHousing() throws {
        for metrics in [notched, autoHiddenMenuBar, notchedOffOrigin] {
            let housing = try #require(metrics.notchRect)
            let f = MeetingPromptPanel.frame(on: metrics)
            #expect(!f.intersects(housing))
            #expect(f.maxY <= metrics.frame.maxY - metrics.topBand)
            #expect(metrics.frame.contains(f))
            // The old formula: top edge 8 pt below the physical top of the display, i.e. inside it.
            let old = CGRect(x: metrics.frame.midX - 190, y: metrics.frame.maxY - 66 - 8, width: 380, height: 66)
            #expect(old.intersects(housing), "the pre-fix formula must be the thing this test rules out")
        }
    }

    @Test func promptSitsUnderTheMenuBarOnANotchlessDisplay() {
        let f = MeetingPromptPanel.frame(on: external)
        #expect(f.maxY == 1139)             // frame.maxY 1169 - 30 pt menu bar
        #expect(f.size == MeetingPromptPanel.panelSize)
        #expect(f.midX == external.frame.midX)
        #expect(external.frame.contains(f))
    }

    @Test func promptIsClampedOnANarrowDisplay() {
        let tiny = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 320, height: 600), menuBarHeight: 24)
        let f = MeetingPromptPanel.frame(on: tiny)
        #expect(tiny.frame.contains(f))
        #expect(f.width <= tiny.frame.width)
    }
}
