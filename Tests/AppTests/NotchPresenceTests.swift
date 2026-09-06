import CoreGraphics
import Shared
import Testing
@testable import VoicePlusApp

/// P5 — the persistent presence indicator ("the notch chin").
///
/// Fixtures are the same measured hardware values `NotchGeometryTests` pins (2026-08-29 / 2026-09-06,
/// MacBook with camera housing + AirPlay external display), so both surfaces are held to the same
/// numbers and cannot drift apart.
@Suite("Presence geometry (P5)")
struct PresenceGeometryTests {
    /// Built-in Retina display: frame 1800x1169, safeAreaInsets.top 38, housing 220 pt wide,
    /// visibleFrame.maxY 1130 (menu-bar delta 39).
    let notched = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1800, height: 1169),
                                topInset: 38, notchWidth: 220, menuBarHeight: 39)
    /// Same panel placed right of an external display (not at the global origin).
    let notchedOffOrigin = ScreenMetrics(frame: CGRect(x: -1800, y: 200, width: 1800, height: 1169),
                                         topInset: 38, notchWidth: 220, menuBarHeight: 39)
    /// Menu bar auto-hidden / a full-screen Space: the visibleFrame delta collapses to 0 but the
    /// camera housing does not go anywhere.
    let autoHiddenMenuBar = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1800, height: 1169),
                                          topInset: 38, notchWidth: 220, menuBarHeight: 0)
    /// External display carrying the menu bar (the Samsung AirPlay panel on the reporting machine).
    let external = ScreenMetrics(frame: CGRect(x: 1800, y: 89, width: 1920, height: 1080),
                                 topInset: 0, notchWidth: nil, menuBarHeight: 30)
    /// Secondary display with no menu bar ("Displays have separate Spaces" off).
    let externalNoMenuBar = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                          topInset: 0, notchWidth: nil, menuBarHeight: 0)
    /// Narrower than the hover row, so the clamp has to do something.
    let sliver = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 160, height: 600),
                               topInset: 0, notchWidth: nil, menuBarHeight: 24)

    var notchedFixtures: [ScreenMetrics] { [notched, notchedOffOrigin, autoHiddenMenuBar] }
    var allFixtures: [ScreenMetrics] { [notched, notchedOffOrigin, autoHiddenMenuBar, external, externalNoMenuBar, sliver] }

    var everyState: [PresenceState] {
        [.ready, .listening(level: 0.7), .processing, .muted, .paused,
         .blocked(.microphoneDenied), .blocked(.relaunchNeeded), .blocked(.modelDownloading(0.4))]
    }

    // MARK: - The guard that matters

    /// The indicator must never be drawn beneath the camera housing: there is no panel behind it,
    /// so anything drawn there is simply never seen. Same guard the pill has carried since T2.
    @Test func neverIntersectsTheCameraHousing() throws {
        for metrics in notchedFixtures {
            let housing = try #require(metrics.notchRect)
            for state in everyState {
                for hovered in [false, true] {
                    let frame = PresenceGeometry.layout(for: metrics, state: state, hovered: hovered).frame
                    #expect(!frame.intersects(housing))
                    #expect(frame.maxY <= metrics.frame.maxY - metrics.topInset)
                    #expect(metrics.frame.contains(frame))
                    #expect(PresenceGeometry.clearsHousing(frame, on: metrics))
                }
            }
            // The diagnostic the app logs at startup checks the same thing for every size at once.
            #expect(PresenceGeometry.allFrames(on: metrics).allSatisfy { PresenceGeometry.clearsHousing($0.rect, on: metrics) })
        }
    }

    /// One rule for both surfaces: the top edge is the bottom of the forbidden band. If this ever
    /// fails, the pill and the indicator have drifted apart and one of them is behind the housing.
    @Test func sharesTheTopBoundaryWithThePill() {
        for metrics in allFixtures {
            let pillTop = NotchGeometry.layout(for: metrics).shown.maxY
            for state in everyState {
                for hovered in [false, true] {
                    #expect(PresenceGeometry.layout(for: metrics, state: state, hovered: hovered).frame.maxY == pillTop)
                }
            }
        }
    }

    // MARK: - Pinned to the measured hardware

    @Test func restFrameMatchesMeasuredHardware() {
        #expect(notched.topBand == 39)
        #expect(notched.notchRect == CGRect(x: 790, y: 1131, width: 220, height: 38))

        #expect(PresenceGeometry.frame(size: PresenceGeometry.restSize, on: notched)
                == CGRect(x: 862, y: 1126, width: 76, height: 4))
        #expect(PresenceGeometry.frame(size: PresenceGeometry.activeSize, on: notched)
                == CGRect(x: 840, y: 1120, width: 120, height: 10))
        #expect(PresenceGeometry.frame(size: PresenceGeometry.mutedSize, on: notched)
                == CGRect(x: 858, y: 1114, width: 84, height: 16))
        #expect(PresenceGeometry.frame(size: PresenceGeometry.hoverSize, on: notched)
                == CGRect(x: 805, y: 1106, width: 190, height: 24))
        // Every one of them hangs off the same boundary as the pill (visibleFrame.maxY).
        #expect(PresenceGeometry.allFrames(on: notched).allSatisfy { $0.rect.maxY == 1130 })
    }

    /// Menu bar hidden: the chin moves up to 1131 — flush with the bottom edge of the housing,
    /// still not intersecting it (a shared edge is not an intersection).
    @Test func menuBarHiddenPutsItFlushUnderTheHousing() throws {
        let frame = PresenceGeometry.frame(size: PresenceGeometry.restSize, on: autoHiddenMenuBar)
        #expect(frame == CGRect(x: 862, y: 1127, width: 76, height: 4))
        #expect(frame.maxY == 1131)
        #expect(!frame.intersects(try #require(autoHiddenMenuBar.notchRect)))
    }

    @Test func offOriginStaysOnItsOwnScreen() {
        let frame = PresenceGeometry.frame(size: PresenceGeometry.restSize, on: notchedOffOrigin)
        #expect(frame == CGRect(x: -938, y: 1326, width: 76, height: 4))
        #expect(notchedOffOrigin.frame.contains(frame))
    }

    // MARK: - Non-notched displays

    @Test func notchlessDisplaysUseTheSameCompactChin() {
        let onExternal = PresenceGeometry.frame(size: PresenceGeometry.restSize, on: external)
        #expect(onExternal == CGRect(x: 2722, y: 1135, width: 76, height: 4))   // 1169 - 30 pt menu bar
        #expect(external.notchRect == nil)
        #expect(PresenceGeometry.clearsHousing(onExternal, on: external))

        // No menu bar at all: flush with the very top of the panel.
        let flush = PresenceGeometry.frame(size: PresenceGeometry.restSize, on: externalNoMenuBar)
        #expect(flush == CGRect(x: 922, y: 1076, width: 76, height: 4))
    }

    @Test func clampsOnANarrowDisplayInsteadOfOverflowing() {
        let hover = PresenceGeometry.frame(size: PresenceGeometry.hoverSize, on: sliver)
        #expect(hover.width == 144)          // 160 - 2 * 8 pt edge margin
        #expect(sliver.frame.contains(hover))
        #expect(hover.maxY == 576)           // still the one rule
    }

    // MARK: - Multi-display

    /// Pinned, not mouse-following: the indicator lives on the notched built-in even when the
    /// pointer is on the external display. `WindowPlacement.hostScreen` already encodes that order.
    @Test func hostScreenIsTheNotchedDisplayNotTheMouseScreen() throws {
        #expect(WindowPlacement.hostScreen(screens: [external, notched], main: external) == notched)
        // Lid closed — the built-in is gone from the list entirely; the external takes over.
        let clamshell = try #require(WindowPlacement.hostScreen(screens: [external], main: external))
        #expect(clamshell == external)
        #expect(PresenceGeometry.frame(size: PresenceGeometry.restSize, on: clamshell).maxY == 1139)
    }

    @Test func everyDisplayKeepsItsOwnFramesOnItself() {
        for metrics in allFixtures {
            for state in everyState {
                let frame = PresenceGeometry.layout(for: metrics, state: state).frame
                #expect(metrics.frame.contains(frame))
                #expect(frame.width > 0 && frame.height > 0)
            }
        }
    }

    @Test func offDrawsNothing() {
        let layout = PresenceGeometry.layout(for: notched, state: .off)
        #expect(!layout.visible)
        #expect(layout.frame == .zero)
        #expect(PresenceGeometry.size(for: .off) == .zero)
    }
}

