import CoreGraphics
import Shared
import Testing
@testable import VoicePlusApp

/// V5 Q6 — the pill follows the work: caret → focused window → active → mouse, re-chosen each turn.
@Suite("Pill display chooser (V5 Q6)")
struct PillDisplayChooserTests {
    let laptop = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1800, height: 1169), topInset: 38,
                               notchWidth: 220, menuBarHeight: 39, displayID: 1)
    let external = ScreenMetrics(frame: CGRect(x: 1800, y: 89, width: 1920, height: 1080), menuBarHeight: 30, displayID: 2)
    let above = ScreenMetrics(frame: CGRect(x: 0, y: 1169, width: 1920, height: 1080), menuBarHeight: 0, displayID: 3)

    @Test func eachRungOfTheChooser() {
        let a = laptop, b = external, c = above
        #expect(PillDisplayChooser.choose(caretScreen: a, focusedWindowScreen: b, activeScreen: c, mouseScreen: b) == a)
        #expect(PillDisplayChooser.choose(caretScreen: nil, focusedWindowScreen: b, activeScreen: c, mouseScreen: a) == b)
        #expect(PillDisplayChooser.choose(caretScreen: nil, focusedWindowScreen: nil, activeScreen: c, mouseScreen: a) == c)
        #expect(PillDisplayChooser.choose(caretScreen: nil, focusedWindowScreen: nil, activeScreen: nil, mouseScreen: a) == a)
        #expect(PillDisplayChooser.choose(caretScreen: nil, focusedWindowScreen: nil, activeScreen: nil, mouseScreen: nil) == nil)
    }

    @Test func rawRectsResolveToTheirDisplays() {
        let screens = [laptop, external]
        // Caret on the external display wins over a mouse on the laptop.
        let caret = CGRect(x: 2000, y: 500, width: 0, height: 18)
        #expect(PillDisplayChooser.choose(caretRect: caret, focusedWindowFrame: nil, activeScreen: laptop,
                                          mouse: CGPoint(x: 10, y: 10), screens: screens, main: laptop) == external)
        // A window straddling both resolves to the display holding most of it.
        let window = CGRect(x: 1700, y: 300, width: 900, height: 500)
        #expect(PillDisplayChooser.choose(caretRect: nil, focusedWindowFrame: window, activeScreen: laptop,
                                          mouse: CGPoint(x: 10, y: 10), screens: screens, main: laptop) == external)
        // Nothing but the mouse.
        #expect(PillDisplayChooser.choose(caretRect: nil, focusedWindowFrame: nil, activeScreen: nil,
                                          mouse: CGPoint(x: 2500, y: 600), screens: screens, main: laptop) == external)
    }

    @Test func axRectsConvertToAppKit() {
        let ax = CGRect(x: 10, y: 0, width: 100, height: 20)
        #expect(PillDisplayChooser.appKitRect(fromAX: ax, primaryHeight: 1169) == CGRect(x: 10, y: 1149, width: 100, height: 20))
    }

    @Test func topEdgeOfTheLaptopResolvesToTheLaptop() {
        let top = CGPoint(x: 900, y: laptop.frame.maxY)
        #expect(NotchGeometry.hostScreen(screens: [laptop, external], mouse: top, main: external) == laptop)
        #expect(PillDisplayChooser.screen(containing: top, in: [laptop, external]) == laptop)
        // A display above the laptop strictly contains y == laptop.maxY, so it still wins there.
        #expect(NotchGeometry.hostScreen(screens: [laptop, above], mouse: top, main: laptop) == above)
    }

    @Test func unconfirmedToStartingRepins() {
        let held = PillState.held(HeldPillInfo(text: "x", destination: "Mail", reason: "destination changed"))
        let unconfirmed = PillState.landed(LandedPillInfo(text: "x", verified: false))
        for previous in [held, unconfirmed, .error(message: "x"), .landedPartial(text: "x")] {
            #expect(PillPanelController.shouldRechooseDisplay(previous: previous, next: .starting, wasVisible: true, hasPin: true))
        }
        // Mid-turn renders keep the pin.
        #expect(!PillPanelController.shouldRechooseDisplay(previous: .starting, next: .starting, wasVisible: true, hasPin: true))
        #expect(!PillPanelController.shouldRechooseDisplay(previous: .starting, next: .listeningQuiet, wasVisible: true, hasPin: true))
        // Appearing, or no pin yet, always chooses.
        #expect(PillPanelController.shouldRechooseDisplay(previous: .hidden, next: .listeningQuiet, wasVisible: false, hasPin: false))
        #expect(PillPanelController.shouldRechooseDisplay(previous: .starting, next: .listeningQuiet, wasVisible: true, hasPin: false))
    }
}

