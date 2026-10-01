import CoreGraphics
import Foundation
import Pipeline
import Shared
import Testing
@testable import VoicePlusApp

/// V5 Q14 + K9 — the OCR caret band: mapping math, locating the caret by landed text and by the
/// blink diff, and the opt-out audit (nothing is captured unless the switch is on).
@Suite("V5 Q14 · OCR caret band")
struct CaretBandQ14Tests {
    typealias T = ScreenTextServiceTests

    static func line(_ text: String, x: CGFloat = 100, y: CGFloat, width: CGFloat? = nil, h: CGFloat = 16) -> ScreenTextLine {
        ScreenTextLine(text: text, box: CGRect(x: x, y: y, width: width ?? CGFloat(text.count) * 8, height: h), confidence: 0.9)
    }

    // MARK: mapping math

    @Test func bandIsThreeLinesCentredAndClipped() {
        let window = CGRect(x: 0, y: 0, width: 800, height: 600)
        let caret = CGRect(x: 300, y: 292, width: 2, height: 16)
        let band = CaretBandGeometry.band(around: caret, lineHeight: 20, within: window)
        #expect(band == CGRect(x: 0, y: 270, width: 800, height: 60))
        let top = CaretBandGeometry.band(around: CGRect(x: 0, y: 590, width: 2, height: 16), lineHeight: 20, within: window)
        #expect(top.maxY == 600 && top.height < 60, "clipped to the window")
    }

    @Test func caretXAndIndexAreInverse() {
        let l = Self.line("Hello world", y: 100)             // 88 pt wide, 8 pt per character
        #expect(CaretBandGeometry.caretX(in: l, afterCharacters: 5) == 140)
        #expect(CaretBandGeometry.characterIndex(in: l, atX: 140) == 5)
        #expect(CaretBandGeometry.characterIndex(in: l, atX: 0) == 0)
        #expect(CaretBandGeometry.characterIndex(in: l, atX: 10_000) == 11)
        #expect(CaretBandGeometry.caretRect(in: l, afterCharacters: 11) == CGRect(x: 187, y: 100, width: 2, height: 16))
    }

    // MARK: locating

    @Test func locateByLandedTextFillsTheThreeLineBand() throws {
        let lines = [Self.line("Dear team,", y: 140), Self.line("The launch moved to Friday because", y: 120),
                     Self.line("of the review.", y: 100)]
        let r = try #require(CaretBandLocator.locate(lines: lines, lastLanded: "the launch moved to Friday"))
        #expect(r.before == "Dear team,\nThe launch moved to Friday")
        #expect(r.after == " because\nof the review.")
        #expect(r.method == .landedText)
        #expect(abs(r.caretRect.midX - (100 + 26 * 8)) < 0.001)
    }

    @Test func landedTextNotOnScreenIsNil() {
        #expect(CaretBandLocator.locate(lines: [Self.line("something else", y: 10)], lastLanded: "never typed") == nil)
        #expect(CaretBandLocator.locate(lines: [Self.line("ab", y: 10)], lastLanded: "ab") == nil, "too short to trust")
    }

    @Test func locateByCaretRectSplitsTheLine() throws {
        let lines = [Self.line("first", y: 140), Self.line("Hello world", y: 120), Self.line("last", y: 100)]
        let caret = CGRect(x: 139, y: 121, width: 2, height: 14)
        let r = try #require(CaretBandLocator.locate(lines: lines, caret: caret))
        #expect(r.before == "first\nHello")
        #expect(r.after == " world\nlast")
        #expect(r.caretRect == caret)
        #expect(CaretBandLocator.locate(lines: lines, caret: CGRect(x: 0, y: 500, width: 2, height: 14)) == nil)
    }

    // MARK: blink diff