@Suite("Presence state (P5)")
struct PresenceStateTests {
    let allGranted = PermissionPlanner.Capabilities(canCapture: true, canUseGlobalHotkey: true, canInjectText: true)
    let noMic = PermissionPlanner.Capabilities(canCapture: false, canUseGlobalHotkey: true, canInjectText: true)
    let noHotkey = PermissionPlanner.Capabilities(canCapture: true, canUseGlobalHotkey: false, canInjectText: true)

    /// Mute is a hard latch and the indicator must never show something less alarming than reality.
    @Test func mutedWinsOverListeningProcessingAndBlocked() {
        let inputs = PresenceInputs(muted: true, paused: true, ambientProcessing: true,
                                    engine: .listening(level: 0.9), capabilities: noMic, tapProvenDead: true,
                                    downloadProgress: 0.2)
        #expect(PresenceStateReducer.reduce(inputs) == .muted)
        #expect(!PresenceState.muted.isQuiet)
        #expect(PresenceState.muted.badge == "MUTED")
    }

    @Test func precedenceBelowMute() {
        #expect(PresenceStateReducer.reduce(PresenceInputs(paused: true, engine: .listening(level: 0.5))) == .paused)
        #expect(PresenceStateReducer.reduce(PresenceInputs(capabilities: noMic)) == .blocked(.microphoneDenied))
        #expect(PresenceStateReducer.reduce(PresenceInputs(engine: .listening(level: 0.5))) == .listening(level: 0.5))
        #expect(PresenceStateReducer.reduce(PresenceInputs(engine: .finalizing)) == .processing)
        #expect(PresenceStateReducer.reduce(PresenceInputs(ambientProcessing: true)) == .processing)
        #expect(PresenceStateReducer.reduce(PresenceInputs()) == .ready)
        // A failed utterance is not a permanent state: the pill carries the error, the chin goes
        // back to "ready" rather than sitting there red forever.
        #expect(PresenceStateReducer.reduce(PresenceInputs(engine: .error("invalidAudioData"))) == .ready)
    }

