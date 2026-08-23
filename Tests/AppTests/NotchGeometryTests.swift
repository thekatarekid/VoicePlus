import CoreGraphics
import Testing
@testable import VoicePlusApp

@Suite("Notch geometry (T2)")
struct NotchGeometryTests {
    let notched = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), topInset: 32, notchWidth: 200, menuBarHeight: 32)
    let plain = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), topInset: 0, notchWidth: nil, menuBarHeight: 24)

    @Test func notchedScreenCentersUnderNotchAndGrowsToNotchWidth() {
        let l = NotchGeometry.layout(for: notched)
        #expect(l.shown.midX == 756)
        #expect(l.shown.maxY == 982)
        #expect(l.shown.width == 320) // wider than notch+24 already
        #expect(l.retracted.minY == 982)
        #expect(l.cornerRadius == 18)
        let narrow = NotchGeometry.layout(for: notched, size: CGSize(width: 100, height: 40))
        #expect(narrow.shown.width == 224)
    }

    @Test func plainScreenSitsBelowMenuBar() {
        let l = NotchGeometry.layout(for: plain)
        #expect(l.shown.maxY == 1056.0)
        #expect(l.shown.midX == 960)
        #expect(l.cornerRadius == 12)
        #expect(!plain.hasNotch)
    }

    @Test func sizeDependsOnState() {
        #expect(NotchGeometry.size(for: .preview(text: "x")) == NotchGeometry.expandedSize)
        #expect(NotchGeometry.size(for: .listening(level: 0)) == NotchGeometry.defaultSize)
    }

    @Test func hostScreenPrefersMouseScreen() {
        let second = ScreenMetrics(frame: CGRect(x: 1920, y: 0, width: 1000, height: 800))
        #expect(NotchGeometry.hostScreen(screens: [plain, second], mouse: CGPoint(x: 2000, y: 10), main: plain) == second)
        #expect(NotchGeometry.hostScreen(screens: [plain, second], mouse: CGPoint(x: -5, y: 10), main: plain) == plain)
        #expect(NotchGeometry.hostScreen(screens: [], mouse: .zero, main: nil) == nil)
    }
}
