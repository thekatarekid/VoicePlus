import AppKit
import CoreGraphics
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// H33 — hover opens the real menu centred under the centre-expanded pill, at one shared width W;
/// 250 ms hover intent; never during a live turn; pointer-leave closes it; the three custom rows are
/// in the menu spec.
@Suite("H33 — hover menu under the pill")
struct MenuHoverH33Tests {
    let notched = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1800, height: 1169),
                                topInset: 38, notchWidth: 220, menuBarHeight: 39)
    let external = ScreenMetrics(frame: CGRect(x: 1800, y: 89, width: 1920, height: 1080),
                                 topInset: 0, notchWidth: nil, menuBarHeight: 30)
    let narrow = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 260, height: 600),
                               topInset: 0, notchWidth: nil, menuBarHeight: 24)
    let t0 = Date(timeIntervalSince1970: 1_000)

    // MARK: Geometry

    @Test func menuIsCentredUnderThePillAtTheSameWidth() {
        for metrics in [notched, external] {
            for (pill, menu) in [(CGFloat(260), CGFloat(300)), (360, 300), (190, 190), (420, 520)] {
                let p = PresenceMenuHover.placement(pillWidth: pill, menuNaturalSize: CGSize(width: menu, height: 400),
                                                    on: metrics)
                #expect(p.width == max(pill, menu))
                #expect(p.pillFrame.width == p.width, "the pill widens to W")
                #expect(p.menuFrame.width == p.width, "widths equal")
                #expect(abs(p.menuFrame.midX - p.pillFrame.midX) < 0.001, "x-centre = pill centre")
                #expect(p.menuOrigin.x == p.menuFrame.minX && p.menuOrigin.y == p.menuFrame.maxY)
                #expect(abs(p.pillFrame.minY - p.menuOrigin.y - PresenceMenuHover.gap) < 0.001, "drops straight down")
                // The widened pill keeps the rest chin's anchor (H34): centre-x and top edge.
                let rest = PresenceGeometry.layout(for: metrics, state: .ready).frame
                #expect(PresenceResize.sharesAnchor(rest, p.pillFrame))
            }
        }
    }

    @Test func widthIsClampedToTheWidestRow() {
        let max = PresenceGeometry.maxRowWidth(on: narrow)
        #expect(PresenceMenuHover.sharedWidth(pillWidth: 190, menuNaturalWidth: 300, on: narrow) == max)
        let p = PresenceMenuHover.placement(pillWidth: 190, menuNaturalSize: CGSize(width: 300, height: 200), on: narrow)
        #expect(p.pillFrame.width == p.menuFrame.width)
        #expect(p.menuFrame.minX >= narrow.frame.minX && p.menuFrame.maxX <= narrow.frame.maxX)
    }

    // MARK: Intent

    @Test func opensAfter250msOfHover() {
        var intent = PresenceMenuIntent()
        #expect(intent.tick(pointerOnPill: true, pointerOnMenu: false, liveTurn: false, now: t0) == .none)
        #expect(intent.tick(pointerOnPill: true, pointerOnMenu: false, liveTurn: false, now: t0 + 0.2) == .none)
        #expect(intent.tick(pointerOnPill: true, pointerOnMenu: false, liveTurn: false, now: t0 + 0.25) == .open)
    }

    @Test func passingOverDoesNotOpen() {
        var intent = PresenceMenuIntent()
        _ = intent.tick(pointerOnPill: true, pointerOnMenu: false, liveTurn: false, now: t0)
        #expect(intent.tick(pointerOnPill: false, pointerOnMenu: false, liveTurn: false, now: t0 + 0.1) == .none)
        #expect(intent.tick(pointerOnPill: true, pointerOnMenu: false, liveTurn: false, now: t0 + 0.3) == .none)
        #expect(intent.tick(pointerOnPill: true, pointerOnMenu: false, liveTurn: false, now: t0 + 0.56) == .open)
    }

    @Test func neverOpensDuringALiveTurn() {
        var intent = PresenceMenuIntent()
        for i in 0..<10 {
            #expect(intent.tick(pointerOnPill: true, pointerOnMenu: false, liveTurn: true,
                                now: t0 + Double(i) * 0.2) == .none)
        }
    }

    @Test func liveTurnClosesAnOpenMenu() {
        var intent = PresenceMenuIntent()
        intent.menuOpened()
        #expect(intent.tick(pointerOnPill: true, pointerOnMenu: false, liveTurn: true, now: t0) == .close)
    }

    @Test func pointerLeavingBothFor300msCloses() {
        var intent = PresenceMenuIntent()
        intent.menuOpened()
        #expect(intent.tick(pointerOnPill: false, pointerOnMenu: true, liveTurn: false, now: t0) == .none)
        #expect(intent.tick(pointerOnPill: false, pointerOnMenu: false, liveTurn: false, now: t0 + 0.1) == .none)
        // Back on the menu resets the leave timer.
        #expect(intent.tick(pointerOnPill: false, pointerOnMenu: true, liveTurn: false, now: t0 + 0.3) == .none)
        #expect(intent.tick(pointerOnPill: false, pointerOnMenu: false, liveTurn: false, now: t0 + 0.5) == .none)
        #expect(intent.tick(pointerOnPill: false, pointerOnMenu: false, liveTurn: false, now: t0 + 0.81) == .close)
    }

    @Test func dismissedMenuDoesNotReopenUntilThePointerLeaves() {
        var intent = PresenceMenuIntent()
        intent.menuOpened()
        intent.menuClosed()
        #expect(intent.tick(pointerOnPill: true, pointerOnMenu: false, liveTurn: false, now: t0) == .none)
        #expect(intent.tick(pointerOnPill: true, pointerOnMenu: false, liveTurn: false, now: t0 + 1) == .none)
        _ = intent.tick(pointerOnPill: false, pointerOnMenu: false, liveTurn: false, now: t0 + 1.1)
        _ = intent.tick(pointerOnPill: true, pointerOnMenu: false, liveTurn: false, now: t0 + 1.2)
        #expect(intent.tick(pointerOnPill: true, pointerOnMenu: false, liveTurn: false, now: t0 + 1.45) == .open)
    }

    // MARK: Spec — the three custom rows

    @Test func customRowsAreSpecSlotsInTheirPlaces() {
        var state = StatusMenuState()
        #expect(StatusMenuSpec.entries(state).allSatisfy { !StatusMenuSpec.ID.customSlots.contains($0.id) },
                "headless default: none")
        state.extras = MenuExtras(zeroEdit: true, whyItWroteThat: true, ambient: true)
        let ids = StatusMenuSpec.entries(state).map(\.id)
        func at(_ id: String) -> Int { ids.firstIndex(of: id) ?? -1 }
        #expect(at(StatusMenuSpec.ID.zeroEdit) == at(StatusMenuSpec.ID.microphone) + 1)
        #expect(at(StatusMenuSpec.ID.whyItWroteThat) == at(StatusMenuSpec.ID.settings) + 1)
        #expect(at(StatusMenuSpec.ID.ambientSeparator) == at(StatusMenuSpec.ID.whyItWroteThat) + 1)
        #expect(at(StatusMenuSpec.ID.ambient) == at(StatusMenuSpec.ID.ambientSeparator) + 1)
        #expect(at("menu.sep.quit") == at(StatusMenuSpec.ID.ambient) + 1)
        #expect(ids.last == StatusMenuSpec.ID.quit)
    }

    /// Quit is never the first row: with `positioning: nil` nothing is pre-selected, and the first
    /// actionable row a keyboard user lands on is not Quit.
    @Test func quitIsNotTheDefaultSelection() {
        var state = StatusMenuState()
        state.extras = MenuExtras(zeroEdit: true, whyItWroteThat: true, ambient: true)
        let firstActionable = StatusMenuSpec.entries(state).first { $0.action != nil && $0.isEnabled }
        #expect(firstActionable?.action != .quit)
    }

    @Test @MainActor func headlessControllerDropsEmptySlotsAndMeasures() {
        let controller = StatusItemController(flags: FeatureFlagService.inMemory(), database: nil,
                                              coordinator: DictationCoordinator(engine: MockEngine(fixture: TranscriptFixture(name: "h33", spans: []), delayScale: 0), database: nil,
                                                                                pill: PillPanelController()),
                                              hotkey: HotkeyService(defaults: UserDefaults(suiteName: "AppTests.h33.\(UUID())")!),
                                              updater: NoopUpdater(), statusBar: nil)
        controller.showsWhyItWroteThat = true   // the slot is in the spec; with no traced turn it draws nothing
        #expect(controller.menuState().extras.whyItWroteThat)
        let size = controller.naturalMenuSize()
        #expect(size.width > 0)
        #expect(controller.menu.minimumWidth == 0)
        #expect(!controller.menu.items.contains { $0.identifier?.rawValue == StatusMenuSpec.ID.whyItWroteThat && $0.title.isEmpty })
        #expect(controller.hoverMenuOpen == false)
    }
}
