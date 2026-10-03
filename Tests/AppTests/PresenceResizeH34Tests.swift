import CoreGraphics
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// H34 — the hover row: no cap above the menu bar, grows from its centre with a target-frame guard,
/// the dot returns only after the collapse, Reduce Motion snaps.
@Suite("H34 — presence hover row resize")
struct PresenceResizeH34Tests {
    let notched = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1800, height: 1169),
                                topInset: 38, notchWidth: 220, menuBarHeight: 39)
    let external = ScreenMetrics(frame: CGRect(x: 1800, y: 89, width: 1920, height: 1080),
                                 topInset: 0, notchWidth: nil, menuBarHeight: 30)

    /// Nothing paints into the menu bar: in every state the panel's top is the pill's top edge.
    @Test func panelTopNeverAboveThePillTopEdge() {
        for metrics in [notched, external] {
            let top = NotchGeometry.pillTopEdge(on: metrics)
            for state: PresenceState in [.ready, .muted, .paused, .processing, .listening(level: 0.4),
                                         .blocked(.microphoneDenied)] {
                for hovered in [false, true] {
                    let layout = PresenceGeometry.layout(for: metrics, state: state, hovered: hovered,
                                                         rowWidth: hovered ? 320 : nil)
                    let frame = PresenceResize.panelFrame(for: layout)
                    #expect(frame == layout.frame, "no cap is added")
                    #expect(frame.maxY <= top + 0.001, "\(state.caseName) hovered=\(hovered)")
                }
            }
        }
    }

    /// Rest and hover frames share centre-x and the top edge, so growth is centred and downward.
    @Test func restAndHoverShareCentreAndTop() {
        for metrics in [notched, external] {
            let rest = PresenceGeometry.layout(for: metrics, state: .ready).frame
            for width: CGFloat in [190, 260, 360, 520] {
                let hover = PresenceGeometry.layout(for: metrics, state: .ready, hovered: true, rowWidth: width).frame
                #expect(PresenceResize.sharesAnchor(rest, hover))
                #expect(hover.width > rest.width && hover.height > rest.height)
            }
        }
    }

    @Test func growAnimatesAndRepeatedTargetIsANoOp() {
        let rest = PresenceGeometry.layout(for: notched, state: .ready).frame
        let hover = PresenceGeometry.layout(for: notched, state: .ready, hovered: true, rowWidth: 300).frame
        #expect(PresenceResize.step(current: rest, inFlightTarget: nil, target: hover,
                                    reduceMotion: false, visible: true) == .animate(hover))
        // The 5 Hz refresh mid-flight: same target → nothing restarts.
        let midFlight = rest.insetBy(dx: -40, dy: 0)
        #expect(PresenceResize.step(current: midFlight, inFlightTarget: hover, target: hover,
                                    reduceMotion: false, visible: true) == .none)
        // Pointer leaves mid-grow: a new target re-aims the animation.
        #expect(PresenceResize.step(current: midFlight, inFlightTarget: hover, target: rest,
                                    reduceMotion: false, visible: true) == .animate(rest))
        // Already there, nothing in flight.
        #expect(PresenceResize.step(current: hover, inFlightTarget: nil, target: hover,
                                    reduceMotion: false, visible: true) == .none)
    }

    @Test func reduceMotionHiddenOrMovedSnaps() {
        let rest = PresenceGeometry.layout(for: notched, state: .ready).frame
        let hover = PresenceGeometry.layout(for: notched, state: .ready, hovered: true, rowWidth: 300).frame
        #expect(PresenceResize.step(current: rest, inFlightTarget: nil, target: hover,
                                    reduceMotion: true, visible: true) == .snap(hover))
        #expect(PresenceResize.step(current: rest, inFlightTarget: nil, target: hover,
                                    reduceMotion: false, visible: false) == .snap(hover))
        let otherDisplay = PresenceGeometry.layout(for: external, state: .ready).frame
        #expect(PresenceResize.step(current: rest, inFlightTarget: nil, target: otherDisplay,
                                    reduceMotion: false, visible: true) == .snap(otherDisplay))
    }

    /// The old FX5 bug: the dot laid out mid-shrink. While collapsing, the chin draws nothing.
    @Test func dotOnlyAfterCollapse() {
        #expect(PresenceContent.kind(state: .ready, hovered: false, collapsing: true) == .empty)
        #expect(!PresenceContent.kind(state: .ready, hovered: false, collapsing: true).showsDot)
        #expect(PresenceContent.kind(state: .ready, hovered: false, collapsing: false) == .dot)
        // Other states' rest bodies are never withheld (muted must always be legible).
        #expect(PresenceContent.kind(state: .muted, hovered: false, collapsing: true) == .badge)
        let view = PresenceIndicatorView(state: .ready, hovered: false, cornerRadius: 6, hint: "", collapsing: true)
        #expect(view.contentKind == .empty)
    }
}
