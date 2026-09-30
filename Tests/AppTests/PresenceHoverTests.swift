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

    /// FX6 — the green dot belongs to the resting chin and to nothing else. It used to slide to the
    /// top-left corner of the growing hint box during the expand, because the chin's body and the
    /// hint's body shared one SwiftUI identity; the dot is now absent from every hovered
    /// presentation, and every kind has its own identity so it can only cross-fade.
    @Test func theHintPresentationCarriesNoDot() {
        // `presentation(...) == .hint` ⇒ no dot in the rendered body.
        #expect(PresenceHover.presentation(state: .ready, pointerOn: true, readyHint: hint) == .hint(hint))
        #expect(PresenceContent.kind(state: .ready, hovered: true) == .hint)
        #expect(PresenceContent.kind(state: .ready, hovered: true).showsDot == false)
        #expect(PresenceIndicatorView(state: .ready, hovered: true, cornerRadius: 10, hint: "",
                                      readyHint: hint).contentKind.showsDot == false)
        // Only the resting ready chin (I0) has it.
        #expect(PresenceContent.kind(state: .ready, hovered: false) == .dot)
        #expect(PresenceContent.kind(state: .ready, hovered: false).showsDot)
        #expect(PresenceIndicatorView(state: .ready, hovered: false, cornerRadius: 6, hint: "",
                                      readyHint: hint).contentKind.showsDot)
        // No other state, hovered or not, draws a dot either.
        for state in [PresenceState.off, .listening(level: 0.4), .processing, .muted, .paused,
                      .blocked(.microphoneDenied)] {
            #expect(!PresenceContent.kind(state: state, hovered: false).showsDot)
            #expect(!PresenceContent.kind(state: state, hovered: true).showsDot)
        }
    }

    /// The dot, the hint and the state row are three different views, so SwiftUI cannot
    /// geometry-match them across the expand/collapse — while the level bar keeps one identity
    /// across level ticks (it is the same bar getting wider, not a new one every frame).
    @Test func eachPresentationHasItsOwnViewIdentity() {
        let ids = [PresenceContent.kind(state: .ready, hovered: false).identity,
                   PresenceContent.kind(state: .ready, hovered: true).identity,
                   PresenceContent.kind(state: .muted, hovered: true).identity,
                   PresenceContent.kind(state: .muted, hovered: false).identity,
                   PresenceContent.kind(state: .listening(level: 0.2), hovered: false).identity,
                   PresenceContent.kind(state: .off, hovered: false).identity]
        #expect(Set(ids).count == ids.count)
        #expect(PresenceContent.kind(state: .listening(level: 0.2), hovered: false).identity
            == PresenceContent.kind(state: .listening(level: 0.9), hovered: false).identity)
        #expect(PresenceContent.kind(state: .processing, hovered: false).identity
            == PresenceContent.kind(state: .listening(level: 0.9), hovered: false).identity)
    }
}
