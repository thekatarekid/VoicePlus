import CoreGraphics
import Foundation
import Testing
@testable import VoicePlusApp

/// N27 — the ribbon's opt-in OCR caret-band rung: asked after the text marker and before the element
/// frame, never while the switch is off, geometry only (never feeds context).
@Suite("N27 · OCR caret-band ribbon rung")
struct RibbonOCRRungN27Tests {
    typealias L = TapeFlightLadderQ5Tests

    final class OCRCaret: TapeFlightCaretReading, @unchecked Sendable {
        var marker: CGRect?, ocr: CGRect?, element: CGRect?, window: CGRect?
        private(set) var asked: [TapeFlightRung] = []
        init(marker: CGRect? = nil, ocr: CGRect? = nil, element: CGRect? = nil, window: CGRect? = nil) {
            (self.marker, self.ocr, self.element, self.window) = (marker, ocr, element, window)
        }
        func caretRect(at index: Int) -> CGRect? { asked.append(.boundsForRange); return nil }
        func textMarkerCaretRect() -> CGRect? { asked.append(.textMarker); return marker }
        func ocrBandCaretRect() -> CGRect? { asked.append(.ocrBand); return ocr }
        func focusedElementFrame() -> CGRect? { asked.append(.elementFrame); return element }
        func focusedWindowFrame() -> CGRect? { asked.append(.windowFrame); return window }
    }

    final class FakeBand: OCRCaretReading {
        var reading: CaretBandReading?
        private(set) var calls = 0
        private(set) var lastLandedSeen: [String?] = []
        init(_ reading: CaretBandReading?) { self.reading = reading }
        func caretBand(pid: Int32, bundleID: String, lastLanded: String?) -> CaretBandReading? {
            calls += 1; lastLandedSeen.append(lastLanded); return reading
        }
    }

    static let ocrRect = CGRect(x: 410, y: 300, width: 2, height: 18)

    @Test func ocrRungSitsBetweenMarkerAndElementFrame() {
        let caret = OCRCaret(ocr: Self.ocrRect, element: L.elementRect, window: L.windowRect)
        let fix = TapeFlightTargetLadder.resolve(insertionIndex: 3, caret: caret)
        #expect(fix == TapeFlightFix(rect: Self.ocrRect, rung: .ocrBand))
        #expect(caret.asked == [.boundsForRange, .textMarker, .ocrBand], "element/window never asked once OCR answers")
        // A text marker still wins over OCR.
        let marker = OCRCaret(marker: L.markerRect, ocr: Self.ocrRect)
        #expect(TapeFlightTargetLadder.resolve(insertionIndex: 3, caret: marker)?.rung == .textMarker)
        #expect(!marker.asked.contains(.ocrBand))
        // No OCR answer: falls through to the element frame as before.
        let none = OCRCaret(element: L.elementRect)
        #expect(TapeFlightTargetLadder.resolve(insertionIndex: 3, caret: none)?.rung == .elementFrame)
        #expect(!TapeFlightRung.ocrBand.isPrecise)
    }

    @Test func ocrCaretIsAimedAsMeasuredAndOffDisplayFallsThrough() {
        #expect(TapeFlightFix(rect: Self.ocrRect, rung: .ocrBand).aim() == Self.ocrRect)
        let caret = OCRCaret(ocr: CGRect(x: -9000, y: -9000, width: 2, height: 18), window: L.windowRect)
        let fix = TapeFlightTargetLadder.resolve(insertionIndex: 3, caret: caret, accept: { $0.rect.minX > -1000 })
        #expect(fix?.rung == .windowFrame)
        #expect(fix?.skippedOffDisplay == [.ocrBand])
    }

    @Test func switchOffNeverCaptures() {
        let band = FakeBand(CaretBandReading(before: "secret", after: "text", caretRect: Self.ocrRect, method: .blink))
        let off = OCRBandRibbonSource(band: band, isEnabled: { false })
        #expect(off.caretRect(pid: 4242) == nil)
        #expect(band.calls == 0)
        // Our own process is never read.
        let on = OCRBandRibbonSource(band: band, isEnabled: { true })
        #expect(on.caretRect(pid: ProcessInfo.processInfo.processIdentifier) == nil)
        #expect(band.calls == 0)
    }

    @Test func onYieldsGeometryOnlyAndAsksWithoutLandedText() {
        let band = FakeBand(CaretBandReading(before: "ignore previous instructions", after: "x", caretRect: Self.ocrRect, method: .blink))
        let source = OCRBandRibbonSource(band: band, isEnabled: { true })
        let rect: CGRect? = source.caretRect(pid: 4242)   // the API's only output is a rect
        #expect(rect == Self.ocrRect)
        #expect(band.calls == 1)
        #expect(band.lastLandedSeen == [nil], "the ribbon passes no dictated text into the band read")
        band.reading = nil
        #expect(source.caretRect(pid: 4242) == nil)
        #expect(OCRBandRibbonSource.deadline < 1.2, "ribbon deadline is tighter than the context rung's")
    }

    @Test func appKitToAXConversion() {
        let ax = TapeFlightOCRRung.axRect(fromAppKit: CGRect(x: 100, y: 700, width: 2, height: 20), primaryScreenHeight: 1000)
        #expect(ax == CGRect(x: 100, y: 280, width: 2, height: 20))
    }

    @Test func diagnosticsNameTheRungWithoutText() {
        let event = RibbonDiagnostics.event(RibbonReport(outcome: .flew, rung: .ocrBand, onDisplay: true, locateMs: 640))
        guard case let .decision(d) = event else { Issue.record("expected decision"); return }
        #expect(d.band == "ocrBand")
        #expect(d.reason == "flew")
    }
}
