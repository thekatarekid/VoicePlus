import Actions
import CoreGraphics
import Foundation
import Pipeline
import Shared
import Testing
@testable import VoicePlusApp

/// G3 — a drawn box → element + text + image, through `DeixisService` with a mock hit-tester, a
/// mock AX text reader and a mock screen. G2's permission rule as the service applies it.
@Suite("G3 box → element + text + image")
struct DeixisRegionServiceTests {
    final class Access: ScreenRecordingAccess {
        var granted: Bool
        var requests = 0
        var onRequest: (() -> Void)?
        init(granted: Bool) { self.granted = granted }
        func preflight() -> Bool { granted }
        func request() -> Bool { requests += 1; onRequest?(); return granted }
    }

    final class Screen: ScreenRegionReading {
        let access: ScreenRecordingAccess
        var lines: [ScreenTextLine]
        private(set) var captures = 0
        private(set) var recognitions: [FieldRole] = []
        private(set) var frames: [UUID: CGImage] = [:]
        private(set) var discards = 0
        var recognitionDelay: UInt64 = 0
        /// Not cancellable: the screenshot finishes even when the turn ends meanwhile.
        var captureDelay: UInt64 = 0
        /// Deterministic hold: `capture` waits (uncancellably) until `releaseCapture()`, having
        /// set `captureStarted`. Timing-free, so a loaded test run cannot reorder it.
        var holdsCapture = false
        private let gate = NSLock()
        private var started = false, released = false
        var captureStarted: Bool { gate.lock(); defer { gate.unlock() }; return started }
        func releaseCapture() { gate.lock(); released = true; gate.unlock() }
        init(access: ScreenRecordingAccess, lines: [ScreenTextLine] = []) { self.access = access; self.lines = lines }

        func capture(_ rect: CGRect, display: CGDirectDisplayID) async throws -> CapturedRegion {
            guard access.preflight() else { throw ScreenTextError.permissionDenied }
            if captureDelay > 0 { try? await Task.sleep(nanoseconds: captureDelay) }
            if holdsCapture {
                gate.withLock { started = true }
                while !({ gate.lock(); defer { gate.unlock() }; return released }()) {
                    await Task.yield()
                    usleep(1_000)
                }
            }
            captures += 1
            let m = ScreenPixelMapping(pointRect: rect, scale: 2)
            let frame = CapturedRegion(image: ScreenTextServiceTests.image(m.pixelSize), mapping: m, windowID: 7)
            frames[frame.id] = frame.image
            return frame
        }
        func recognize(_ frame: CapturedRegion, role: FieldRole) async throws -> [ScreenTextLine] {
            recognitions.append(role)
            if recognitionDelay > 0 { try await Task.sleep(nanoseconds: recognitionDelay) }
            return lines
        }
        func image(for id: UUID) -> CGImage? { frames[id] }
        func discardFrames() { discards += 1; frames.removeAll() }
        func discardFrame(_ id: UUID) { frames[id] = nil }
    }

    static let docsCanvas = ElementReference(id: "canvas", role: "AXGroup", label: "Document", frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                                             displayID: 1, pid: 0)
    static let mailBody = ElementReference(id: "body", role: "AXTextArea", label: "Message body", frame: CGRect(x: 100, y: 100, width: 600, height: 400),
                                           displayID: 1, pid: 0)
    static let boxRect = CGRect(x: 120, y: 300, width: 320, height: 90)

    static func drawn(_ rect: CGRect = boxRect) -> DrawnRegion {
        DrawnRegion(anchor: GlobalPoint(x: rect.minX, y: rect.maxY, displayID: 1), corner: GlobalPoint(x: rect.maxX, y: rect.minY, displayID: 1),
                    rect: rect, displayID: 1, displayRect: rect, began: 1, ended: 1.4, isComplete: true)
    }

    static func service(elements: [ElementReference], axText: String?, screen: Screen?,
                        settings: SettingsStore = InMemorySettingsStore()) -> (DeixisService, MockAXRegionTextReader) {
        let service = DeixisService(hitTester: MockAXHitTester(elements: elements), settings: settings)
        let ax = MockAXRegionTextReader(texts: axText.map { [(rect: boxRect, text: $0)] } ?? [])
        service.regionText = ax
        service.screen = screen
        service.bundleIDForPID = { _ in nil }
        service.beginCapture(at: 0)
        return (service, ax)
    }

