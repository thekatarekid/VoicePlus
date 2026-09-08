import CoreGraphics
import Shared
import Testing
@testable import VoicePlusApp

/// Geometry values below are measured from real hardware (2026-08-29, MacBook with camera housing +
/// AirPlay external display), so the regression guard matches the display the bug was reported on.
@Suite("Notch geometry (T2)")
struct NotchGeometryTests {
    /// Built-in Retina display: frame 1800x1169, safeAreaInsets.top 38, aux areas 790 pt wide each
    /// (housing 220 pt), visibleFrame.maxY 1130 (menu-bar delta 39).
    let notched = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1800, height: 1169),
                                topInset: 38, notchWidth: 220, menuBarHeight: 39)
    /// Same panel, but not at the global origin (built-in placed right of an external display).
    let notchedOffOrigin = ScreenMetrics(frame: CGRect(x: -1800, y: 200, width: 1800, height: 1169),
                                         topInset: 38, notchWidth: 220, menuBarHeight: 39)
    /// Notched panel with the menu bar auto-hidden / a full-screen space: the visibleFrame delta
    /// collapses to 0 but the camera housing does not go anywhere.
    let autoHiddenMenuBar = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1800, height: 1169),
                                          topInset: 38, notchWidth: 220, menuBarHeight: 0)
    /// External display carrying the menu bar.
    let external = ScreenMetrics(frame: CGRect(x: 1800, y: 89, width: 1920, height: 1080),
                                 topInset: 0, notchWidth: nil, menuBarHeight: 30)
    /// Secondary display with no menu bar ("Displays have separate Spaces" off).
    let externalNoMenuBar = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                          topInset: 0, notchWidth: nil, menuBarHeight: 0)

    // MARK: - The regression guard for the reported bug

    @Test func pillNeverIntersectsTheCameraHousing() throws {
        for metrics in [notched, notchedOffOrigin, autoHiddenMenuBar] {
            let housing = try #require(metrics.notchRect)
            for size in [NotchGeometry.defaultSize, NotchGeometry.expandedSize, CGSize(width: 100, height: 40)] {
                let l = NotchGeometry.layout(for: metrics, size: size)
                #expect(!l.shown.intersects(housing))      // nothing drawn behind the camera housing
                #expect(!l.retracted.intersects(housing))  // and not during the slide in/out either
                #expect(l.shown.maxY <= metrics.frame.maxY - metrics.topInset)
                #expect(metrics.frame.contains(l.shown))
            }
        }
    }

    // MARK: - Notched built-in display

    @Test func notchedPillHangsOffTheBottomOfTheTopBand() {
        #expect(notched.hasNotch)
        #expect(notched.topBand == 39)
        #expect(notched.notchRect == CGRect(x: 790, y: 1131, width: 220, height: 38))

        let l = NotchGeometry.layout(for: notched)
        #expect(l.shown == CGRect(x: 740, y: 1086, width: 320, height: 44))
        #expect(l.shown.maxY == 1130) // == visibleFrame.maxY, i.e. flush under the menu bar
        #expect(l.cornerRadius == 18)
        // Retracted rolls up to the band boundary instead of translating off the top of the screen.
        #expect(l.retracted == CGRect(x: 740, y: 1129, width: 320, height: 1))

        let expanded = NotchGeometry.layout(for: notched, size: NotchGeometry.expandedSize)
        #expect(expanded.shown == CGRect(x: 690, y: 1066, width: 420, height: 64))
        // A pill narrower than the notch still spans it (notch + 24).
        #expect(NotchGeometry.layout(for: notched, size: CGSize(width: 100, height: 40)).shown.width == 244)
    }

    @Test func notchedPillClearsTheHousingWithTheMenuBarHidden() {
        let l = NotchGeometry.layout(for: autoHiddenMenuBar)
        #expect(autoHiddenMenuBar.topBand == 38) // safe-area inset wins over the collapsed menu bar
        #expect(l.shown.maxY == 1131)            // exactly the bottom edge of the housing
        #expect(l.shown == CGRect(x: 740, y: 1087, width: 320, height: 44))
    }

    @Test func notchedPillOffTheGlobalOriginStaysOnItsOwnScreen() {
        let l = NotchGeometry.layout(for: notchedOffOrigin)
        #expect(l.shown == CGRect(x: -1060, y: 1286, width: 320, height: 44))
        #expect(l.shown.maxY == notchedOffOrigin.frame.maxY - notchedOffOrigin.topBand)
    }

    // MARK: - Non-notched displays

    @Test func externalDisplaySitsBelowTheMenuBar() {
        #expect(!external.hasNotch)
        #expect(external.notchRect == nil)
        let l = NotchGeometry.layout(for: external)
        #expect(l.shown.maxY == 1139) // frame.maxY 1169 - 30 pt menu bar
        #expect(l.shown.midX == 2760)
        #expect(l.shown.width == 320) // no notch, so no widening
        #expect(l.cornerRadius == 12)
        #expect(external.frame.contains(l.shown))
    }

    @Test func secondaryDisplayWithoutMenuBarSitsFlushWithTheTop() {
        let l = NotchGeometry.layout(for: externalNoMenuBar)
        #expect(externalNoMenuBar.topBand == 0)
        #expect(l.shown.maxY == 1080)
        #expect(l.retracted == CGRect(x: 800, y: 1079, width: 320, height: 1))
    }

    @Test func narrowDisplayClampsInsteadOfOverflowing() {
        let tiny = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 400, height: 600),
                                 topInset: 0, notchWidth: nil, menuBarHeight: 24)
        let l = NotchGeometry.layout(for: tiny, size: NotchGeometry.expandedSize)
        #expect(l.shown.width == 384)
        #expect(tiny.frame.contains(l.shown))
    }

    // MARK: - Display arrangement

    @Test func clamshellUsesTheExternalDisplayOnly() throws {
        // Lid closed: the built-in panel is absent from NSScreen.screens entirely.
        let host = try #require(NotchGeometry.hostScreen(screens: [external], mouse: CGPoint(x: 2500, y: 500), main: external))
        #expect(host == external)
        let l = NotchGeometry.layout(for: host)
        #expect(l.cornerRadius == 12)
        #expect(l.shown.maxY == 1139)
    }

    @Test func multiDisplayFollowsTheMouse() throws {
        let screens = [notched, external]
        let onBuiltIn = try #require(NotchGeometry.hostScreen(screens: screens, mouse: CGPoint(x: 900, y: 600), main: notched))
        #expect(onBuiltIn == notched)
        #expect(NotchGeometry.layout(for: onBuiltIn).shown.maxY == 1130)
        #expect(!NotchGeometry.layout(for: onBuiltIn).shown.intersects(try #require(onBuiltIn.notchRect)))

        let onExternal = try #require(NotchGeometry.hostScreen(screens: screens, mouse: CGPoint(x: 2700, y: 500), main: notched))
        #expect(onExternal == external)
        #expect(NotchGeometry.layout(for: onExternal).shown.maxY == 1139)
        #expect(NotchGeometry.layout(for: onExternal).shown.midX == 2760)
    }

    @Test func hostScreenPrefersMouseScreenThenMain() {
        #expect(NotchGeometry.hostScreen(screens: [externalNoMenuBar, external],
                                         mouse: CGPoint(x: -5, y: 10), main: external) == external)
        #expect(NotchGeometry.hostScreen(screens: [], mouse: .zero, main: nil) == nil)
    }

    // MARK: - The regression guard for the "black slab" (1.7.9)

    /// A ruler in the same shape as `PillPanelController.pillSize`, without AppKit: 7 pt per
    /// character is wider than any real callout glyph, so the bound proved here is conservative.
    private func measure(_ text: String) -> CGFloat { CGFloat(text.count) * 7 }

    private func size(_ state: PillState, on metrics: ScreenMetrics) -> CGSize {
        NotchGeometry.size(for: state, on: metrics, measure: measure)
    }

    /// The reported bug: a raw error string from deep in the stack sized the panel into a black slab
    /// over half the display. Any message, at any length, must produce a pill inside the ceiling.
    @Test func aVeryLongErrorMessageStaysABoundedPill() throws {
        let monstrous = String(repeating: "The file “weight.bin.partial” doesn’t exist and nothing was typed. ", count: 40)
        for metrics in [notched, autoHiddenMenuBar, external, externalNoMenuBar, notchedOffOrigin] {
            let bounds = NotchGeometry.maximumSize(on: metrics)
            for state: PillState in [.error(message: monstrous), .unavailable(reason: monstrous),
                                     .error(message: String(repeating: "x", count: 5_000))] {
                let s = size(state, on: metrics)
                #expect(s.width <= bounds.width)
                #expect(s.height <= bounds.height)
                #expect(s.height <= NotchGeometry.absoluteMaximumSize.height)
                let shown = NotchGeometry.layout(for: metrics, size: s).shown
                #expect(metrics.frame.contains(shown))
                // Comfortably a notice, not a panel: never more than a tenth of the display's height
                // and never more than 60% of its width.
                #expect(shown.height <= metrics.frame.height / 10)
                #expect(shown.width <= max(NotchGeometry.expandedSize.width, metrics.frame.width * 0.6))
                if let housing = metrics.notchRect { #expect(!shown.intersects(housing)) }
            }
        }
    }

    /// Not just `.error`: every state the pill can be in is bounded, including the two-line notices
    /// that share the same wrapping layout and the ones that never measure their content at all.
    @Test func everyPillStateStaysWithinTheCeiling() {
        let long = String(repeating: "unreadably long reason ", count: 30)
        let states: [PillState] = [.hidden, .idle, .listening(level: 1), .preview(text: long), .landing,
                                   .warning(MicQuality(snr: 3, clipping: 0.9, lowLevel: true, verdict: .bad)),
                                   .unavailable(reason: long), .error(message: long),
                                   .transform(TransformPillInfo(editingWords: 9, stage: .editing))]
        for metrics in [notched, external, externalNoMenuBar] {
            let bounds = NotchGeometry.maximumSize(on: metrics)
            for state in states {
                let s = size(state, on: metrics)
                #expect(s.width <= bounds.width, "\(state.caseName) width \(s.width)")
                #expect(s.height <= bounds.height, "\(state.caseName) height \(s.height)")
                #expect(s.height <= 96)
                #expect(metrics.frame.contains(NotchGeometry.layout(for: metrics, size: s).shown))
            }
        }
    }

    /// A message that fits gets exactly the room it needs — the widening the ceiling is protecting,
    /// not replacing — and one that does not gets a second line and no more.
    @Test func aMessageIsWidenedToFitAndThenWraps() {
        // Sized to the widest of the *state's* sentences — here the fixed subtitle, not the message.
        let short = PillState.error(message: "Mic went away")
        #expect(size(short, on: notched) ==
                CGSize(width: measure(PillState.errorSubtitle) + NotchGeometry.textChrome,
                       height: NotchGeometry.expandedSize.height))
        let mid = PillState.error(message: String(repeating: "a", count: 60))
        let midSize = size(mid, on: notched)
        #expect(midSize.width == 60 * 7 + NotchGeometry.textChrome) // widened to fit, still under the cap
        #expect(midSize.height == NotchGeometry.expandedSize.height) // one line, no extra height
        let over = PillState.error(message: String(repeating: "a", count: 400))
        let overSize = size(over, on: notched)
        #expect(overSize.width == NotchGeometry.maximumSize(on: notched).width)
        #expect(overSize.height == NotchGeometry.expandedSize.height + NotchGeometry.wrapExtraHeight)
    }

    /// `layout(for:size:)` is the last gate: even a caller that asks for a slab directly gets a pill.
    @Test func layoutClampsAnAbsurdRequestedSize() {
        for metrics in [notched, external, externalNoMenuBar] {
            let l = NotchGeometry.layout(for: metrics, size: CGSize(width: 9_000, height: 9_000))
            #expect(metrics.frame.contains(l.shown))
            #expect(l.shown.height <= NotchGeometry.absoluteMaximumSize.height)
            #expect(l.shown.width <= NotchGeometry.absoluteMaximumSize.width)
            if let housing = metrics.notchRect { #expect(!l.shown.intersects(housing)) }
        }
    }

    @Test func sizeDependsOnState() {
        #expect(NotchGeometry.size(for: .preview(text: "x")) == NotchGeometry.expandedSize)
        #expect(NotchGeometry.size(for: .listening(level: 0)) == NotchGeometry.defaultSize)
    }
}
