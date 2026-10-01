import Actions
import Combine
import Foundation
import Injection
import Testing
@testable import VoicePlusApp

/// S4 — the mouth-to-caret tape flight (design §4 "Mouth-to-caret tape path", §5 step 6): anchor maths
/// across displays and scale factors, the suppression matrix, and the flight taken down on any state
/// change. The ribbon's own maths is S1's `SpoolFlight`, checked here through the flight's path against
/// the prototype's eight `flights` hashes. Nothing here touches Accessibility, a window or a display.
@Suite("Tape flight (S4)")
struct TapeFlightTests {

    // MARK: Fakes

    final class FakeProbe: TapeFlightProbing, @unchecked Sendable {
        var value: TapeFlightProbe
        private(set) var reads = 0
        init(_ value: TapeFlightProbe) { self.value = value }
        func probe() -> TapeFlightProbe {
            reads += 1
            return value
        }
    }

    final class FakeCaret: TapeFlightCaretReading, @unchecked Sendable {
        var rect: CGRect?
        /// The landed text's bounds (the destination tape cue's line), AX coordinates.
        var textRect: CGRect?
        var textLines: [CGRect]?
        var rtl = false
        private(set) var asked: [Int] = []
        private(set) var askedRanges: [Range<Int>] = []
        init(_ rect: CGRect?) { self.rect = rect }
        func caretRect(at index: Int) -> CGRect? {
            asked.append(index)
            return rect
        }
        func rangeRect(_ range: Range<Int>) -> CGRect? {
            askedRanges.append(range)
            return textRect
        }
        func lineMeasurements(_ range: Range<Int>) -> [TapeFlightLineMeasurement] {
            lineRects(range).map { TapeFlightLineMeasurement(rect: $0, rightToLeft: rtl) }
        }
        func lineRects(_ range: Range<Int>) -> [CGRect] {
            askedRanges.append(range)
            return textLines ?? textRect.map { [$0] } ?? []
        }
    }

    final class FakeSurface: TapeFlightSurface {
        private(set) var shown: [TapeFlightRun] = []
        private(set) var clears = 0
        private(set) var current: TapeFlightRun?
        private(set) var cues: [TapeFieldCue] = []
        private(set) var cueClears = 0
        private(set) var currentCue: TapeFieldCue?
        func show(_ run: TapeFlightRun) {
            shown.append(run)
            current = run
        }
        func clear() {
            clears += 1
            current = nil
        }
        func showCue(_ cue: TapeFieldCue) {
            cues.append(cue)
            currentCue = cue
        }
        func clearCue() {
            cueClears += 1
            currentCue = nil
        }
    }

    /// A read queue the test drains by hand, to hold a read "in flight".
    final class ManualQueue {
        private var pending: [() -> Void] = []
        var isEmpty: Bool { pending.isEmpty }
        func enqueue(_ work: @escaping () -> Void) { pending.append(work) }
        func drain() {
            while !pending.isEmpty { pending.removeFirst()() }
        }
    }

    final class Clock: TurnClock, @unchecked Sendable {
        private struct Item {
            let due: Date
            let timer: TurnTimer
            let work: () -> Void
        }
        private(set) var now = Date(timeIntervalSinceReferenceDate: 1000)
        private var items: [Item] = []

        func schedule(after seconds: TimeInterval, _ work: @escaping () -> Void) -> TurnTimer {
            let timer = TurnTimer()
            items.append(Item(due: now.addingTimeInterval(max(0, seconds)), timer: timer, work: work))
            return timer
        }

        func advance(_ seconds: TimeInterval) {
            let target = now.addingTimeInterval(seconds)
            while let next = items.filter({ $0.due <= target }).min(by: { $0.due < $1.due }) {
                items.removeAll { $0.timer === next.timer }
                now = next.due
                if !next.timer.isCancelled { next.work() }
            }
            now = target
        }
    }

    final class Config {
        var mouth: CGPoint?
        var displays: [DisplayFrame]
        var reduced = false
        /// Destination uncertainty mark strips on screen (AppKit screen coordinates).
        var strips: [CGRect] = []
        init(mouth: CGPoint?, displays: [DisplayFrame]) {
            self.mouth = mouth
            self.displays = displays
        }
    }

