import CoreGraphics
import Foundation
import Injection
import Shared
import Testing
@testable import VoicePlusApp

/// N19 (F17 + F18) — ribbon misses in Claude, x.com and Docs: a zero-width caret rect is a caret, coarse
/// rungs aim at the first line's leading edge, a rung whose rect is off every display falls through to the
/// next, and every insertion leaves one geometry-only ribbon event.
@Suite("N19 · ribbon aim, fall-through and diagnostics")
struct RibbonN19Tests {
    typealias T = TapeFlightTests
    typealias L = TapeFlightLadderQ5Tests

    // MARK: Geometry (F17)

    @Test func zeroWidthNextCharacterIsACaret() {
        // Claude's empty composer: AXValue "\n"; the caret itself is unmeasured, the "\n" measures width 0.
        let rect = TapeFlightCaretLocator.locate(at: 0) { range in
            range.isEmpty ? nil : CGRect(x: 412, y: 700, width: 0, height: 19)
        }
        #expect(rect == CGRect(x: 412, y: 700, width: 0, height: 19))
        // Same for the previous character at the end of a line.
        let before = TapeFlightCaretLocator.locate(at: 3) { range in
            range.lowerBound == 2 ? CGRect(x: 40, y: 10, width: 0, height: 17) : nil
        }
        #expect(before == CGRect(x: 40, y: 10, width: 0, height: 17))
        // Zero height is still not geometry.
        #expect(TapeFlightCaretLocator.locate(at: 0) { _ in CGRect(x: 1, y: 1, width: 0, height: 0) } == nil)
    }

    /// Regression references: a measured Notes caret and a Spotlight next-character rect are unchanged.
    @Test func notesAndSpotlightAimAsBefore() {
        let notes = CGRect(x: 300, y: 564, width: 0, height: 18)
        #expect(TapeFlightCaretLocator.locate(at: 5) { $0.isEmpty ? notes : nil } == notes)
        let spotlight = TapeFlightCaretLocator.locate(at: 2) { r in
            r.isEmpty ? nil : CGRect(x: 520, y: 220, width: 11, height: 26)
        }
        #expect(spotlight == CGRect(x: 520, y: 220, width: 0, height: 26))
        // The precise rung is aimed as measured.
        #expect(TapeFlightFix(rect: notes, rung: .boundsForRange).aim() == notes)
    }

    @Test func coarseRungsAimAtTheLeadingEdgeOfTheFirstLine() {
        let box = CGRect(x: 200, y: 500, width: 400, height: 120)
        let ltr = TapeFlightFix(rect: box, rung: .elementFrame).aim()
        #expect(ltr == CGRect(x: 210, y: 508, width: 0, height: 20))
        let rtl = TapeFlightFix(rect: box, rung: .elementFrame).aim(rightToLeft: true)
        #expect(rtl == CGRect(x: 590, y: 508, width: 0, height: 20))
        // A one-line field: the line is the box's own height, vertically centred.
        let slim = TapeFlightFix(rect: CGRect(x: 0, y: 0, width: 300, height: 16), rung: .elementFrame).aim()
        #expect(slim == CGRect(x: 10, y: 0, width: 0, height: 16))
        // A box-wide text marker is coarse too; a caret-narrow one is a caret.
        #expect(TapeFlightFix(rect: box, rung: .textMarker).aim() == ltr)
        let marker = CGRect(x: 320, y: 564, width: 1, height: 18)
        #expect(TapeFlightFix(rect: marker, rung: .textMarker).aim() == marker)
        // A window's first-line edge is its title bar: it stays centred.
        #expect(TapeFlightFix(rect: L.windowRect, rung: .windowFrame).aim() == L.windowRect)
    }

    // MARK: Fall-through (F18)

    static let offDisplay = CGRect(x: -9000, y: -9000, width: 0, height: 18)

    @Test func ladderSkipsARungThatIsOffEveryDisplay() {
        let displays = [T.builtIn, T.external]
        let caret = L.LadderCaret(range: Self.offDisplay, marker: Self.offDisplay, element: L.elementRect, window: L.windowRect)
        let fix = TapeFlightTargetLadder.resolve(insertionIndex: 5, caret: caret) {
            TapeFlightGeometry.isOnDisplay(axRect: $0.aim(), displays: displays)
        }
        #expect(fix?.rung == .elementFrame)
        #expect(fix?.skippedOffDisplay == [.boundsForRange, .textMarker])
        #expect(caret.askedRungs == [.boundsForRange, .textMarker, .elementFrame], "a lower rung is never read")
        #expect(TapeFlightGeometry.isOnDisplay(axRect: T.caretAX, displays: displays))
        #expect(!TapeFlightGeometry.isOnDisplay(axRect: Self.offDisplay, displays: displays))
    }