    /// The pill is the richer surface at the same anchor, one window level above, and would draw
    /// straight over this — so while it is up, the indicator stands down. Nothing is hidden by
    /// doing so: the pill says more than the chin ever could.
    @Test func pillVisibleHidesTheIndicator() {
        for engine: EngineState in [.idle, .listening(level: 0.4), .finalizing] {
            #expect(PresenceStateReducer.reduce(PresenceInputs(pillVisible: true, engine: engine)) == .off)
        }
        #expect(PresenceStateReducer.reduce(PresenceInputs(pillVisible: true, muted: true)) == .off)
        // …and the underlying state is still computed correctly, it is only suppressed.
        #expect(PresenceStateReducer.substance(PresenceInputs(pillVisible: true, muted: true)) == .muted)
    }

    @Test func capabilityGapsMapToBlocked() {
        #expect(PresenceStateReducer.reduce(PresenceInputs(capabilities: noMic)) == .blocked(.microphoneDenied))
        #expect(PresenceStateReducer.reduce(PresenceInputs(capabilities: noHotkey)) == .blocked(.hotkeyUnavailable))
        let dead = PresenceStateReducer.reduce(PresenceInputs(capabilities: allGranted, tapProvenDead: true))
        #expect(dead == .blocked(.relaunchNeeded))
        #expect(dead.offersRelaunch)
        #expect(!PresenceState.ready.offersRelaunch)
        #expect(PresenceState.blocked(.microphoneDenied).badge == "Mic off")
    }

