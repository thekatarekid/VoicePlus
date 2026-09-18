import Actions
import CoreGraphics
import Foundation
import Pipeline
import Shared
import Testing
@testable import VoicePlusApp

/// G2 — the screen capture + OCR service behind `ScreenTextReader`, through its seams: point ↔
/// pixel conversion, the recognition policy, the per-turn frame store, and the Screen Recording
/// permission state machine. The live ScreenCaptureKit / Vision paths need a window server and the
/// grant; they are not exercised here (§5 item 6).
@Suite("G2 screen text service")
struct ScreenTextServiceTests {
    final class Access: ScreenRecordingAccess {
        var granted: Bool
        var requests = 0
        var grantOnRequest = false
        init(granted: Bool) { self.granted = granted }
        func preflight() -> Bool { granted }
        func request() -> Bool { requests += 1; if grantOnRequest { granted = true }; return granted }
    }

    final class Capturer: ScreenFrameCapturing {
        var calls: [CGRect] = []
        let scale: CGFloat
        init(scale: CGFloat = 2) { self.scale = scale }
        func capture(_ rect: CGRect, display: CGDirectDisplayID) async throws -> CapturedRegion {
            calls.append(rect)
            let mapping = ScreenPixelMapping(pointRect: rect, scale: scale)
            return CapturedRegion(image: ScreenTextServiceTests.image(mapping.pixelSize), mapping: mapping, windowID: 42)
        }
    }

    final class Recognizer: TextRecognizing {
        var lines: [RecognizedLine]
        var calls: [TextRecognitionOptions] = []
        var supportedLanguages = ["en-US", "fr-FR", "de-DE", "zh-Hans"]
        init(lines: [RecognizedLine]) { self.lines = lines }
        func recognize(_ image: CGImage, options: TextRecognitionOptions) throws -> [RecognizedLine] {
            calls.append(options)
            return lines
        }
    }

    static func image(_ size: CGSize) -> CGImage {
        let ctx = CGContext(data: nil, width: max(1, Int(size.width)), height: max(1, Int(size.height)), bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    static func close(_ a: CGRect, _ b: CGRect, _ e: CGFloat = 1e-9) -> Bool {
        abs(a.minX - b.minX) < e && abs(a.minY - b.minY) < e && abs(a.width - b.width) < e && abs(a.height - b.height) < e
    }

    // MARK: point ↔ pixel

    @Test func pointsToPixelsFlipsAndScales() {
        // A 400×200 pt window whose bottom-left is at (100, 300), captured at 2×.
        let m = ScreenPixelMapping(pointRect: CGRect(x: 100, y: 300, width: 400, height: 200), scale: 2)
        #expect(m.pixelSize == CGSize(width: 800, height: 400))
        // The window's top-left 50×20 pt corner is the image's first 100×40 px.
        #expect(m.pixelRect(forPoints: CGRect(x: 100, y: 480, width: 50, height: 20)) == CGRect(x: 0, y: 0, width: 100, height: 40))
        // Bottom-right corner.
        #expect(m.pixelRect(forPoints: CGRect(x: 450, y: 300, width: 50, height: 20)) == CGRect(x: 700, y: 360, width: 100, height: 40))
        // Fractional points round outward to whole pixels; outside the image clips; disjoint is empty.
        #expect(m.pixelRect(forPoints: CGRect(x: 100.3, y: 480.2, width: 10, height: 10)) == CGRect(x: 0, y: 19, width: 21, height: 21))
        #expect(m.pixelRect(forPoints: CGRect(x: 0, y: 0, width: 150, height: 350)) == CGRect(x: 0, y: 300, width: 100, height: 100))
        #expect(m.pixelRect(forPoints: CGRect(x: 0, y: 0, width: 10, height: 10)) == .zero)
    }

    @Test func pixelsToPointsRoundTrips() {
        let m = ScreenPixelMapping(pointRect: CGRect(x: -1440, y: 180, width: 1440, height: 900), scale: 2)
        for r in [CGRect(x: -1400, y: 200, width: 300, height: 90), CGRect(x: -100, y: 1000, width: 100, height: 80)] {
            #expect(m.pointRect(forPixels: m.pixelRect(forPoints: r)) == r)
        }
        // A cropped mapping keeps the scale and names the crop's points.
        let crop = m.pixelRect(forPoints: CGRect(x: -1400, y: 200, width: 300, height: 90))
        #expect(m.cropped(to: crop) == ScreenPixelMapping(pointRect: CGRect(x: -1400, y: 200, width: 300, height: 90), scale: 2))
    }

    @Test func visionBoxesBecomeGlobalPoints() {
        // Box image of 200×100 pt at 2×; Vision reports the top half's left quarter as one line.
        let m = ScreenPixelMapping(pointRect: CGRect(x: 1000, y: 500, width: 200, height: 100), scale: 2)
        let crop = CGRect(origin: .zero, size: m.pixelSize)
        let box = m.pointRect(forNormalized: CGRect(x: 0, y: 0.5, width: 0.25, height: 0.5), inPixelCrop: crop)
        #expect(Self.close(box, CGRect(x: 1000, y: 550, width: 50, height: 50)))
        let frame = CapturedRegion(image: Self.image(m.pixelSize), mapping: m, windowID: nil)
        let lines = ScreenTextService.lines(from: [
            RecognizedLine(text: "second", normalizedBox: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.2), confidence: 0.4),
            RecognizedLine(text: "  ", normalizedBox: CGRect(x: 0, y: 0, width: 1, height: 1), confidence: 1),
            RecognizedLine(text: "first", normalizedBox: CGRect(x: 0.1, y: 0.7, width: 0.5, height: 0.2), confidence: 0.9),
        ], frame: frame)
        #expect(lines.map(\.text) == ["first", "second"])       // reading order, blanks dropped
        #expect(Self.close(lines[0].box, CGRect(x: 1020, y: 570, width: 100, height: 20)))
        #expect(lines[1].isLowConfidence)
    }

    // MARK: recognition policy

    @Test func languageCorrectionFollowsTheFieldRole() {
        func correction(_ role: FieldRole) -> Bool {
            TextRecognitionOptions.policy(role: role, customWords: [], configuredLanguages: [], supportedLanguages: ["en-US"])
                .usesLanguageCorrection
        }
        #expect(correction(.multilineText) && correction(.singleLineText) && correction(.unknown))
        #expect(!correction(.terminal) && !correction(.codeEditor) && !correction(.secure))
    }

    @Test func customWordsAndLanguages() {
        let o = TextRecognitionOptions.policy(role: .multilineText, customWords: ["Kubernetes", " kubernetes ", "", "VoicePlus"],
                                              configuredLanguages: ["en-GB", "fr_FR", "ja-JP", "de"],
                                              supportedLanguages: ["en-US", "fr-FR", "de-DE"])
        #expect(o.accurate)
        #expect(o.customWords == ["Kubernetes", "VoicePlus"])
        #expect(o.languages == ["en-US", "fr-FR", "de-DE"])        // English first; unsupported ja dropped
        let many = TextRecognitionOptions.policy(role: .unknown, customWords: (0..<400).map { "w\($0)" },
                                                 configuredLanguages: [], supportedLanguages: [])
        #expect(many.customWords.count == TextRecognitionOptions.customWordLimit && many.languages == ["en-US"])
    }

    // MARK: the service over mocks

    @Test func linesCaptureRecogniseAndHoldTheFrameForTheTurn() async throws {
        let access = Access(granted: true)
        let capturer = Capturer()
        let recognizer = Recognizer(lines: [RecognizedLine(text: "Send the deck", normalizedBox: CGRect(x: 0, y: 0, width: 1, height: 1), confidence: 0.95)])
        let service = ScreenTextService(access: access, capturer: capturer, recognizer: recognizer,
                                        customWords: { ["Figma"] }, configuredLanguages: { ["fr-FR"] })
        let rect = CGRect(x: 10, y: 20, width: 320, height: 90)
        let reader: ScreenTextReader = service
        let lines = try await reader.lines(in: rect, display: 1)
        #expect(lines.map(\.text) == ["Send the deck"] && lines[0].box == rect)
        #expect(capturer.calls == [rect])
        #expect(recognizer.calls.first?.customWords == ["Figma"] && recognizer.calls.first?.languages == ["en-US", "fr-FR"])
        #expect(service.heldFrameCount == 1)
        service.discardFrames()
        #expect(service.heldFrameCount == 0)
    }

    @Test func noGrantNoCapture() async {
        let capturer = Capturer()
        let service = ScreenTextService(access: Access(granted: false), capturer: capturer, recognizer: Recognizer(lines: []))
        await #expect(throws: ScreenTextError.permissionDenied) {
            _ = try await service.lines(in: CGRect(x: 0, y: 0, width: 10, height: 10), display: 1)
        }
        #expect(capturer.calls.isEmpty && service.heldFrameCount == 0)
    }