    struct Harness {
        let probe = T.FakeProbe(T.caret)
        let caret: L.LadderCaret
        let surface = T.FakeSurface()
        let clock = T.Clock()
        let controller: TapeFlightController
        let sink = Sink()
        final class Sink: @unchecked Sendable { var reports: [RibbonReport] = [] }
        init(_ caret: L.LadderCaret) {
            self.caret = caret
            let sink = self.sink
            controller = TapeFlightController(reader: TapeFlightReader(probe: probe, caret: caret),
                                              mouth: { T.mouth }, displays: { [T.builtIn, T.external] },
                                              reduceMotion: { false }, surface: surface, clock: clock,
                                              queues: TapeFlightQueues(read: { $0() }, deliver: { $0() }),
                                              diagnostics: { sink.reports.append($0) })
        }
        func fly() {
            controller.stateChanged(.finalPreview(FinalPreviewInfo(text: T.text, dwellRemaining: 0.9)))
            controller.stateChanged(.inserting(text: T.text))
        }
    }

    /// Docs: rung 1 answers with a rect off every display; the flight falls to the element frame (rung 3)
    /// instead of suppressing, and aims at its leading edge.
    @Test func offDisplayRungOneFallsToRungThree() {
        let h = Harness(L.LadderCaret(range: Self.offDisplay, element: L.elementRect))
        h.fly()
        #expect(h.surface.current != nil)
        #expect(h.controller.aimRung == .elementFrame)
        guard case .flying(let path) = h.controller.phase else { Issue.record("not flying"); return }
        // Leading edge (210, 518) in AX → AppKit y 982 − 518 = 464 → overlay y 982 − 464 = 518.
        #expect(abs(path.to.x - 210) < 1e-9 && abs(path.to.y - 518) < 1e-9)
        #expect(h.sink.reports == [RibbonReport(outcome: .flew, rung: .elementFrame, onDisplay: true, locateMs: 0,
                                                skippedOffDisplay: [.boundsForRange])])
        #expect(h.controller.ribbonReports == h.sink.reports)
    }

    @Test func suppressionIsReportedOncePerInsertion() {
        let h = Harness(L.LadderCaret(range: Self.offDisplay))
        h.fly()
        #expect(h.controller.phase == .suppressed(.caretUnavailable))
        #expect(h.sink.reports == [RibbonReport(outcome: .suppressed(.caretUnavailable), rung: nil, onDisplay: nil,
                                                locateMs: 0)])
    }

    @Test func invalidationAfterFlyingIsReported() {
        let h = Harness(L.LadderCaret(element: L.elementRect))
        h.fly()
        h.probe.value = TapeFlightProbe(focus: FocusSnapshot(pid: 42, bundleID: "com.apple.TextEdit", elementToken: "900"),
                                        selection: nil)
        h.clock.advance(TapeFlightController.refreshInterval + 0.01)
        #expect(h.controller.phase == .suppressed(.targetChanged))
        #expect(h.sink.reports.map(\.outcome) == [.flew, .invalidated(.targetChanged)])
    }

    @Test func previewWithoutInsertionReportsNothing() {
        let h = Harness(L.LadderCaret(element: L.elementRect))
        h.controller.stateChanged(.finalPreview(FinalPreviewInfo(text: T.text, dwellRemaining: 0.9)))
        h.controller.stateChanged(.hidden)
        #expect(h.sink.reports.isEmpty)
    }

    // MARK: Q13 event

    @Test func eventIsGeometryOnly() {
        let event = RibbonDiagnostics.event(RibbonReport(outcome: .flew, rung: .elementFrame, onDisplay: true,
                                                         locateMs: 42, skippedOffDisplay: [.boundsForRange]))
        guard case let .decision(d) = event else { Issue.record("not a decision event"); return }
        #expect(d.owner == "ribbon" && d.band == "elementFrame" && d.confidence == 1)
        #expect(d.reason == "flew; skipped off-display: boundsForRange")
        #expect(d.questionProbabilities == ["locateMs": 42, "onDisplay": 1, "offDisplaySkipped": 1])
        let suppressed = RibbonDiagnostics.event(RibbonReport(outcome: .suppressed(.targetChanged), rung: nil,
                                                              onDisplay: nil, locateMs: nil))
        guard case let .decision(s) = suppressed else { return }
        #expect(s.reason == "suppressed: targetChanged" && s.band == nil && s.confidence == 0)
        #expect(s.questionProbabilities == ["offDisplaySkipped": 0])
    }
}