    static func frame(width: Int, height: Int, bar: CGRect?) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let bar { ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1)); ctx.fill(bar) }
        return ctx.makeImage()!
    }

    @Test func blinkDiffFindsANarrowBar() throws {
        // 200×100 pt at 2×; the bar is 2 px wide, 30 px tall (1×15 pt) at pixel x=80 from the left.
        let mapping = ScreenPixelMapping(pointRect: CGRect(x: 0, y: 0, width: 200, height: 100), scale: 2)
        let on = Self.frame(width: 400, height: 200, bar: CGRect(x: 80, y: 100, width: 2, height: 30))
        let off = Self.frame(width: 400, height: 200, bar: nil)
        let rect = try #require(CaretBlink.caretRect(on, off, mapping: mapping))
        #expect(rect.width == 1 && rect.height == 15 && rect.minX == 40)
        #expect(CaretBlink.caretRect(off, off, mapping: mapping) == nil, "no change, no caret")
        let wide = Self.frame(width: 400, height: 200, bar: CGRect(x: 80, y: 100, width: 120, height: 30))
        #expect(CaretBlink.caretRect(wide, off, mapping: mapping) == nil, "typing / scrolling is not a caret")
    }

    // MARK: the service and the opt-out audit

    final class BlinkCapturer: ScreenFrameCapturing {
        var calls = 0
        func capture(_ rect: CGRect, display: CGDirectDisplayID) async throws -> CapturedRegion {
            calls += 1
            let mapping = ScreenPixelMapping(pointRect: rect, scale: 1)
            let bar: CGRect? = calls == 1 ? CGRect(x: 40, y: 40, width: 2, height: 16) : nil
            return CapturedRegion(image: CaretBandQ14Tests.frame(width: Int(rect.width), height: Int(rect.height), bar: bar),
                                  mapping: mapping, windowID: 7)
        }
    }

    @Test func serviceFindsTheCaretByLandedTextWithOneFrame() async throws {
        let capturer = T.Capturer(scale: 1)
        let anchor = CGRect(x: 0, y: 0, width: 400, height: 100)
        // Vision boxes are normalised over the frame, origin bottom-left.
        let recognizer = T.Recognizer(lines: [RecognizedLine(text: "see you on Friday", normalizedBox: CGRect(x: 0.1, y: 0.4, width: 0.5, height: 0.16), confidence: 0.9)])
        let service = ScreenTextService(access: T.Access(granted: true), capturer: capturer, recognizer: recognizer,
                                        configuredLanguages: { [] })
        let r = try #require(try await service.caretBand(around: anchor, display: 1, lastLanded: "see you on Friday", blinkInterval: 0))
        #expect(r.method == .landedText && r.before == "see you on Friday" && r.after.isEmpty)
        #expect(capturer.calls.count == 1)
        #expect(service.heldFrameCount == 0, "frames are dropped after the read")
    }

    @Test func serviceFallsBackToTheBlink() async throws {
        let capturer = BlinkCapturer()
        let recognizer = T.Recognizer(lines: [RecognizedLine(text: "Hello world", normalizedBox: CGRect(x: 0, y: 0.2, width: 1, height: 0.6), confidence: 0.9)])
        let service = ScreenTextService(access: T.Access(granted: true), capturer: capturer, recognizer: recognizer,
                                        configuredLanguages: { [] })
        let r = try await service.caretBand(around: CGRect(x: 0, y: 0, width: 200, height: 100), display: 1, lastLanded: nil,
                                            blinkInterval: 0)
        #expect(capturer.calls == 2)
        #expect(r?.method == .blink)
        #expect(service.heldFrameCount == 0)
    }

    @Test func noPermissionNeverCapturesOrAsks() async {
        let access = T.Access(granted: false)
        let capturer = T.Capturer()
        let service = ScreenTextService(access: access, capturer: capturer, recognizer: T.Recognizer(lines: []),
                                        configuredLanguages: { [] })
        await #expect(throws: ScreenTextError.permissionDenied) {
            _ = try await service.caretBand(around: CGRect(x: 0, y: 0, width: 10, height: 10), display: 1, lastLanded: "x")
        }
        #expect(capturer.calls.isEmpty && access.requests == 0)
        // The live rung checks the switch before anything else: off → no preflight, no capture.
        let live = LiveOCRCaret(service: service, isEnabled: { false })
        #expect(live.caretBand(pid: 4242, bundleID: "com.figma.Desktop", lastLanded: "x") == nil)
        #expect(capturer.calls.isEmpty)
    }

    @Test func switchIsOffByDefault() {
        let defaults = UserDefaults(suiteName: "q14-\(UUID().uuidString)")!
        #expect(CaretOCRSettings.isEnabled(defaults) == false)
        defaults.set(true, forKey: CaretOCRSettings.enabledKey)
        #expect(CaretOCRSettings.isEnabled(defaults))
    }
}