    @Test func codeRoleTurnsCorrectionOff() async throws {
        let recognizer = Recognizer(lines: [])
        let service = ScreenTextService(access: Access(granted: true), capturer: Capturer(), recognizer: recognizer)
        let frame = try await service.capture(CGRect(x: 0, y: 0, width: 50, height: 50), display: 1)
        _ = try await service.recognize(frame, role: .codeEditor)
        #expect(recognizer.calls.first?.usesLanguageCorrection == false)
        #expect(service.image(for: frame.id) != nil)
    }

    // MARK: permission state machine

    @Test func screenRecordingConsentStateMachine() {
        var c = ScreenRecordingConsent()
        #expect(c.status == .notDetermined && !c.allowsCapture)
        // First box without the grant: explain once, ask once.
        #expect(c.boxDrawn(preflight: false) == .explainAndRequest(explanation: OptionalPermission.screenRecording.rationale))
        c.requestReturned(granted: false)
        #expect(c.status == .awaitingUserAction && c.hasRequested)
        // Every later box without it: AX text only, with the pill line.
        #expect(c.boxDrawn(preflight: false) == .axOnly(notice: "Screen text isn't available"))
        // Granted in System Settings (and seen by a relaunched app): capture.
        #expect(c.boxDrawn(preflight: true) == .capture)
        #expect(c.status == .granted && c.allowsCapture)
        // Revoked later: denied, AX only, never asked again.
        #expect(c.boxDrawn(preflight: false) == .axOnly(notice: ScreenRecordingConsent.unavailableNotice))
        #expect(c.status == .denied)
        // A persisted "already asked" skips the explanation on a fresh launch.
        var relaunched = ScreenRecordingConsent(hasRequested: true)
        #expect(relaunched.boxDrawn(preflight: false) == .axOnly(notice: ScreenRecordingConsent.unavailableNotice))
        #expect(relaunched.status == .denied)
    }

    @Test func optionalPermissionStaysOutOfTheRequiredWalk() {
        #expect(!Permission.allCases.map(\.rawValue).contains(OptionalPermission.screenRecording.rawValue))
        #expect(PermissionPlanner.nextStep([.microphone: .granted, .accessibility: .granted]) == .allGranted)
        let p = OptionalPermission.screenRecording
        #expect(p.title == "Screen Recording" && !p.isPromptable && !p.grantReachesRunningApp)
        #expect(p.settingsURLs.first?.absoluteString.hasSuffix("Privacy_ScreenCapture") == true)
        #expect(!p.rationale.isEmpty && !p.rationale.contains("\n"))
    }
}