    /// The single most important test in this file. Hiding a hot — or hard-muted — microphone in a
    /// full-screen Space is exactly the hidden hot mic the product spec forbids, and full screen
    /// (a call, a talk, a screen share) is when it matters most. Only the quiet states may hide.
    @Test func fullScreenHidesOnlyTheQuietStates() {
        func state(_ inputs: PresenceInputs) -> PresenceState {
            var full = inputs
            full.menuBarPresent = false      // menu bar collapsed == full-screen Space
            full.hideInFullScreen = true
            return PresenceStateReducer.reduce(full)
        }
        #expect(state(PresenceInputs()) == .off)                                        // ready
        #expect(state(PresenceInputs(paused: true)) == .off)
        #expect(state(PresenceInputs(capabilities: noMic)) == .off)                     // blocked
        #expect(state(PresenceInputs(muted: true)) == .muted)                           // never hidden
        #expect(state(PresenceInputs(engine: .listening(level: 0.3))) == .listening(level: 0.3))
        #expect(state(PresenceInputs(engine: .finalizing)) == .processing)

        // With the setting off, even the quiet states keep drawing in full screen.
        var keep = PresenceInputs(hideInFullScreen: false, menuBarPresent: false)
        #expect(PresenceStateReducer.reduce(keep) == .ready)
        keep.paused = true
        #expect(PresenceStateReducer.reduce(keep) == .paused)
    }

    @Test func downloadProgressSurfacesWhenSuppliedAndIsIgnoredWhenNil() {
        #expect(PresenceStateReducer.reduce(PresenceInputs(downloadProgress: nil)) == .ready)
        #expect(PresenceStateReducer.reduce(PresenceInputs(downloadProgress: 0.42)) == .blocked(.modelDownloading(0.42)))
        #expect(PresenceBlockReason.modelDownloading(0.42).badge == "42%")
        // A finished download is not a blockage.
        #expect(PresenceStateReducer.reduce(PresenceInputs(downloadProgress: 1)) == .ready)
        // …and a real permission gap still outranks it.
        #expect(PresenceStateReducer.reduce(PresenceInputs(capabilities: noMic, downloadProgress: 0.1))
                == .blocked(.microphoneDenied))
    }

    @Test func settingDisabledYieldsNoPanel() {
        for inputs in [PresenceInputs(enabled: false),
                       PresenceInputs(enabled: false, muted: true),
                       PresenceInputs(enabled: false, engine: .listening(level: 1)),
                       PresenceInputs(enabled: false, capabilities: noMic)] {
            #expect(PresenceStateReducer.reduce(inputs) == .off)
        }
    }

    @Test func everyStateHasCopyAndADistinctSymbol() {
        let states: [PresenceState] = [.ready, .listening(level: 0), .processing, .muted, .paused,
                                       .blocked(.microphoneDenied)]
        #expect(Set(states.map(\.symbol)).count == states.count)
        #expect(Set(states.map(\.caseName)).count == states.count)
        for state in states {
            #expect(!state.detail.isEmpty)
            #expect(!state.symbol.isEmpty)
            #expect(state.isVisible)
        }
        // The glyph vocabulary is shared with the menu-bar ambient state — one vocabulary, two surfaces.
        #expect(PresenceState.muted.symbol == AmbientState.muted.notchSymbol)
        #expect(PresenceState.listening(level: 0).symbol == AmbientState.listening.notchSymbol)
        #expect(PresenceState.off.isVisible == false)
        // Levels are clamped, never trusted raw.
        #expect(PresenceStateReducer.reduce(PresenceInputs(engine: .listening(level: 4))).level == 1)
        #expect(PresenceStateReducer.reduce(PresenceInputs(engine: .listening(level: -2))).level == 0)
    }
}