    // A 1512 × 982 built-in display at the origin, and a 1× external to its right.
    static let builtIn = DisplayFrame(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2)
    static let external = DisplayFrame(id: 2, frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080), scale: 1)
    static let textEdit = FocusSnapshot(pid: 42, bundleID: "com.apple.TextEdit", appName: "TextEdit", elementToken: "777")
    /// Spool's mouth on the built-in display (AppKit), and the caret at (300, 400)…(300, 418) there,
    /// as AX reports it (y down from the top of the primary display: 982 − 418 = 564).
    static let mouth = CGPoint(x: 700, y: 850)
    static let caretAX = CGRect(x: 300, y: 564, width: 0, height: 18)
    static let caretOnExternalAX = CGRect(x: 1900, y: 500, width: 0, height: 18)
    static let caret = TapeFlightProbe(focus: textEdit, selection: 5 ..< 5)
    static let text = "See you at noon."

    struct Harness {
        let probe: FakeProbe
        let caret: FakeCaret
        let surface = FakeSurface()
        let clock = Clock()
        let config: Config
        let queue: ManualQueue?
        let controller: TapeFlightController

        init(probe: TapeFlightProbe = TapeFlightTests.caret, caretAX: CGRect? = TapeFlightTests.caretAX,
             mouth: CGPoint? = TapeFlightTests.mouth,
             displays: [DisplayFrame] = [TapeFlightTests.builtIn, TapeFlightTests.external], manualQueue: Bool = false) {
            self.probe = FakeProbe(probe)
            caret = FakeCaret(caretAX)
            config = Config(mouth: mouth, displays: displays)
            let queue = manualQueue ? ManualQueue() : nil
            self.queue = queue
            let config = self.config
            let queues = TapeFlightQueues(read: { work in if let queue { queue.enqueue(work) } else { work() } },
                                          deliver: { $0() })
            controller = TapeFlightController(reader: TapeFlightReader(probe: self.probe, caret: caret),
                                              mouth: { config.mouth }, displays: { config.displays },
                                              reduceMotion: { config.reduced }, surface: surface, clock: clock,
                                              queues: queues, markStrips: { config.strips })
        }

        func preview() {
            controller.stateChanged(.finalPreview(FinalPreviewInfo(text: TapeFlightTests.text, dwellRemaining: 0.9)))
        }

        func insert() {
            controller.stateChanged(.inserting(text: TapeFlightTests.text))
        }
    }

    // MARK: Anchor maths across displays and scale factors

    /// The pill's SwiftUI anchor (window space, top-left origin) to the screen, then to the overlay of the
    /// display it is on, for a pill on the built-in display and on a 1× display left of it at a negative
    /// origin; a scene drawn at 1×, 0.75× and 0.5× of its viewBox maps the mouth with the scene.
    @Test func mouthAnchorMapsFromTheWindowToTheDisplaysOverlay() {
        let ready = SpoolScene.frame(.ready, t: 1.4, drive: .capture(level: 0))
        #expect(ready.mouth == SpoolPoint(488, 100.8))
        let left = DisplayFrame(id: 3, frame: CGRect(x: -1920, y: 200, width: 1920, height: 1080), scale: 1)
        let displays = [Self.builtIn, left]
        struct Case { var display: DisplayFrame; var panel: CGRect; var sceneSize: CGSize }
        let cases = [
            Case(display: Self.builtIn, panel: CGRect(x: 476, y: 982 - 32 - 160, width: 560, height: 160),
                 sceneSize: CGSize(width: 560, height: 160)),
            Case(display: left, panel: CGRect(x: -1920 + 680, y: 1280 - 24 - 160, width: 560, height: 160),
                 sceneSize: CGSize(width: 560, height: 160)),
            Case(display: left, panel: CGRect(x: -1500, y: 900, width: 420, height: 120),
                 sceneSize: CGSize(width: 420, height: 120)),
            Case(display: Self.builtIn, panel: CGRect(x: 200, y: 600, width: 280, height: 80),
                 sceneSize: CGSize(width: 280, height: 80)),
        ]
        for c in cases {
            let anchors = SpoolAnchors(frame: ready, size: c.sceneSize, origin: .zero)
            let scale = c.sceneSize.height / 160
            #expect(abs(anchors.mouthAnchor.x - 488 * scale) < 1e-9 && abs(anchors.mouthAnchor.y - 100.8 * scale) < 1e-9)
            let content = CGRect(origin: .zero, size: c.panel.size)
            let screen = SpoolScreenGeometry.screenPoint(anchors.mouthAnchor, windowFrame: c.panel, contentFrame: content)
            #expect(screen == CGPoint(x: c.panel.minX + anchors.mouthAnchor.x, y: c.panel.maxY - anchors.mouthAnchor.y))
            #expect(TapeFlightGeometry.display(containing: screen, in: displays) == c.display)
            let local = TapeFlightGeometry.local(screen, in: c.display)
            #expect(local == CGPoint(x: screen.x - c.display.frame.minX, y: c.display.frame.maxY - screen.y))
        }
        // A content view inset in its window (a titled window) shifts the point by the inset.
        let inset = SpoolScreenGeometry.screenPoint(CGPoint(x: 10, y: 20), windowFrame: CGRect(x: 100, y: 100, width: 300, height: 228),
                                                    contentFrame: CGRect(x: 0, y: 0, width: 300, height: 200))
        #expect(inset == CGPoint(x: 110, y: 280))
    }

    /// AX's caret rect (Quartz global, y down from the primary's top) reaches the right display and the
    /// right overlay point for a display to the right, above (negative AX y) and left of the primary —
    /// and the backing scale never changes a point: AppKit, AX and the overlay all measure in points.
    @Test func caretRectMapsAcrossDisplaysAndScaleFactors() throws {
        for scale in [1.0, 2.0, 3.0] as [CGFloat] {
            let primary = DisplayFrame(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: scale)
            let above = DisplayFrame(id: 2, frame: CGRect(x: -200, y: 982, width: 2560, height: 1440), scale: 3 - scale + 1)
            let left = DisplayFrame(id: 3, frame: CGRect(x: -1920, y: -300, width: 1920, height: 1080), scale: scale)
            let displays = [above, primary, left]
            #expect(TapeFlightGeometry.primary(displays) == primary)

            // On the primary: AX y 564 → AppKit 400…418, centre 409 → overlay y 982 − 409.
            let onPrimary = try #require(try? TapeFlightGeometry.path(mouth: CGPoint(x: 700, y: 850), caretAX: Self.caretAX,
                                                                      displays: displays).get())
            #expect(onPrimary.display == primary)
            #expect(onPrimary.to == CGPoint(x: 300, y: 573))
            #expect(onPrimary.from == CGPoint(x: 700, y: 132))
            #expect(onPrimary.size == CGSize(width: 1512, height: 982))

            // Above the primary: AX y is negative. AppKit y = 982 − (−500 + 20) = 1462 … 1482.
            let aboveCaret = CGRect(x: 100, y: -500, width: 0, height: 20)
            let mouthAbove = CGPoint(x: 900, y: 2300)
            let onAbove = try #require(try? TapeFlightGeometry.path(mouth: mouthAbove, caretAX: aboveCaret, displays: displays).get())
            #expect(onAbove.display == above)
            #expect(onAbove.to == CGPoint(x: 300, y: 2422 - 1472))
            #expect(onAbove.from == CGPoint(x: 1100, y: 2422 - 2300))

            // Left of and lower than the primary: negative AppKit x and y.
            let leftCaret = CGRect(x: -1000, y: 1000, width: 0, height: 16)   // AppKit y −34 … −18
            let onLeft = try #require(try? TapeFlightGeometry.path(mouth: CGPoint(x: -600, y: 500), caretAX: leftCaret,
                                                                   displays: displays).get())
            #expect(onLeft.display == left)
            #expect(onLeft.to == CGPoint(x: 920, y: 780 - -26))
            #expect(onLeft.from == CGPoint(x: 1320, y: 280))
        }
    }

    /// The flight's path feeds `SpoolFlight` exactly as the prototype's `flight(t, from, to, w, h)`: a
    /// 900 × 600 display left of the primary, mouth and caret placed so the overlay points are the golden
    /// file's (480, 111) → (140, 420), reproduces the eight `flights` hashes at 1× and 2×.
    @Test func flightPathMatchesThePrototypesGoldenFlights() throws {
        let golden = SpoolParityTests.golden.flights
        #expect(golden.count == 8)
        for scale in [1.0, 2.0] as [CGFloat] {
            let primary = DisplayFrame(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), scale: 2)
            let side = DisplayFrame(id: 9, frame: CGRect(x: -900, y: 300, width: 900, height: 600), scale: scale)
            let mouth = CGPoint(x: -900 + 480, y: 900 - 111)
            // Caret centre at AppKit (−760, 480): rect 470…490, AX y = 900 − 490.
            let caretAX = CGRect(x: -760, y: 410, width: 0, height: 20)
            var path = try #require(try? TapeFlightGeometry.path(mouth: mouth, caretAX: caretAX, displays: [primary, side]).get())
            path.lines = golden.first?.lines ?? []
            path.verified = false
            #expect(path.from == CGPoint(x: 480, y: 111) && path.to == CGPoint(x: 140, y: 420))
            // At the reference date `start + t − start` is `t` to the bit, as the golden times need.
            let start = Date(timeIntervalSinceReferenceDate: 0)
            let run = TapeFlightRun(start: start, text: Self.text, path: path, mouth: { mouth })
            for entry in golden {
                #expect(entry.from == [480, 111] && entry.to == [140, 420] && entry.w == 900 && entry.h == 600)
                let svg = SpoolSVG.string(path.frame(t: entry.t))
                #expect(SpoolParityTests.sha256(svg) == entry.sha256, "flight t=\(entry.t) at \(scale)×")
                let drawn = SpoolSVG.string(run.frame(at: start.addingTimeInterval(entry.t)))
                #expect(SpoolParityTests.sha256(drawn) == entry.sha256, "run t=\(entry.t) at \(scale)×")
            }
            #expect(run.frame(at: start) == nil)
            #expect(run.frame(at: run.end) == nil)
        }
    }

    /// A pill that moves mid-flight is followed: the run reads the mouth every frame; a mouth that has
    /// left the path's display keeps the planned source rather than jumping across displays.
    @Test func runFollowsTheMouthOnItsDisplay() throws {
        let path = TapeFlightPath(display: Self.builtIn, from: CGPoint(x: 700, y: 132), to: CGPoint(x: 300, y: 573))
        var mouth: CGPoint? = CGPoint(x: 720, y: 840)
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let run = TapeFlightRun(start: start, text: Self.text, path: path, mouth: { mouth })
        let moved = try #require(run.frame(at: start.addingTimeInterval(0.9)))
        let expected = try #require(path.frame(t: 0.9, mouth: CGPoint(x: 720, y: 142)))
        #expect(moved == expected)
        mouth = CGPoint(x: 2000, y: 500)   // on the external display
        #expect(run.frame(at: start.addingTimeInterval(0.9)) == path.frame(t: 0.9))
        mouth = nil
        #expect(run.frame(at: start.addingTimeInterval(0.9)) == path.frame(t: 0.9))
    }

    // MARK: The caret rect at the insertion point

    @Test func caretLocatorUsesMeasuredRectsOnly() {
        let char = CGRect(x: 100, y: 50, width: 7, height: 16)
        // The character after the caret: its left edge.
        #expect(TapeFlightCaretLocator.locate(at: 4) { $0 == 4 ..< 5 ? char : nil } == CGRect(x: 100, y: 50, width: 0, height: 16))
        // End of the text: the empty range's own caret rect (zero width is fine) …
        let caretRect = CGRect(x: 180, y: 50, width: 0, height: 16)
        #expect(TapeFlightCaretLocator.locate(at: 9) { $0.isEmpty ? caretRect : char } == caretRect,
                "Measured insertion affinity takes priority over a character edge, including RTL")
        #expect(TapeFlightCaretLocator.locate(at: 9) { $0 == 9 ..< 9 ? caretRect : nil } == caretRect)
        // … else the character before: its right edge.
        #expect(TapeFlightCaretLocator.locate(at: 9) { $0 == 8 ..< 9 ? char : nil } == CGRect(x: 107, y: 50, width: 0, height: 16))
        // Nothing measurable: nothing invented.
        #expect(TapeFlightCaretLocator.locate(at: 0) { _ in nil } == nil)
        #expect(TapeFlightCaretLocator.locate(at: 0) { $0 == -1 ..< 0 ? char : nil } == nil)
        #expect(TapeFlightCaretLocator.locate(at: -1) { _ in char } == nil)
        let flat = CGRect(x: 1, y: 1, width: 0, height: 0)
        #expect(TapeFlightCaretLocator.locate(at: 3) { _ in flat } == nil)
        let broken = CGRect(x: CGFloat.nan, y: 1, width: 2, height: 10)
        #expect(TapeFlightCaretLocator.locate(at: 3) { _ in broken } == nil)
    }

    // MARK: Which destination may be aimed at

    @Test func previewSampleArmsOnlyAReadableNonSecureCaret() {
        let target = TapeFlightTarget(pid: 42, bundleID: "com.apple.TextEdit", elementToken: "777", selection: 5 ..< 5)
        #expect(TapeFlightPlanner.arm(Self.caret) == .armed(target))
        #expect(target.insertionIndex == 5)
        #expect(TapeFlightPlanner.arm(TapeFlightProbe(focus: Self.textEdit, selection: nil, isSecure: true)) == .refused(.secureField))
        // Q5 — no readable selection still arms (the caret ladder aims it); no focused element does not.
        #expect(TapeFlightPlanner.arm(TapeFlightProbe(focus: Self.textEdit, selection: nil))
                == .armed(TapeFlightTarget(pid: 42, bundleID: "com.apple.TextEdit", elementToken: "777", selection: nil)))
        #expect(TapeFlightPlanner.arm(TapeFlightProbe(focus: nil, selection: 0 ..< 0)) == .refused(.caretUnavailable))
        let replacing = TapeFlightPlanner.arm(TapeFlightProbe(focus: Self.textEdit, selection: 3 ..< 8))
        #expect(replacing == .armed(TapeFlightTarget(pid: 42, bundleID: "com.apple.TextEdit", elementToken: "777", selection: 3 ..< 8)))
    }

    @Test func verifyAcceptsTheSameCaretBeforeOrInsideOurOwnWrite() {
        let armed = TapeFlightPlanner.arm(Self.caret)
        let length = 16
        func verify(_ probe: TapeFlightProbe, _ arming: TapeFlightArming? = nil) -> TapeFlightSuppression? {
            switch TapeFlightPlanner.verify(arming ?? armed, now: probe, insertedLength: length) {
            case .success: return nil
            case .failure(let reason): return reason
            }
        }
        let other = FocusSnapshot(pid: 42, bundleID: "com.apple.TextEdit", appName: "TextEdit", elementToken: "888")
        let mail = FocusSnapshot(pid: 7, bundleID: "com.apple.mail", appName: "Mail", elementToken: "777")
        #expect(verify(Self.caret) == nil)                                                         // not written yet
        #expect(verify(TapeFlightProbe(focus: Self.textEdit, selection: 21 ..< 21)) == nil)        // right after the write
        #expect(verify(TapeFlightProbe(focus: Self.textEdit, selection: 12 ..< 12)) == nil)        // typed, mid-write
        #expect(verify(TapeFlightProbe(focus: Self.textEdit, selection: 22 ..< 22)) == .targetChanged)
        #expect(verify(TapeFlightProbe(focus: Self.textEdit, selection: 4 ..< 4)) == .targetChanged)
        #expect(verify(TapeFlightProbe(focus: Self.textEdit, selection: 5 ..< 9)) == .targetChanged)
        #expect(verify(TapeFlightProbe(focus: other, selection: 5 ..< 5)) == .targetChanged)
        #expect(verify(TapeFlightProbe(focus: mail, selection: 5 ..< 5)) == .targetChanged)
        #expect(verify(TapeFlightProbe(focus: nil, selection: 5 ..< 5)) == .targetChanged)
        #expect(verify(TapeFlightProbe(focus: Self.textEdit, selection: nil, isSecure: true)) == .secureField)
        #expect(verify(TapeFlightProbe(focus: Self.textEdit, selection: nil)) == nil)   // Q5: unreadable ≠ contradicted
        #expect(verify(Self.caret, .refused(.secureField)) == .secureField)
        #expect(TapeFlightPlanner.verify(nil, now: Self.caret, insertedLength: length) == .failure(.caretUnavailable))
        // A replaced selection: untouched, or the caret after the new text.
        let selected = TapeFlightPlanner.arm(TapeFlightProbe(focus: Self.textEdit, selection: 3 ..< 8))
        #expect(verify(TapeFlightProbe(focus: Self.textEdit, selection: 3 ..< 8), selected) == nil)
        #expect(verify(TapeFlightProbe(focus: Self.textEdit, selection: 19 ..< 19), selected) == nil)
        #expect(verify(TapeFlightProbe(focus: Self.textEdit, selection: 3 ..< 5), selected) == .targetChanged)
    }

    // MARK: The controller — flight, suppression matrix, cancellation

    @Test func previewThenInsertingFliesFromTheMouthToThePreInsertionCaret() throws {
        let h = Harness()
        h.preview()
        #expect(h.controller.phase == .armed)
        #expect(h.probe.reads == 1)
        #expect(h.caret.asked.isEmpty)   // the preview only samples; nothing is measured or drawn yet
        let startedAt = h.clock.now
        h.insert()
        let run = try #require(h.surface.current)
        #expect(h.surface.shown.count == 1)
        #expect(run.start == startedAt)
        #expect(run.text == Self.text)
        #expect(run.path.display == Self.builtIn)
        #expect(run.path.from == CGPoint(x: 700, y: 132))
        #expect(run.path.to == CGPoint(x: 300, y: 573))
        #expect(h.caret.asked == [5])   // the insertion point the preview saw
        #expect(h.controller.phase == .flying(run.path))
        #expect(h.controller.suppressions.isEmpty)
        // The ribbon runs its full course and is taken down when the tail has fed in (1.05 s).
        h.clock.advance(1.0)
        #expect(h.surface.current === run)
        h.clock.advance(SpoolFlight.duration - 1.0 + 0.01)
        #expect(h.surface.current == nil)
        #expect(h.surface.clears == 1)
        #expect(h.controller.phase == .finished)
        // A re-published `.inserting` or the landed outcome starts nothing new.
        h.insert()
        h.controller.stateChanged(.landed(LandedPillInfo(text: Self.text, verified: true)))
        #expect(h.surface.shown.count == 1)
    }

    // MARK: V4.41 — the manual "Insert now" path animates like the automatic one

    /// A preview held for review (manual review, a hover pause, or simply a few seconds before
    /// "Insert now") used to insert against the sample taken when the preview opened. Electron and
    /// Chromium move the caret and re-create the focused element freely, so `verify` answered
    /// `.targetChanged` and the landing ribbon was suppressed — the one insertion the user asked for
    /// explicitly was the one that never animated. The sample is kept fresh while the preview is up.
    @Test func aHeldPreviewReArmsSoTheManualInsertStillFlies() throws {
        let h = Harness()
        h.preview()
        #expect(h.controller.phase == .armed)
        #expect(h.probe.reads == 1)
        // The user reads the preview; meanwhile the destination's caret and element move on.
        h.config.mouth = Self.mouth
        h.probe.value = TapeFlightProbe(focus: FocusSnapshot(pid: 42, bundleID: "com.apple.TextEdit",
                                                             appName: "TextEdit", elementToken: "888"),
                                        selection: 11 ..< 11)
        h.clock.advance(3)
        #expect(h.probe.reads > 1, "the pre-insertion sample is taken again while the preview is up")
        // "Insert now": the flight aims at the caret that is really there.
        h.insert()
        let run = try #require(h.surface.current)
        #expect(h.controller.phase == .flying(run.path))
        #expect(h.controller.suppressions.isEmpty)
        #expect(h.caret.asked.last == 11)
    }

    /// Nothing re-arms once the write is on its way: the sample must be pre-insertion.
    @Test func reArmingStopsWhenTheWriteBegins() {
        let h = Harness()
        h.preview()
        h.insert()
        // Past the ribbon's own course, so the flight's refresh reads have stopped too.
        h.clock.advance(SpoolFlight.duration + 0.05)
        #expect(h.controller.phase == .finished)
        let readsWhenFinished = h.probe.reads
        h.clock.advance(5)
        #expect(h.probe.reads == readsWhenFinished, "no sample is taken after the write was dispatched")
    }

    /// The suppression matrix: every condition draws no ribbon, reads nothing it must not, and leaves
    /// the pill alone (the controller has no way to reach the turn or the pill).
    @Test func suppressionMatrix() {
        struct Row {
            var name: String
            var expected: TapeFlightSuppression
            var setUp: (Harness) -> Void
        }
        let changedElement = TapeFlightProbe(focus: FocusSnapshot(pid: 42, bundleID: "com.apple.TextEdit", elementToken: "900"),
                                             selection: 5 ..< 5)
        let rows: [Row] = [
            Row(name: "caret rect unavailable", expected: .caretUnavailable) { $0.caret.rect = nil },
            Row(name: "caret rect off every display", expected: .caretUnavailable) {
                $0.caret.rect = CGRect(x: 9000, y: 9000, width: 0, height: 18)
            },
            Row(name: "target changed", expected: .targetChanged) { h in
                h.preview()
                h.probe.value = changedElement
            },
            Row(name: "caret moved elsewhere", expected: .targetChanged) { h in
                h.preview()
                h.probe.value = TapeFlightProbe(focus: TapeFlightTests.textEdit, selection: 40 ..< 40)
            },
            Row(name: "secure field at the preview", expected: .secureField) {
                $0.probe.value = TapeFlightProbe(focus: TapeFlightTests.textEdit, selection: nil, isSecure: true)
            },
            Row(name: "field became secure", expected: .secureField) { h in
                h.preview()
                h.probe.value = TapeFlightProbe(focus: TapeFlightTests.textEdit, selection: nil, isSecure: true)
            },
            Row(name: "other display", expected: .otherDisplay) { $0.caret.rect = TapeFlightTests.caretOnExternalAX },
            Row(name: "mouth not on screen", expected: .mouthUnavailable) { $0.config.mouth = nil },
            Row(name: "reduce motion", expected: .reduceMotion) { $0.config.reduced = true },
        ]
        for row in rows {
            let h = Harness()
            let model = PillViewModel()
            h.controller.follow(model.$state.eraseToAnyPublisher())
            row.setUp(h)
            model.present(.finalPreview(FinalPreviewInfo(text: Self.text, dwellRemaining: 0.9)))
            model.present(.inserting(text: Self.text))
            #expect(h.controller.phase == .suppressed(row.expected), "\(row.name)")
            #expect(h.controller.suppressions.last == row.expected, "\(row.name)")
            #expect(h.surface.shown.isEmpty, "\(row.name)")
            #expect(model.state == .inserting(text: Self.text), "\(row.name): the pill keeps its label")
            if row.expected == .reduceMotion {
                #expect(h.probe.reads > 0 && !h.caret.asked.isEmpty, "reduce motion still verifies a static destination cue")
            }
            if row.expected == .secureField {
                #expect(h.caret.asked.isEmpty, "a password field is never measured")
            }
            // The outcome shows as it would anyway; nothing is left behind.
            model.present(.landed(LandedPillInfo(text: Self.text, verified: true)))
            #expect(h.surface.shown.isEmpty && h.surface.current == nil, "\(row.name)")
        }
        // No final preview before the insertion: the pre-insertion caret was never seen.
        let unseen = Harness()
        unseen.insert()
        #expect(unseen.controller.phase == .suppressed(.caretUnavailable))
        #expect(unseen.surface.shown.isEmpty && unseen.caret.asked.isEmpty)
    }

    /// Any state other than the insertion and its own landed outcome takes the ribbon down at once.
    @Test func flightIsTakenDownOnStateChange() {
        let interruptions: [PillState] = [
            .held(HeldPillInfo(text: Self.text, destination: "TextEdit", reason: "focus moved")),
            .cancelled, .hidden, .idle, .starting, .listening(level: 0.3), .error(message: "Couldn’t insert"),
            .landedPartial(text: Self.text), .undoAvailable,
            .finalPreview(FinalPreviewInfo(text: "Next one.", dwellRemaining: 0.9)),
        ]
        for state in interruptions {
            let h = Harness()
            h.preview()
            h.insert()
            #expect(h.surface.current != nil, "\(state.caseName)")
            h.clock.advance(0.2)
            h.controller.stateChanged(state)
            #expect(h.surface.current == nil, "\(state.caseName): cleared immediately")
            #expect(h.surface.clears == 1, "\(state.caseName)")
            #expect(h.controller.run == nil, "\(state.caseName)")
            // Timers of the old flight never fire into the next state.
            h.clock.advance(2)
            #expect(h.surface.clears == 1 && h.surface.shown.count == 1, "\(state.caseName)")
        }
        // Q5 — an unconfirmed outcome no longer takes the ribbon down: it is independent of verification.
        let h = Harness()
        h.preview()
        h.insert()
        h.clock.advance(0.1)
        h.controller.stateChanged(.landed(LandedPillInfo(text: Self.text, verified: false)))
        #expect(h.surface.current != nil)
        if case .flying = h.controller.phase {} else { Issue.record("still flying after an unconfirmed landing") }
        h.clock.advance(0.1)
        h.controller.stateChanged(.idle)
        #expect(h.surface.current == nil && h.controller.phase == .idle)
    }

    /// A read still in flight when the state changes is dropped: no ribbon appears late.
    @Test func pendingReadIsDroppedOnStateChange() {
        let h = Harness(manualQueue: true)
        h.preview()
        #expect(h.probe.reads == 0)   // nothing read on the pill's thread
        h.insert()
        #expect(h.probe.reads == 0 && h.surface.shown.isEmpty)   // the insertion is not held up by a read
        h.controller.stateChanged(.cancelled)
        h.queue?.drain()
        #expect(h.surface.shown.isEmpty)
        #expect(h.controller.phase == .idle)
        // Queue order keeps the preview's sample ahead of the insertion's verification.
        let late = Harness(manualQueue: true)
        late.preview()
        late.insert()
        #expect(late.surface.shown.isEmpty)
        late.queue?.drain()
        #expect(late.surface.shown.count == 1)
    }

    /// While flying the caret is re-measured: a reflow moves the endpoint; a changed target, a scroll out
    /// of trustworthy geometry or a move to another display takes the ribbon down.
    @Test func refreshFollowsReflowAndDropsLostGeometry() throws {
        let h = Harness()
        h.preview()
        h.insert()
        let run = try #require(h.surface.current)
        // After the write the caret sits after the text; the field reflowed 30 pt down.
        h.probe.value = TapeFlightProbe(focus: Self.textEdit, selection: 21 ..< 21)
        h.caret.rect = CGRect(x: 300, y: 594, width: 0, height: 18)
        h.clock.advance(TapeFlightController.refreshInterval)
        #expect(run.path.to == CGPoint(x: 300, y: 603))
        #expect(h.caret.asked == [5, 5])
        #expect(h.surface.current === run)

        for (name, change) in [
            ("scrolled away", { (h: Harness) in h.caret.rect = nil }),
            ("clicked elsewhere", { (h: Harness) in h.probe.value = TapeFlightProbe(focus: Self.textEdit, selection: 2 ..< 2) }),
            ("other display", { (h: Harness) in h.caret.rect = Self.caretOnExternalAX }),
        ] as [(String, (Harness) -> Void)] {
            let h = Harness()
            h.preview()
            h.insert()
            change(h)
            h.clock.advance(TapeFlightController.refreshInterval)
            #expect(h.surface.current == nil && h.surface.clears == 1, "\(name)")
            #expect(h.controller.run == nil, "\(name)")
            if case .suppressed = h.controller.phase {} else { Issue.record("\(name): \(h.controller.phase)") }
        }
    }

    /// The flight's clock is the insertion's: a caret measured late draws only what is left, and one
    /// measured after 1.05 s draws nothing.
    @Test func lateMeasurementNeverExtendsTheFlight() {
        let h = Harness(manualQueue: true)
        h.preview()
        h.insert()
        h.clock.advance(SpoolFlight.duration + 0.15)
        h.queue?.drain()
        #expect(h.surface.shown.isEmpty)
        #expect(h.controller.phase == .finished)
    }

    // MARK: Spool while the tape feeds, and the live hook

    /// While the tape flies the pill shows Spool's `inserting` pose: reels clockwise until 1.05 s.
    @Test func insertingPoseTurnsTheReelsClockwise() {
        let model = PillViewModel()
        model.present(.inserting(text: Self.text))
        #expect(model.content().spoolKey == "inserting")
        #expect(SpoolPoseTable.pose(for: .inserting) == .insert)
        var reel = SpoolReelIntegrator()
        reel.advance(.inserting, t: 0.5, dt: 0.02)
        #expect(reel.angle > 0)
        let angle = reel.angle
        reel.advance(.inserting, t: SpoolFlight.duration + 0.1, dt: 0.02)
        #expect(reel.angle == angle)
    }

    /// The anchor tracker the pill hands its `SpoolView`: nothing on screen without a window, and no
    /// flight installed on a view model that is never drawn (tests never read Accessibility).
    @Test func pillAnchorHookStaysInertWithoutAWindow() {
        let model = PillViewModel()
        let tracker = model.spoolAnchors
        #expect(tracker === model.spoolAnchors)
        tracker.update(SpoolAnchors(mouthAnchor: CGPoint(x: 482, y: 111), inletAnchor: CGPoint(x: 420, y: 102)))
        #expect(tracker.anchors?.mouthAnchor == CGPoint(x: 482, y: 111))
        #expect(tracker.window == nil)
        #expect(tracker.mouthOnScreen == nil)
        #expect(tracker.subscriber == nil)
    }

    // MARK: The destination tape cue (design §13 scenario 4, prototype `.field-line`)

    /// The landed text "See you at noon." on the caret's line: AX (300, 564) 120 × 18 → overlay
    /// (300, 564) 120 × 18 on the built-in display; the cue sits 6 pt under it, 3 pt tall.
    static let landedAX = CGRect(x: 300, y: 564, width: 120, height: 18)
    static let cueRect = CGRect(x: 300, y: 564 + 18 + 7, width: 120, height: 2.4)

    func landed(_ h: Harness, verified: Bool = true) {
        h.controller.stateChanged(.landed(LandedPillInfo(text: Self.text, verified: verified)))
    }

    @Test func cueFollowsAFlightThatFinishedOnAVerifiedLandingAndFades() throws {
        let h = Harness()
        h.caret.textRect = Self.landedAX
        h.preview()
        h.insert()
        let run = try #require(h.surface.current)
        h.clock.advance(0.05)
        landed(h)
        #expect(h.surface.cues.isEmpty, "nothing at the destination while the ribbon still flies")
        // The Undo row of the same write does not cut the flight short after a verified landing.
        h.clock.advance(0.65)
        h.controller.stateChanged(.undoAvailable)
        #expect(h.surface.current != nil)
        h.clock.advance(run.end.timeIntervalSince(h.clock.now) + 0.01)
        #expect(h.surface.current == nil && h.controller.phase == .finished)
        let cue = try #require(h.surface.currentCue)
        #expect(h.surface.cues.count == 1 && h.controller.cue == cue)
        #expect(!h.caret.askedRanges.isEmpty && h.caret.askedRanges.allSatisfy { $0 == 5 ..< 5 + Self.text.utf16.count }, "the text this write put there")
        #expect(cue.display == Self.builtIn)
        #expect(cue.rect == Self.cueRect)
        #expect(cue.start == run.end, "when the tail fed in")
        // linefade: opaque for 65 % of 1.2 s, then linear to nothing.
        #expect(cue.opacity(at: cue.start.addingTimeInterval(0.5)) == 1)
        #expect(abs(cue.opacity(at: cue.start.addingTimeInterval(0.775)) - 0.5) < 1e-9)
        #expect(cue.opacity(at: cue.start.addingTimeInterval(1.0)) == 0)
        // The pill retracting does not take it down; its own 1.2 s does.
        h.controller.stateChanged(.hidden)
        h.clock.advance(cue.end.timeIntervalSince(h.clock.now) - 0.01)
        #expect(h.surface.currentCue == cue)
        h.clock.advance(0.02)
        #expect(h.surface.currentCue == nil && h.surface.cueClears == 1 && h.controller.cue == nil)
        h.clock.advance(5)
        #expect(h.surface.cues.count == 1, "one cue per insertion")
    }

    @Test func aLandingReportedAfterTheFlightStillLeavesTheCue() throws {
        let h = Harness()
        h.caret.textRect = Self.landedAX
        h.preview()
        h.insert()
        h.clock.advance(SpoolFlight.duration + 0.01)
        #expect(h.controller.phase == .finished && h.surface.cues.isEmpty)
        landed(h)
        #expect(try #require(h.surface.currentCue).rect == Self.cueRect)
        landed(h)
        #expect(h.surface.cues.count == 1, "a re-published landed row adds nothing")
    }

    @Test func noCueWithoutAVerifiedLanding() {
        for verified in [false, nil] as [Bool?] {
            let h = Harness()
            h.caret.textRect = Self.landedAX
            h.preview()
            h.insert()
            if let verified { landed(h, verified: verified) }
            h.clock.advance(3)
            #expect(h.surface.cues.isEmpty && h.caret.askedRanges.isEmpty, "\(String(describing: verified))")
        }
    }

    /// No flight, no cue: every suppression of the flight suppresses the cue too, and a landed text
    /// that cannot be measured, or that sits on another display than the flight, draws none.
    @Test func cueSuppressionMatrix() {
        struct Row {
            var name: String
            var setUp: (Harness) -> Void
        }
        let rows: [Row] = [
            Row(name: "secure field") {
                $0.probe.value = TapeFlightProbe(focus: TapeFlightTests.textEdit, selection: nil, isSecure: true)
            },
            Row(name: "other display") { $0.caret.rect = TapeFlightTests.caretOnExternalAX },
            Row(name: "no caret rect") { $0.caret.rect = nil },
            Row(name: "mouth not on screen") { $0.config.mouth = nil },
        ]
        for row in rows {
            let h = Harness()
            h.caret.textRect = Self.landedAX
            row.setUp(h)
            h.preview()
            h.insert()
            landed(h)
            h.clock.advance(3)
            #expect(h.surface.shown.isEmpty && h.surface.cues.isEmpty, "\(row.name)")
            #expect(h.caret.askedRanges.isEmpty, "\(row.name): nothing measured for a cue")
        }
        // The flight ran, but the landed text cannot be measured, or it is on another display.
        for (name, rect, reason) in [("unmeasurable", nil, TapeFlightSuppression.caretUnavailable),
                                     ("landed text on the external display", CGRect(x: 1700, y: 500, width: 80, height: 18),
                                      TapeFlightSuppression.otherDisplay)] as [(String, CGRect?, TapeFlightSuppression)] {
            let h = Harness()
            h.caret.textRect = rect
            h.preview()
            h.insert()
            landed(h)
            h.clock.advance(SpoolFlight.duration + 0.01)
            #expect(h.surface.shown.count == 1 && h.surface.cues.isEmpty, "\(name)")
            #expect(h.controller.cueSuppressions == [reason], "\(name)")
        }
        // The caret left the text this write put there: the target changed, no cue.
        let moved = Harness()
        moved.caret.textRect = Self.landedAX
        moved.preview()
        moved.insert()
        landed(moved)
        moved.clock.advance(0.5)
        moved.probe.value = TapeFlightProbe(focus: Self.textEdit, selection: 80 ..< 80)
        moved.clock.advance(0.6)
        #expect(moved.surface.cues.isEmpty)
    }

    /// Scenario 4: "ordinary destination tape cue fades, uncertainty stays" — the cue never covers a
    /// destination mark; it steps down below the strip instead.
    @Test func cueNeverDrawsOverAnUncertaintyMark() throws {
        // Pure: a strip crossing the cue's band pushes it below; one beside it does not.
        let text = CGRect(x: 300, y: 564, width: 120, height: 18)
        #expect(TapeFieldCue.rect(under: text, avoiding: []) == Self.cueRect)
        let strip = CGRect(x: 340, y: 580, width: 30, height: 12)          // overlay space
        let below = TapeFieldCue.rect(under: text, avoiding: [strip])
        #expect(below == CGRect(x: 300, y: 593, width: 120, height: 2.4))
        #expect(!below.intersects(strip))
        #expect(TapeFieldCue.rect(under: text, avoiding: [CGRect(x: 600, y: 580, width: 30, height: 12)]) == Self.cueRect)
        let chained = TapeFieldCue.rect(under: text, avoiding: [strip, CGRect(x: 380, y: 592, width: 30, height: 12)])
        #expect(chained.minY == 605)

        // Through the controller: the marks overlay's strip, in AppKit screen coordinates.
        let h = Harness()
        h.caret.textRect = Self.landedAX
        h.config.strips = [CGRect(x: 340, y: 982 - 592, width: 30, height: 12)]   // overlay y 580…592
        h.preview()
        h.insert()
        landed(h)
        h.clock.advance(SpoolFlight.duration + 0.01)
        let cue = try #require(h.surface.currentCue)
        #expect(cue.rect == below)
        #expect(!cue.rect.intersects(TapeFlightGeometry.localRect(h.config.strips[0], in: Self.builtIn)))
    }

    @Test func aNewTurnTakesTheCueDownAtOnce() throws {
        for next: PillState in [.idle, .starting, .listening(level: 0.2), .finalPreview(FinalPreviewInfo(text: "Next.", dwellRemaining: 0.9)),
                                .held(HeldPillInfo(text: Self.text, destination: "TextEdit", reason: "focus moved")),
                                .error(message: "Couldn’t insert"), .cancelled] {
            let h = Harness()
            h.caret.textRect = Self.landedAX
            h.preview()
            h.insert()
            landed(h)
            h.clock.advance(SpoolFlight.duration + 0.01)
            _ = try #require(h.surface.currentCue)
            h.controller.stateChanged(next)
            #expect(h.surface.currentCue == nil && h.surface.cueClears == 1, "\(next.caseName)")
            h.clock.advance(2)
            #expect(h.surface.cueClears == 1, "\(next.caseName): its fade timer never fires into the next turn")
        }
    }
    @Test func verifiedLinesCarryTheSameRibbonIntoEveryDestinationUnderline() throws {
        let h = Harness()
        h.caret.textLines = [Self.landedAX, CGRect(x: 300, y: 588, width: 220, height: 18),
                            CGRect(x: 300, y: 612, width: 84, height: 18)]
        h.preview(); h.insert()
        let run = try #require(h.surface.current)
        #expect(run.path.lines.isEmpty, "No text geometry is invented before delivery acknowledgement")
        landed(h)
        #expect(run.path.verified)
        #expect(run.path.lines.map(\.width) == [120, 220, 84])
        #expect(run.path.lines.map(\.x) == [300, 300, 300])
        let animated = try #require(run.frame(at: run.start.addingTimeInterval(1.15)))
        #expect(animated.linePoints.count == 3)
        h.clock.advance(SpoolFlight.duration + 0.01)
        let cue = try #require(h.surface.currentCue)
        #expect(cue.rects.count == 3)
        for (line, rect) in zip(run.path.lines, cue.rects) {
            #expect(line.x == Double(rect.minX))
            #expect(line.y == Double(rect.midY))
            #expect(line.width == Double(rect.width))
        }
    }

    @Test func lineGeometryNeverTransfersToAChangedDestination() throws {
        let h = Harness()
        h.caret.textLines = [Self.landedAX]
        h.preview(); h.insert(); landed(h)
        #expect(try #require(h.surface.current).path.lines.count == 1)
        h.probe.value = TapeFlightProbe(focus: nil, selection: nil)
        h.clock.advance(TapeFlightController.refreshInterval + 0.01)
        #expect(h.surface.current == nil)
        #expect(h.surface.currentCue == nil)
        #expect(h.controller.phase == .suppressed(.targetChanged))
    }

    @Test func reduceMotionLeavesOnlyAStaticVerifiedCue() throws {
        let h = Harness()
        h.config.reduced = true
        h.caret.textLines = [Self.landedAX]
        h.preview(); h.insert()
        #expect(h.surface.shown.isEmpty && h.surface.cues.isEmpty)
        landed(h)
        let cue = try #require(h.surface.currentCue)
        #expect(cue.reduced && cue.rects.count == 1)
        #expect(cue.opacity(at: cue.start.addingTimeInterval(0.9)) == 1)
        h.clock.advance(TapeFieldCue.lifetime + 0.01)
        #expect(h.surface.currentCue == nil && h.surface.shown.isEmpty)
    }

    @Test func unconfirmedOutcomeDiscardsPendingVerifiedGeometry() {
        let h = Harness(manualQueue: true)
        h.caret.textLines = [Self.landedAX]
        h.preview(); h.insert(); h.queue?.drain()
        landed(h)
        landed(h, verified: false)
        h.queue?.drain()
        h.clock.advance(3)
        #expect(h.controller.phase == .suppressed(.unconfirmed))
        #expect(h.surface.current == nil && h.surface.cues.isEmpty)
    }

    @Test func failedVerifiedGeometryTakesDownTheExistingRibbon() {
        let h = Harness()
        h.caret.textLines = [Self.landedAX]
        h.preview(); h.insert(); landed(h)
        h.caret.textLines = []
        h.clock.advance(TapeFlightController.refreshInterval + 0.01)
        #expect(h.controller.phase == .suppressed(.caretUnavailable))
        #expect(h.surface.current == nil)
        h.clock.advance(2)
        #expect(h.surface.cues.isEmpty)
    }

    @Test func cueValidatesFocusGeometryAndDisplayThroughoutItsLifetime() throws {
        let changes: [(Harness) -> Void] = [
            { $0.probe.value = TapeFlightProbe(focus: nil, selection: nil) },
            { $0.caret.textLines = [] },
            { $0.caret.textLines = [Self.landedAX.offsetBy(dx: 0, dy: 40)] },
            { $0.config.displays = [Self.external] },
        ]
        for reduced in [false, true] {
            for change in changes {
                let h = Harness()
                h.config.reduced = reduced
                h.caret.textLines = [Self.landedAX]
                h.preview(); h.insert(); landed(h)
                if !reduced { h.clock.advance(SpoolFlight.duration) }
                _ = try #require(h.surface.currentCue)
                change(h)
                h.clock.advance(TapeFlightController.refreshInterval + 0.01)
                #expect(h.surface.currentCue == nil && h.surface.cueClears == 1)
                h.clock.advance(2)
                #expect(h.surface.cues.count == 1 && h.surface.cueClears == 1)
            }
        }
    }

    @Test func settlingCannotJumpToGeometryChangedAfterTheLastFlightRead() {
        let h = Harness()
        h.caret.textLines = [Self.landedAX]
        h.preview(); h.insert(); landed(h)
        h.clock.advance(1.29)
        h.caret.textLines = [Self.landedAX.offsetBy(dx: 60, dy: 0)]
        h.clock.advance(0.02)
        #expect(h.surface.cues.isEmpty)
        #expect(h.controller.phase == .suppressed(.geometryChanged))
    }

    @Test func verifiedGeometryEasesOutOfTheExistingCaretBridge() throws {
        let h = Harness()
        h.caret.textLines = [Self.landedAX]
        h.preview(); h.insert()
        h.clock.advance(0.6)
        let run = try #require(h.surface.current)
        let before = try #require(run.frame(at: h.clock.now))
        landed(h)
        let atAcknowledgement = try #require(run.frame(at: h.clock.now))
        #expect(atAcknowledgement.points == before.points)
        #expect(atAcknowledgement.linePoints.isEmpty)
        h.clock.advance(0.06)
        let midway = try #require(run.frame(at: h.clock.now))
        #expect(midway.points != before.points && !midway.linePoints.isEmpty)
        h.clock.advance(0.07)
        let finished = try #require(run.frame(at: h.clock.now))
        #expect(finished == run.path.frame(t: h.clock.now.timeIntervalSince(run.start)))
    }

    @Test func measuredRTLUsesLogicalEndpointCaretsAndNegativeFlightWidths() throws {
        let rect = Self.landedAX
        let left = CGRect(x: rect.minX, y: rect.minY, width: 0, height: rect.height)
        let right = CGRect(x: rect.maxX, y: rect.minY, width: 0, height: rect.height)
        #expect(TapeFlightLineMeasurement.measuredRTL(rect: rect, start: right, end: left))
        #expect(!TapeFlightLineMeasurement.measuredRTL(rect: rect, start: left, end: right))
        #expect(!TapeFlightLineMeasurement.measuredRTL(rect: rect, start: right, end: left.offsetBy(dx: 0, dy: 24)))
        #expect(!TapeFlightLineMeasurement.measuredRTL(rect: rect, start: right, end: left.offsetBy(dx: 20, dy: 0)))
        #expect(!TapeFlightLineMeasurement.measuredRTL(rect: rect, start: nil, end: left))
        let h = Harness()
        h.caret.textLines = [rect]
        h.caret.rtl = true
        h.preview(); h.insert(); landed(h)
        let line = try #require(h.surface.current?.path.lines.first)
        #expect(line.x == rect.maxX && line.width == -rect.width)
        h.clock.advance(SpoolFlight.duration)
        #expect(try #require(h.surface.currentCue).rect == Self.cueRect)
    }

}