/// V5 Q7 — "on screen" means on the pill's chosen display, and only that suppresses the chin there.
@Suite("Pill on-screen report (V5 Q7)")
struct PillOnScreenTests {
    let laptop = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1800, height: 1169), topInset: 38,
                               notchWidth: 220, menuBarHeight: 39, displayID: 1)
    let external = ScreenMetrics(frame: CGRect(x: 1800, y: 89, width: 1920, height: 1080), menuBarHeight: 30, displayID: 2)
    var shown: CGRect { CGRect(x: 620, y: 970, width: 560, height: 199) }

    @Test func everyConjunctMatters() {
        #expect(PillSurfaceReport.evaluate(orderedIn: true, occlusionVisible: true, frame: shown, chosenScreen: laptop)
                == PillSurfaceReport(onScreen: true, display: laptop))
        #expect(!PillSurfaceReport.evaluate(orderedIn: false, occlusionVisible: true, frame: shown, chosenScreen: laptop).onScreen)
        #expect(!PillSurfaceReport.evaluate(orderedIn: true, occlusionVisible: false, frame: shown, chosenScreen: laptop).onScreen)
        #expect(!PillSurfaceReport.evaluate(orderedIn: true, occlusionVisible: true, frame: shown, chosenScreen: external).onScreen)
        #expect(!PillSurfaceReport.evaluate(orderedIn: true, occlusionVisible: true, frame: shown, chosenScreen: nil).onScreen)
        let retracted = CGRect(x: 620, y: 1130, width: 560, height: 1)
        #expect(!PillSurfaceReport.evaluate(orderedIn: true, occlusionVisible: true, frame: retracted, chosenScreen: laptop).onScreen)
    }

    @Test func aPillOnAnotherDisplayDoesNotSuppressTheChin() {
        #expect(!PresenceIndicatorController.pillSuppressesChin(stateVisible: true, panelOnScreen: true,
                                                               pillDisplay: external, chinDisplay: laptop))
        #expect(PresenceIndicatorController.pillSuppressesChin(stateVisible: true, panelOnScreen: true,
                                                              pillDisplay: laptop, chinDisplay: laptop))
        #expect(!PresenceIndicatorController.pillSuppressesChin(stateVisible: true, panelOnScreen: false,
                                                               pillDisplay: nil, chinDisplay: laptop))
        #expect(!PresenceIndicatorController.pillSuppressesChin(stateVisible: false, panelOnScreen: true,
                                                               pillDisplay: laptop, chinDisplay: laptop))
        // No panel report yet (headless): the pill state alone decides, as before.
        #expect(PresenceIndicatorController.pillSuppressesChin(stateVisible: true, panelOnScreen: nil,
                                                              pillDisplay: nil, chinDisplay: nil))
    }

    @MainActor @Test func controllerHonoursTheReportedDisplay() {
        let presence = PresenceIndicatorController()
        presence.chinDisplay = { laptop }
        presence.setPillVisible(true)
        presence.setPillSurface(PillSurfaceReport(onScreen: true, display: external))
        #expect(presence.currentInputs.pillVisible == false)
        presence.setPillSurface(PillSurfaceReport(onScreen: true, display: laptop))
        #expect(presence.currentInputs.pillVisible == true)
    }
}
