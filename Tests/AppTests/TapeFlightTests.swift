import Actions
import Combine
import Foundation
import Injection
import Testing
@testable import VoicePlusApp

/// S4 — the mouth-to-caret tape flight (design §4 "Mouth-to-caret tape path", §5 step 6): anchor maths
/// across displays and scale factors, the suppression matrix, and the flight taken down on any state
/// change. The ribbon's own maths is S1's `SpoolFlight`, checked here through the flight's path against
/// the prototype's six `flights` hashes. Nothing here touches Accessibility, a window or a display.
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
        private(set) var asked: [Int] = []
        init(_ rect: CGRect?) { self.rect = rect }
        func caretRect(at index: Int) -> CGRect? {
            asked.append(index)
            return rect
        }
    }

    final class FakeSurface: TapeFlightSurface {
        private(set) var shown: [TapeFlightRun] = []
        private(set) var clears = 0
        private(set) var current: TapeFlightRun?
        func show(_ run: TapeFlightRun) {
            shown.append(run)
            current = run
        }
        func clear() {
            clears += 1
            current = nil
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
                                              queues: queues)
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
        #expect(ready.mouth == SpoolPoint(482, 111))
        let left = DisplayFrame(id: 3, frame: CGRect(x: -1920, y: 200, width: 1920, height: 1080), scale: 1)
        let displays = [Self.builtIn, left]
        struct Case { var display: DisplayFrame; var panel: CGRect; var sceneSize: CGSize }
        let cases = [
            Case(display: Self.builtIn, panel: CGRect(x: 476, y: 982 - 32 - 164, width: 560, height: 164),
                 sceneSize: CGSize(width: 560, height: 164)),
            Case(display: left, panel: CGRect(x: -1920 + 680, y: 1280 - 24 - 164, width: 560, height: 164),
                 sceneSize: CGSize(width: 560, height: 164)),
            Case(display: left, panel: CGRect(x: -1500, y: 900, width: 420, height: 123),
                 sceneSize: CGSize(width: 420, height: 123)),
            Case(display: Self.builtIn, panel: CGRect(x: 200, y: 600, width: 280, height: 82),
                 sceneSize: CGSize(width: 280, height: 82)),
        ]
        for c in cases {
            let anchors = SpoolAnchors(frame: ready, size: c.sceneSize, origin: .zero)
            let scale = c.sceneSize.height / 164
            #expect(abs(anchors.mouthAnchor.x - 482 * scale) < 1e-9 && abs(anchors.mouthAnchor.y - 111 * scale) < 1e-9)
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
    /// file's (480, 111) → (140, 420), reproduces the six `flights` hashes at 1× and 2×.
    @Test func flightPathMatchesThePrototypesGoldenFlights() throws {
        let golden = SpoolParityTests.golden.flights
        #expect(golden.count == 6)
        for scale in [1.0, 2.0] as [CGFloat] {
            let primary = DisplayFrame(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), scale: 2)
            let side = DisplayFrame(id: 9, frame: CGRect(x: -900, y: 300, width: 900, height: 600), scale: scale)
            let mouth = CGPoint(x: -900 + 480, y: 900 - 111)
            // Caret centre at AppKit (−760, 480): rect 470…490, AX y = 900 − 490.
            let caretAX = CGRect(x: -760, y: 410, width: 0, height: 20)
            let path = try #require(try? TapeFlightGeometry.path(mouth: mouth, caretAX: caretAX, displays: [primary, side]).get())
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
        #expect(TapeFlightPlanner.arm(TapeFlightProbe(focus: Self.textEdit, selection: nil)) == .refused(.caretUnavailable))
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
        #expect(verify(TapeFlightProbe(focus: Self.textEdit, selection: nil)) == .caretUnavailable)
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
        h.clock.advance(0.06)
        #expect(h.surface.current == nil)
        #expect(h.surface.clears == 1)
        #expect(h.controller.phase == .finished)
        // A re-published `.inserting` or the landed outcome starts nothing new.
        h.insert()
        h.controller.stateChanged(.landed(LandedPillInfo(text: Self.text, verified: true)))
        #expect(h.surface.shown.count == 1)
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
                #expect(h.probe.reads == 0 && h.caret.asked.isEmpty, "reduce motion reads nothing")
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
        // The landed outcome of the same write lets the ribbon finish; the idle row after it does not.
        let h = Harness()
        h.preview()
        h.insert()
        h.clock.advance(0.1)
        h.controller.stateChanged(.landed(LandedPillInfo(text: Self.text, verified: false)))
        #expect(h.surface.current != nil)
        h.clock.advance(0.5)
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
        h.clock.advance(1.2)
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
        reel.advance(.inserting, t: 1.1, dt: 0.02)
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
}