@Suite("Presence interaction (P5)")
struct PresenceInteractionTests {
    let notched = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1800, height: 1169),
                                topInset: 38, notchWidth: 220, menuBarHeight: 39)
    let external = ScreenMetrics(frame: CGRect(x: 1800, y: 89, width: 1920, height: 1080),
                                 topInset: 0, notchWidth: nil, menuBarHeight: 30)

    /// The click-through guarantee, as a unit test rather than a comment: the panel takes the mouse
    /// only while the pointer is provably on it, so it can never swallow a click meant for the app
    /// underneath.
    @Test func ignoresMouseUnlessHovering() {
        #expect(PresenceInteraction.ignoresMouse(hovering: false))
        #expect(!PresenceInteraction.ignoresMouse(hovering: true))
    }

    @Test func hoverRectCoversTheChinTheHoverRowAndTheHousing() throws {
        let rect = PresenceGeometry.hoverRect(on: notched)
        let housing = try #require(notched.notchRect)
        #expect(rect.contains(PresenceGeometry.frame(size: PresenceGeometry.restSize, on: notched)))
        #expect(rect.contains(PresenceGeometry.frame(size: PresenceGeometry.hoverSize, on: notched)))
        #expect(rect.contains(housing))   // pointing at the camera housing itself reveals it

        // Dead centre of the chin: hovering. Well clear of it: not.
        #expect(PresenceInteraction.isHovering(mouse: CGPoint(x: 900, y: 1128), on: notched))
        #expect(!PresenceInteraction.isHovering(mouse: CGPoint(x: 900, y: 600), on: notched))
        #expect(!PresenceInteraction.isHovering(mouse: CGPoint(x: 400, y: 1128), on: notched))
        // The 8 pt slop is real, and 2 pt past it is not hovering.
        #expect(PresenceInteraction.isHovering(mouse: CGPoint(x: 900, y: rect.minY + 1), on: notched))
        #expect(!PresenceInteraction.isHovering(mouse: CGPoint(x: 900, y: rect.minY - 2), on: notched))
    }

    /// Full-screen detection without private API — and its one false-positive trap: a display that
    /// never had a menu bar in the first place is not in a full-screen Space.
    @Test func fullScreenIsAMenuBarThatUsedToBeThere() {
        #expect(PresenceInteraction.menuBarPresent(current: 39, everObserved: 39))
        #expect(!PresenceInteraction.menuBarPresent(current: 0, everObserved: 39))   // full screen
        #expect(PresenceInteraction.menuBarPresent(current: 0, everObserved: 0))     // never had one
    }

    /// Defaults: on, and hiding the quiet states in full screen. Both survive a round trip.
    @Test func settingsDefaultOnAndRoundTrip() {
        let store = InMemorySettingsStore()
        #expect(PresenceSettings.isEnabled(store))
        #expect(PresenceSettings.hidesInFullScreen(store))
        #expect(PresenceSettings.isEnabled(nil))          // no store yet — still on

        PresenceSettings.setEnabled(false, store: store)
        PresenceSettings.setHidesInFullScreen(false, store: store)
        #expect(!PresenceSettings.isEnabled(store))
        #expect(!PresenceSettings.hidesInFullScreen(store))
        #expect(store.values[SettingsKeys.presenceIndicator] as? Bool == false)

        PresenceSettings.setEnabled(true, store: store)
        #expect(PresenceSettings.isEnabled(store))
    }

    /// The indicator is one instance on one pinned display; it does not follow the pointer between
    /// displays, and each display's own geometry stays on that display.
    @Test func pinnedToOneDisplayAcrossAnArrangementChange() {
        let host = WindowPlacement.hostScreen(screens: [external, notched], main: external)
        #expect(host == notched)
        let afterUnplug = WindowPlacement.hostScreen(screens: [external], main: external)
        #expect(afterUnplug == external)
        for metrics in [notched, external] {
            let frame = PresenceGeometry.frame(size: PresenceGeometry.activeSize, on: metrics)
            #expect(metrics.frame.contains(frame))
        }
    }
}