    /// Poll (bounded) for a timer-driven change, so a loaded parallel run does not flake.
    static func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
    }

    @Test func axTextPresentMeansNoOCR() async {
        let screen = Screen(access: Access(granted: true), lines: [ScreenTextLine(text: "never read", box: Self.boxRect, confidence: 1)])
        let (service, ax) = Self.service(elements: [Self.mailBody], axText: "Send the deck by Friday", screen: screen)
        await service.regionDrawn(Self.drawn()).value
        let r = service.currentRegions
        #expect(r.count == 1)
        #expect(r[0].element?.id == "body" && r[0].text == "Send the deck by Friday" && r[0].source == DeixisRegionSource.ax)
        #expect(screen.recognitions.isEmpty)                    // no OCR call
        #expect(screen.captures == 1 && r[0].imageID != nil)     // the crop is still taken for the chip
        #expect(service.image(for: r[0]) != nil)
        #expect(!r[0].isPending && !r[0].screenTextUnavailable && ax.calls == [Self.boxRect])
    }

    @Test func noAXTextFallsBackToOCR() async {
        let ocr = [ScreenTextLine(text: "Q3 revenue", box: CGRect(x: 130, y: 360, width: 100, height: 20), confidence: 0.9),
                   ScreenTextLine(text: "up 12%", box: CGRect(x: 130, y: 320, width: 80, height: 20), confidence: 0.8)]
        let screen = Screen(access: Access(granted: true), lines: ocr)
        let (service, _) = Self.service(elements: [Self.docsCanvas], axText: nil, screen: screen)
        await service.regionDrawn(Self.drawn()).value
        let r = service.currentRegions[0]
        #expect(screen.recognitions == [.multilineText])        // AXGroup → prose: language correction on
        #expect(r.source == .ocr && r.text == "Q3 revenue\nup 12%" && r.lines == ocr)
        #expect(r.element?.id == "canvas" && r.imageID != nil)
        #expect(service.regionContextLines == [#"region 1 = AXGroup "Document" text: "Q3 revenue up 12%""#])
    }

    @Test func regionClearedAtTurnEnd() async {
        let screen = Screen(access: Access(granted: true))
        let (service, _) = Self.service(elements: [Self.mailBody], axText: "hello", screen: screen)
        var published: [[DeixisRegion]] = []
        service.onRegionsChanged = { published.append($0) }
        await service.regionDrawn(Self.drawn()).value
        #expect(service.currentRegions.count == 1 && screen.frames.count == 1)
        service.endTurn()
        #expect(service.currentRegions.isEmpty && screen.frames.isEmpty && published.last == [])

        // The next turn's key-down clears too; a latch re-arm (same turn) keeps the boxes.
        await service.regionDrawn(Self.drawn()).value
        service.beginCapture(newTurn: false)
        #expect(service.currentRegions.count == 1)
        service.beginCapture()
        #expect(service.currentRegions.isEmpty)

        // Cancel drops them as well.
        await service.regionDrawn(Self.drawn()).value
        service.cancelTurn()
        #expect(service.currentRegions.isEmpty)
    }

    @Test func retentionLimitClearsAForgottenTurn() async throws {
        let screen = Screen(access: Access(granted: true))
        let (service, _) = Self.service(elements: [], axText: "x", screen: screen)
        service.regionRetention = 0.05
        await service.regionDrawn(Self.drawn()).value
        service.endCapture()
        // `endTurn()` empties the regions under its lock and drops the crops just after, off this
        // thread — wait for the whole turn end, not its first half.
        try await Self.waitUntil { service.currentRegions.isEmpty && screen.frames.isEmpty }
        #expect(service.currentRegions.isEmpty && screen.frames.isEmpty)
    }

    @Test func holdModeLandingEndsTheTurnAfterTheGrace() async throws {
        let screen = Screen(access: Access(granted: true))
        let (service, _) = Self.service(elements: [Self.mailBody], axText: "Send the deck", screen: screen)
        service.landedRetention = 0.05
        await service.regionDrawn(Self.drawn()).value
        let spans = [TranscriptSpan(text: "reply to this", confidence: 0.9, audioRange: 0.0...0.3)]
        let landed = service.augment(spans, StageContext())
        #expect(landed.extra[DeixisService.contextLineKey]?.hasPrefix("region 1 = ") == true)
        #expect(service.currentRegions.count == 1 && screen.frames.count == 1)   // still there for the fade/chip
        try await Self.waitUntil { service.currentRegions.isEmpty && screen.frames.isEmpty }
        #expect(service.currentRegions.isEmpty && screen.frames.isEmpty)        // turn over: box and crop gone

        // A new key-down inside the grace starts a new turn; its box is not cleared by the old timer.
        service.landedRetention = 0.1
        await service.regionDrawn(Self.drawn()).value
        _ = service.augment(spans, StageContext())
        service.beginCapture()
        await service.regionDrawn(Self.drawn(CGRect(x: 500, y: 500, width: 50, height: 50))).value
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(service.currentRegions.count == 1 && service.currentRegions[0].rect.minX == 500)
    }

    @Test func firstBoxWithoutPermissionExplainsAsksOnceThenAXOnly() async {
        let access = Access(granted: false)
        let settings = InMemorySettingsStore()
        let screen = Screen(access: access)
        let (service, _) = Self.service(elements: [Self.mailBody], axText: nil, screen: screen, settings: settings)
        var notices: [String] = []
        service.onNotice = { notices.append($0) }
        var shownBeforeTheSystemAsked: [String] = []
        access.onRequest = { shownBeforeTheSystemAsked = notices }

        await service.regionDrawn(Self.drawn()).value
        #expect(access.requests == 1 && DeixisSettings.screenRecordingRequested(settings))
        #expect(notices == [OptionalPermission.screenRecording.rationale])
        #expect(shownBeforeTheSystemAsked == notices)             // the explanation comes first
        var r = service.currentRegions[0]
        #expect(r.screenTextUnavailable && r.source == .ax && r.imageID == nil && r.text.isEmpty)
        #expect(screen.captures == 0 && screen.recognitions.isEmpty)

        // Next turn, still denied: never asked again, the pill says screen text isn't available.
        service.beginCapture()
        await service.regionDrawn(Self.drawn()).value
        #expect(access.requests == 1)
        #expect(notices.last == "Screen text isn't available")
        r = service.currentRegions[0]
        #expect(r.screenTextUnavailable && r.imageID == nil)

        // A relaunch that already asked goes straight to AX only.
        let (again, _) = Self.service(elements: [Self.mailBody], axText: "AX still works", screen: Screen(access: access), settings: settings)
        var againNotices: [String] = []
        again.onNotice = { againNotices.append($0) }
        await again.regionDrawn(Self.drawn()).value
        #expect(access.requests == 1 && againNotices == ["Screen text isn't available"])
        #expect(again.currentRegions[0].text == "AX still works" && again.currentRegions[0].source == .ax)
    }

    @Test func noticeShownOncePerTurn() async {
        let (service, _) = Self.service(elements: [], axText: nil, screen: Screen(access: Access(granted: false)),
                                        settings: { let s = InMemorySettingsStore(); DeixisSettings.noteScreenRecordingRequested(store: s); return s }())
        var notices: [String] = []
        service.onNotice = { notices.append($0) }
        await service.regionDrawn(Self.drawn()).value
        await service.regionDrawn(Self.drawn(CGRect(x: 500, y: 500, width: 50, height: 50))).value
        #expect(notices == ["Screen text isn't available"] && service.currentRegions.count == 2)
    }

    @Test func augmentAddsRegionLinesOnceAcrossLatchedSegments() async {
        let screen = Screen(access: Access(granted: true))
        let (service, _) = Self.service(elements: [Self.mailBody], axText: "Send the deck", screen: screen)
        service.isLatched = { true }
        await service.regionDrawn(Self.drawn()).value
        let spans = [TranscriptSpan(text: "reply", confidence: 0.9, audioRange: 0.0...0.3)]
        let first = service.augment(spans, StageContext())
        #expect(first.extra[DeixisService.contextLineKey] == #"region 1 = AXTextArea "Message body" text: "Send the deck""#)
        #expect(service.actContextLines.contains(#"region 1 = AXTextArea "Message body" text: "Send the deck""#))
        #expect(service.currentRegions.count == 1 && screen.frames.count == 1)   // kept for the chip during dwell
        // The next latched segment is its own turn: it does not repeat the box, and the box and
        // its crop go.
        let second = service.augment(spans, StageContext())
        #expect(second.extra[DeixisService.contextLineKey] == nil)
        #expect(service.currentRegions.isEmpty && screen.frames.isEmpty)
        // Two boxes drawn for a later segment are numbered from 1 again.
        await service.regionDrawn(Self.drawn(CGRect(x: 150, y: 150, width: 60, height: 40))).value
        await service.regionDrawn(Self.drawn(CGRect(x: 300, y: 150, width: 60, height: 40))).value
        let third = service.augment(spans, StageContext())
        let line = third.extra[DeixisService.contextLineKey] ?? ""
        #expect(line.hasPrefix("region 1 = ") && line.contains("; region 2 = "))
    }

    @Test func boxClearedWhileItsScreenshotIsTakenDropsTheFrame() async {
        let screen = Screen(access: Access(granted: true))
        screen.holdsCapture = true
        let (service, _) = Self.service(elements: [Self.mailBody], axText: nil, screen: screen)
        let analysis = service.regionDrawn(Self.drawn())
        while !screen.captureStarted { await Task.yield(); usleep(1_000) }
        service.endTurn()                                        // the turn ends mid-capture
        screen.releaseCapture()
        await analysis.value
        #expect(service.currentRegions.isEmpty && screen.frames.isEmpty && screen.recognitions.isEmpty)
    }

    @Test func augmentWaitsBrieflyForABoxStillBeingRead() async {
        let screen = Screen(access: Access(granted: true), lines: [ScreenTextLine(text: "Q3 plan", box: Self.boxRect, confidence: 0.9)])
        screen.recognitionDelay = 150_000_000
        let (service, _) = Self.service(elements: [Self.docsCanvas], axText: nil, screen: screen)
        service.settleTimeout = 2
        let analysis = service.regionDrawn(Self.drawn())
        #expect(service.currentRegions.first?.isPending == true)
        let ctx = service.augment([TranscriptSpan(text: "summarise", confidence: 0.9, audioRange: 0...0.4)], StageContext())
        #expect(ctx.extra[DeixisService.contextLineKey] == #"region 1 = AXGroup "Document" text: "Q3 plan""#)
        await analysis.value
    }

    @Test func codeElementTurnsOCRCorrectionOff() async {
        let editor = ElementReference(id: "ed", role: "AXTextArea", label: "Monaco editor content", frame: CGRect(x: 0, y: 0, width: 900, height: 900),
                                      displayID: 1, pid: 0)
        let screen = Screen(access: Access(granted: true))
        let (service, _) = Self.service(elements: [editor], axText: nil, screen: screen)
        await service.regionDrawn(Self.drawn()).value
        #expect(screen.recognitions == [.codeEditor])
    }

    @Test func recorderGateReadsTheKeyTheLatchAndTheSetting() {
        let settings = InMemorySettingsStore()
        let service = DeixisService(hitTester: MockAXHitTester(elements: []), settings: settings)
        final class State: @unchecked Sendable { var key = false, latched = false }
        let state = State()
        service.isDictationKeyDown = { state.key }
        service.isLatched = { state.latched }
        let gate = service.regionGate
        #expect(!gate.isOpen)
        state.key = true
        #expect(gate.isOpen)
        state.key = false; state.latched = true
        #expect(!gate.isOpen)                                 // latch, bare drag: nothing
        DeixisSettings.setDrawsWithoutKey(true, store: settings)
        #expect(gate.isOpen)                                  // latch + "draw without a key"
        state.latched = false
        #expect(!gate.isOpen)                                 // the setting is latch-only
        #expect(DeixisSettings.drawsWithoutKey(InMemorySettingsStore()) == false)   // default off
    }
}
