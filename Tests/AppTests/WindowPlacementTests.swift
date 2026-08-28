import CoreGraphics
import Testing
@testable import VoicePlusApp

/// FIX 1 regression cover: onboarding (and the pre-prompt / enrollment windows) used
/// `NSWindow.center()`, which centres on `NSScreen.main`. On the reporting user's machine that was
/// an AirPlay display running a full-screen Space: the window landed at (2759, 30) with
/// `isOnScreen == false` — the app was running with no visible window and no way in.
///
/// Screen values are the ones measured on that machine (built-in 1800x1169 with a 38 pt housing,
/// external 1920x1080 to its right).
@Suite("App window placement (FIX 1)")
struct WindowPlacementTests {
    let builtIn = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1800, height: 1169),
                                topInset: 38, notchWidth: 220, menuBarHeight: 39,
                                visibleFrame: CGRect(x: 0, y: 0, width: 1800, height: 1130))
    /// External display to the right of the built-in, carrying a normal menu bar.
    let external = ScreenMetrics(frame: CGRect(x: 1800, y: 89, width: 1920, height: 1080),
                                 topInset: 0, notchWidth: nil, menuBarHeight: 30,
                                 visibleFrame: CGRect(x: 1800, y: 89, width: 1920, height: 1050))
    /// The same external display while a full-screen Space is active: no menu bar in the
    /// visibleFrame delta, and it is what AppKit reports as `NSScreen.main`.
    let fullScreenExternal = ScreenMetrics(frame: CGRect(x: 1800, y: 89, width: 1920, height: 1080),
                                           topInset: 0, notchWidth: nil, menuBarHeight: 0,
                                           visibleFrame: CGRect(x: 1800, y: 89, width: 1920, height: 1080))

    private let onboardingSize = CGSize(width: 720, height: 520)

    // MARK: - Which display

    @Test func singleBuiltInDisplayHostsTheWindow() throws {
        let host = try #require(WindowPlacement.hostScreen(screens: [builtIn], main: builtIn))
        #expect(host == builtIn)
    }

    /// The reported configuration: the external display is `NSScreen.main`, so `center()` put the
    /// window there. Placement must ignore `main` and pick the built-in panel.
    @Test func externalAsMainScreenDoesNotStealTheWindow() throws {
        let host = try #require(WindowPlacement.hostScreen(screens: [builtIn, external], main: external))
        #expect(host == builtIn)
        let f = WindowPlacement.frame(size: onboardingSize, on: host)
        #expect(builtIn.usableFrame.contains(f))
        #expect(!external.frame.intersects(f))
    }

    /// The exact dead end: external is main *and* running a full-screen Space. Same answer.
    @Test func fullScreenSpaceOnTheExternalDisplayNeverGetsTheWindow() throws {
        let host = try #require(WindowPlacement.hostScreen(screens: [builtIn, fullScreenExternal],
                                                           main: fullScreenExternal))
        #expect(host == builtIn)
        let f = WindowPlacement.frame(size: onboardingSize, on: host)
        // The frame the user could not see was (2759, 30, 720, 520) — off the built-in entirely.
        #expect(f.minX < 1800)
        #expect(builtIn.usableFrame.contains(f))
    }

    /// Clamshell / display-less-built-in: the primary display (global origin) wins, then any screen.
    @Test func primaryDisplayWinsWhenNothingIsNotched() throws {
        let primary = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), menuBarHeight: 25,
                                    visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055))
        let host = try #require(WindowPlacement.hostScreen(screens: [external, primary], main: external))
        #expect(host == primary)
        #expect(WindowPlacement.hostScreen(screens: [external], main: external) == external)
        #expect(WindowPlacement.hostScreen(screens: [], main: external) == external)
        #expect(WindowPlacement.hostScreen(screens: [], main: nil) == nil)
    }

    // MARK: - Where on that display

    @Test func windowIsCentredInsideTheVisibleFrame() {
        let f = WindowPlacement.frame(size: onboardingSize, on: builtIn)
        #expect(f == CGRect(x: 540, y: 305, width: 720, height: 520))
        #expect(f.maxY <= builtIn.frame.maxY - builtIn.topBand) // clears the camera housing
        #expect(builtIn.usableFrame.contains(f))
    }

    /// A window bigger than the usable area is shrunk to fit instead of hanging off an edge
    /// (a title bar under the menu bar is another way to lose a window).
    @Test func oversizedWindowIsClampedInsideTheVisibleFrame() {
        let small = ScreenMetrics(frame: CGRect(x: 400, y: 200, width: 640, height: 480),
                                  menuBarHeight: 24,
                                  visibleFrame: CGRect(x: 400, y: 200, width: 640, height: 456))
        let f = WindowPlacement.frame(size: CGSize(width: 1200, height: 900), on: small)
        #expect(f == small.usableFrame)
        #expect(small.usableFrame.contains(f))
    }

    /// Without a known visibleFrame the fallback still keeps the window clear of the notch band.
    @Test func fallbackUsableFrameExcludesTheTopBand() {
        let noVisible = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1800, height: 1169),
                                      topInset: 38, notchWidth: 220, menuBarHeight: 39)
        #expect(noVisible.usableFrame == CGRect(x: 0, y: 0, width: 1800, height: 1130))
        let f = WindowPlacement.frame(size: onboardingSize, on: noVisible)
        #expect(f.maxY <= noVisible.frame.maxY - noVisible.topBand)
        #expect(!f.intersects(noVisible.notchRect!))
    }
}
