import CoreGraphics
import Foundation
import Injection
import Pipeline
import Shared
import Testing
@testable import VoicePlusApp

/// V5 K10 — the caret ladder: AX → landing memory → OCR (only if opted in) → unknown, the rung
/// recorded per app, rungs an app never answers skipped.
@Suite("V5 K10 · context ladder")
struct ContextLadderK10Tests {

    final class MockOCR: OCRCaretReading {
        var result: CaretBandReading?
        private(set) var calls = 0
        func caretBand(pid: Int32, bundleID: String, lastLanded: String?) -> CaretBandReading? { calls += 1; return result }
    }

    static let figma = "com.figma.Desktop"

    private func canvas(bundle: String = ContextLadderK10Tests.figma) -> MockSystemAccess {
        let s = MockSystemAccess(frontmost: FocusSnapshot(pid: 4242, bundleID: bundle, appName: "Canvas", elementToken: "el"))
        s.field = .init(role: "AXGroup", value: "")
        s.axReadable = false
        s.axCaretReadable = false
        return s
    }

    private func reader(_ s: MockSystemAccess, ocr: MockOCR, optIn: Bool, contextual: Bool = true) -> FieldContextReader {
        let r = FieldContextReader(system: s, unknownApps: UnknownApps(log: Log(category: "test")), ocr: ocr)
        r.ocrOptIn = { optIn }
        r.contextualReading = { _ in contextual }
        return r
    }

    private let band = CaretBandReading(before: "Hello wor", after: "ld", caretRect: CGRect(x: 10, y: 20, width: 2, height: 14),
                                        method: .blink)

    @Test
    func ocrIsTheLastRungAndOnlyWhenOptedIn() throws {
        let ocr = MockOCR(); ocr.result = band
        let off = reader(canvas(), ocr: ocr, optIn: false)
        #expect(off.fieldContext(bundleID: Self.figma)?.caret == .unknown)
        #expect(ocr.calls == 0, "opted out: the OCR rung is never asked")

        let on = reader(canvas(), ocr: ocr, optIn: true)
        let field = try #require(on.fieldContext(bundleID: Self.figma))
        #expect(field.caret == .known(before: "Hello wor", after: "ld"))
        #expect(on.lastReading?.rung == .ocr)
        #expect(on.lastReading?.caretRect == band.caretRect, "Q5 anchor")
        #expect(on.capabilities.lastRung(for: Self.figma) == .ocr)
    }

    @Test
    func contextualReadingOffBlocksOCR() {
        let ocr = MockOCR(); ocr.result = band
        _ = reader(canvas(), ocr: ocr, optIn: true, contextual: false).fieldContext(bundleID: Self.figma)
        #expect(ocr.calls == 0)
    }

    @Test
    func axAnswersFirstAndOCRIsNotAsked() {
        let s = MockSystemAccess(frontmost: FocusSnapshot(pid: 4242, bundleID: "com.apple.TextEdit", appName: "T", elementToken: "el"))
        s.field = .init(role: "AXTextArea", value: "Hello")
        let ocr = MockOCR(); ocr.result = band
        let r = reader(s, ocr: ocr, optIn: true)
        _ = r.fieldContext(bundleID: "com.apple.TextEdit")
        #expect(r.lastReading?.rung == .selectedRange)
        #expect(r.capabilities.lastRung(for: "com.apple.TextEdit") == .selectedRange)
        #expect(ocr.calls == 0)
    }

    @Test
    func landingMemoryAnswersBeforeOCR() {
        let s = canvas()
        let ocr = MockOCR(); ocr.result = band
        let r = reader(s, ocr: ocr, optIn: true)
        let element = LandedElement(bundleID: Self.figma, role: "AXGroup", elementToken: "el")
        r.landingMemory.record(text: "We landed this.", in: element)
        _ = r.fieldContext(bundleID: Self.figma)
        #expect(r.lastReading?.rung == .landingMemory)
        #expect(ocr.calls == 0)
    }

    @Test
    func anAppWhoseBandNeverAnswersIsSkipped() {
        let ocr = MockOCR()   // never finds the caret
        let r = reader(canvas(), ocr: ocr, optIn: true)
        for _ in 0..<(CaretCapabilityMemory.defaultThreshold + 3) { _ = r.fieldContext(bundleID: Self.figma) }
        #expect(ocr.calls == CaretCapabilityMemory.defaultThreshold)
        #expect(r.capabilities.shouldSkip(.ocr, bundleID: Self.figma))
        #expect(r.capabilities.lastRung(for: Self.figma) == CaretRung.none)
    }

    @Test
    func anAnswerResetsTheRungCount() {
        let memory = CaretCapabilityMemory(threshold: 2)
        memory.note(bundleID: "x", rung: .ocr, answered: false)
        #expect(memory.misses(for: "x", rung: .ocr) == 1)
        memory.note(bundleID: "x", rung: .ocr, answered: true)
        #expect(memory.misses(for: "x", rung: .ocr) == 0)
        #expect(!memory.shouldSkip(.selectedRange, bundleID: "x") && !memory.shouldSkip(.landingMemory, bundleID: "x"))
    }

    @Test
    func passwordFieldNeverReachesOCR() {
        let s = canvas()
        s.field = .secure()
        let ocr = MockOCR(); ocr.result = band
        _ = reader(s, ocr: ocr, optIn: true).fieldContext(bundleID: Self.figma)
        #expect(ocr.calls == 0)
    }
}
