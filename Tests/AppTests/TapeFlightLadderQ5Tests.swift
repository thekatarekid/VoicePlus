import CoreGraphics
import Foundation
import Injection
import Shared
import Testing
@testable import VoicePlusApp

/// V5 Q5 — the ribbon is independent of verification. It aims by a ladder — `AXBoundsForRange` →
/// Chromium/WebKit text-marker caret → focused element frame → focused window frame — and plays on
/// every landing except a contradicted one (`.targetChanged`).
@Suite("Q5 · ribbon independent of verification")
struct TapeFlightLadderQ5Tests {
    typealias T = TapeFlightTests

    /// A caret reader with every rung independently switchable.
    final class LadderCaret: TapeFlightCaretReading, @unchecked Sendable {
        var range: CGRect?
        var marker: CGRect?
        var element: CGRect?
        var window: CGRect?
        private(set) var askedRungs: [TapeFlightRung] = []
        init(range: CGRect? = nil, marker: CGRect? = nil, element: CGRect? = nil, window: CGRect? = nil) {
            (self.range, self.marker, self.element, self.window) = (range, marker, element, window)
        }
        func caretRect(at index: Int) -> CGRect? { askedRungs.append(.boundsForRange); return range }
        func textMarkerCaretRect() -> CGRect? { askedRungs.append(.textMarker); return marker }
        func focusedElementFrame() -> CGRect? { askedRungs.append(.elementFrame); return element }
        func focusedWindowFrame() -> CGRect? { askedRungs.append(.windowFrame); return window }
        func lineRects(_ range: Range<Int>) -> [CGRect] { [] }
    }

    static let rangeRect = CGRect(x: 300, y: 564, width: 0, height: 18)
    static let markerRect = CGRect(x: 320, y: 564, width: 1, height: 18)
    static let elementRect = CGRect(x: 200, y: 500, width: 400, height: 120)
    static let windowRect = CGRect(x: 100, y: 100, width: 900, height: 700)

    @Test func eachRungInOrder() {
        let all = LadderCaret(range: Self.rangeRect, marker: Self.markerRect, element: Self.elementRect, window: Self.windowRect)
        #expect(TapeFlightTargetLadder.resolve(insertionIndex: 5, caret: all) == TapeFlightFix(rect: Self.rangeRect, rung: .boundsForRange))
        #expect(all.askedRungs == [.boundsForRange], "stops at the first rung that answers")

        let marker = LadderCaret(marker: Self.markerRect, element: Self.elementRect, window: Self.windowRect)
        #expect(TapeFlightTargetLadder.resolve(insertionIndex: 5, caret: marker) == TapeFlightFix(rect: Self.markerRect, rung: .textMarker))

        let element = LadderCaret(element: Self.elementRect, window: Self.windowRect)
        #expect(TapeFlightTargetLadder.resolve(insertionIndex: 5, caret: element) == TapeFlightFix(rect: Self.elementRect, rung: .elementFrame))

        let window = LadderCaret(window: Self.windowRect)
        #expect(TapeFlightTargetLadder.resolve(insertionIndex: 5, caret: window) == TapeFlightFix(rect: Self.windowRect, rung: .windowFrame))
        #expect(window.askedRungs == [.boundsForRange, .textMarker, .elementFrame, .windowFrame])

        #expect(TapeFlightTargetLadder.resolve(insertionIndex: 5, caret: LadderCaret()) == nil)
    }

    @Test func noSelectionSkipsTheRangeRungAndBadGeometryIsSkipped() {
        let caret = LadderCaret(range: Self.rangeRect, marker: Self.markerRect)
        #expect(TapeFlightTargetLadder.resolve(insertionIndex: nil, caret: caret)?.rung == .textMarker)
        #expect(!caret.askedRungs.contains(.boundsForRange))
        let flat = LadderCaret(range: CGRect(x: 1, y: 1, width: 0, height: 0), marker: CGRect(x: CGFloat.nan, y: 0, width: 0, height: 9),
                               element: Self.elementRect)
        #expect(TapeFlightTargetLadder.resolve(insertionIndex: 3, caret: flat)?.rung == .elementFrame)
        #expect(TapeFlightRung.allCases.filter(\.isPrecise) == [.boundsForRange])
    }

