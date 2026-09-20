import CoreGraphics
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// S2 — hover logic of the idle chin (design §4 "Hover presence", DESIGN.md §6.2, §8.4): I0 at rest,
/// the text-only I1 hint on pointer hover, and capture / errors / held text taking priority over hover.
@Suite("S2 — presence hover")
struct PresenceHoverTests {
    let notched = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1800, height: 1169),
                                topInset: 38, notchWidth: 220, menuBarHeight: 39)
    let external = ScreenMetrics(frame: CGRect(x: 1800, y: 89, width: 1920, height: 1080),
                                 topInset: 0, notchWidth: nil, menuBarHeight: 30)
    let hint = "Hold or Double Tap fn / 🌐 to dictate"

    @Test func idleIsTheChinAndHoverIsTheTextOnlyHint() {
        #expect(PresenceHover.presentation(state: .ready, pointerOn: false, readyHint: hint) == .chin)
        #expect(PresenceHover.presentation(state: .ready, pointerOn: true, readyHint: hint) == .hint(hint))
        // Pointer exit collapses it again.
        #expect(PresenceHover.presentation(state: .ready, pointerOn: false, readyHint: hint) == .chin)
        // The hint is the configured key's, with no brand prefix and no "Ready".
        #expect(!hint.contains("VoicePlus") && !hint.contains("Ready"))
        #expect(HotkeyBinding(kind: .rightOption).readyHint() == "Hold or Double Tap Right Option to dictate")
        #expect(HotkeyBinding.default.readyHint(latchEnabled: false) == "Hold fn / 🌐 to dictate")
    }

    @Test func keyboardFocusNeverOpensTheHover() {
        #expect(PresenceHover.presentation(state: .ready, pointerOn: false, keyboardFocus: true, readyHint: hint) == .chin)
    }

    /// Muted, paused and blocked keep their own rows under the pointer; nothing expands for `off`.
    @Test func otherStatesShowTheirOwnRow() {
        for state: PresenceState in [.muted, .paused, .blocked(.microphoneDenied), .listening(level: 0.3), .processing] {
            #expect(PresenceHover.presentation(state: state, pointerOn: true, readyHint: hint) == .row, "\(state.caseName)")
        }
        #expect(PresenceHover.presentation(state: .off, pointerOn: true, readyHint: hint) == .none)
    }

    /// Capture, errors and held text take priority over hover: while the pill shows them the indicator
    /// is off, so hovering the notch cannot bring the hint back over a live turn.
    @Test func thePillTakesPriorityOverHover() {
        var inputs = PresenceInputs()
        inputs.pillVisible = true
        let state = PresenceStateReducer.reduce(inputs)
        #expect(state == .off)
        #expect(PresenceHover.presentation(state: state, pointerOn: true, readyHint: hint) == .none)
    }

    @Test func theChinIsSixtyFourByFourteenWithASixPointDot() {
        #expect(PresenceGeometry.restSize == CGSize(width: 64, height: 14))
        #expect(PresenceGeometry.dotDiameter == 6)
        let layout = PresenceGeometry.layout(for: notched, state: .ready)
        #expect(layout.frame.size == CGSize(width: 64, height: 14))
        #expect(layout.cornerRadius == Tokens.Radius.presenceChin)
        #expect(layout.attached)
    }

    /// The hint is text-sized, never under 190 pt, 38 pt tall, and floats with the pill on an
    /// external display.
    @Test func theHintIsTextSized() {
        let ruler: (String) -> CGFloat = { CGFloat($0.count) * 6 }
        let width = PresenceHover.hintWidth(hint, on: notched, measure: ruler)
        #expect(width == max(360, ruler(hint) + 24))
        #expect(PresenceHover.hintWidth("Hi", on: notched, measure: ruler) == 360)
        let hovered = PresenceGeometry.layout(for: notched, state: .ready, hovered: true, rowWidth: width)
        #expect(hovered.frame.size == CGSize(width: width, height: 38))
        #expect(hovered.cornerRadius == Tokens.Radius.presenceHint)
        #expect(PresenceGeometry.clearsHousing(hovered.frame, on: notched))
        let floating = PresenceGeometry.layout(for: external, state: .ready, hovered: true, rowWidth: width)
        #expect(!floating.attached)
        #expect(floating.frame.maxY == NotchGeometry.pillLayout(for: external).shown.maxY)
        // The pointer stays "on it" across the whole expanded hint, so it cannot flicker shut.
        #expect(hovered.hoverRect.contains(CGPoint(x: hovered.frame.minX + 2, y: hovered.frame.midY)))
    }
}