    /// The controller with a ladder caret, for a field whose selection cannot be read.
    struct LadderHarness {
        let probe = T.FakeProbe(TapeFlightProbe(focus: T.textEdit, selection: nil))
        let caret: LadderCaret
        let surface = T.FakeSurface()
        let clock = T.Clock()
        let controller: TapeFlightController
        init(_ caret: LadderCaret) {
            self.caret = caret
            controller = TapeFlightController(reader: TapeFlightReader(probe: probe, caret: caret),
                                              mouth: { T.mouth }, displays: { [T.builtIn, T.external] },
                                              reduceMotion: { false }, surface: surface, clock: clock,
                                              queues: TapeFlightQueues(read: { $0() }, deliver: { $0() }))
        }
        func fly() {
            controller.stateChanged(.finalPreview(FinalPreviewInfo(text: T.text, dwellRemaining: 0.9)))
            controller.stateChanged(.inserting(text: T.text))
        }
    }

    @Test func unreadableFieldStillFliesByACoarseRung() {
        for (caret, rung) in [(LadderCaret(marker: Self.markerRect), TapeFlightRung.textMarker),
                              (LadderCaret(element: Self.elementRect), .elementFrame),
                              (LadderCaret(window: Self.windowRect), .windowFrame)] {
            let h = LadderHarness(caret)
            h.fly()
            #expect(h.surface.current != nil, "\(rung)")
            #expect(h.controller.aimRung == rung)
            // The unreadable landing (pill: neutral "Inserted in <app>") does not take the ribbon down…
            h.controller.stateChanged(.landed(LandedPillInfo(text: T.text, verdict: .unreadable)))
            #expect(h.surface.current != nil, "\(rung): plays through an unreadable landing")
            // …nor does its tail (the pill retracting after the landed dwell).
            h.clock.advance(PillDwell.inserted)
            h.controller.stateChanged(.hidden)
            #expect(h.surface.current != nil, "\(rung): the pill's retraction does not cut the ribbon")
            h.clock.advance(SpoolFlight.duration)
            #expect(h.controller.phase == .finished && h.surface.current == nil)
            #expect(h.surface.cues.isEmpty, "\(rung): no cue without a verified, precisely measured landing")
        }
    }

    @Test func unreadableReadbackStillPlaysOnAPreciseCaret() {
        let h = T.Harness()
        h.preview()
        h.insert()
        h.controller.stateChanged(.landed(LandedPillInfo(text: T.text, verdict: .unreadable)))
        #expect(h.surface.current != nil)
        h.controller.stateChanged(.hidden)
        #expect(h.surface.current != nil)
        h.clock.advance(SpoolFlight.duration + 0.01)
        #expect(h.controller.phase == .finished)
        #expect(!h.controller.suppressions.contains(.unconfirmed))
    }

    @Test func aContradictedLandingIsTheOnlyOneThatStopsIt() {
        let h = LadderHarness(LadderCaret(element: Self.elementRect))
        h.fly()
        #expect(h.surface.current != nil)
        // Focus moved to another element mid-flight: the refresh reads a contradicted target.
        h.probe.value = TapeFlightProbe(focus: FocusSnapshot(pid: 42, bundleID: "com.apple.TextEdit", elementToken: "900"),
                                        selection: nil)
        h.clock.advance(TapeFlightController.refreshInterval + 0.01)
        #expect(h.controller.phase == .suppressed(.targetChanged) && h.surface.current == nil)
    }

    @Test func nothingAtAnyRungSuppressesAsCaretUnavailable() {
        let h = LadderHarness(LadderCaret())
        h.fly()
        #expect(h.controller.phase == .suppressed(.caretUnavailable) && h.surface.shown.isEmpty)
    }
}
