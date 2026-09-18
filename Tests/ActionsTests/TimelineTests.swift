import Foundation
import CoreGraphics
import Testing
@testable import Actions

private func pt(_ x: CGFloat, _ y: CGFloat, d: UInt32 = 1) -> GlobalPoint { GlobalPoint(x: x, y: y, displayID: d) }

@Suite("P3.1 InputTimeline ring buffer")
struct InputTimelineTests {
    @Test func evictsBeyondHorizon() {
        let tl = InputTimeline(horizon: 30)
        for i in 0..<40 { tl.record(.pointerMove(pt(CGFloat(i), 0)), at: Double(i)) }
        // newest is t=39 → cutoff 9 → events with t<9 gone
        #expect(tl.eventCount == 31)
        #expect(tl.events.first?.timestamp == 9)
        #expect(tl.events.last?.timestamp == 39)
    }

    @Test func expireAgesOutWithoutNewEvents() {
        let tl = InputTimeline(horizon: 30)
        tl.record(.pointerMove(pt(0, 0)), at: 0)
        tl.record(.pointerMove(pt(1, 0)), at: 5)
        tl.expire(now: 34)
        #expect(tl.eventCount == 1)
        tl.expire(now: 36)
        #expect(tl.eventCount == 0)
    }

    @Test func capacityBoundWrapsAndKeepsOrder() {
        let tl = InputTimeline(horizon: 1000, capacity: 8)
        for i in 0..<20 { tl.record(.pointerMove(pt(CGFloat(i), 0)), at: Double(i)) }
        #expect(tl.eventCount == 8)
        #expect(tl.events.map(\.timestamp) == (12..<20).map(Double.init))
        tl.clear()
        #expect(tl.eventCount == 0)
    }

    @Test func pointerAtInstantPicksLatestBeforeOrNearestAfter() {
        let tl = InputTimeline()
        tl.record(.pointerMove(pt(10, 10)), at: 1.0)
        tl.record(.click(pt(20, 20), button: .left, down: true), at: 2.0)
        tl.record(.selectionChange(.init(bundleID: nil, pid: 1, bounds: nil, length: 3)), at: 2.5)
        tl.record(.pointerMove(pt(30, 30)), at: 3.0)
        #expect(tl.pointer(at: 2.7) == pt(20, 20))
        #expect(tl.pointer(at: 0.9) == pt(10, 10))       // just before first, within tolerance
        #expect(tl.pointer(at: 0.5) == nil)
        #expect(tl.selection(at: 2.6)?.length == 3)
        #expect(tl.selection(at: 2.4) == nil)
    }

    @Test func strokesInRangeReturnWholeStroke() {
        let tl = InputTimeline()
        let a = UUID(), b = UUID()
        for i in 0..<5 { tl.record(.strokePoint(strokeID: a, pt(CGFloat(i), 0), pressure: 1), at: Double(i)) }
        for i in 10..<13 { tl.record(.strokePoint(strokeID: b, pt(CGFloat(i), 0), pressure: 1), at: Double(i)) }
        let s = tl.strokes(in: 3...4)
        #expect(s.keys.count == 1)
        #expect(s[a]?.count == 5)
        #expect(tl.strokes(in: 6...9).isEmpty)
    }
}

@Suite("P3.1 display normalization")
struct DisplayNormalizerTests {
    // Primary 1920x1080 at origin; second display to the right and raised; third to the left, smaller.
    let n = DisplayNormalizer(displays: [
        DisplayFrame(id: 1, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
        DisplayFrame(id: 2, frame: CGRect(x: 1920, y: 200, width: 2560, height: 1440)),
        DisplayFrame(id: 3, frame: CGRect(x: -1440, y: -100, width: 1440, height: 900)),
    ])

    @Test func quartzToCocoaFlipsAroundPrimaryHeight() {
        // Quartz (0,0) is the primary's top-left → Cocoa (0,1080)
        #expect(n.cocoaPoint(fromQuartz: .zero) == CGPoint(x: 0, y: 1080))
        let q = CGPoint(x: 2000, y: -300) // above primary top, on display 2
        let c = n.cocoaPoint(fromQuartz: q)
        #expect(c == CGPoint(x: 2000, y: 1380))
        #expect(n.quartzPoint(fromCocoa: c) == q)
    }

    @Test func tagsDisplayAndUnitCoordinates() {
        let p = n.normalize(quartz: CGPoint(x: 3200, y: -360))   // cocoa (3200, 1440)
        #expect(p.displayID == 2)
        #expect(abs(p.unit.x - 0.5) < 1e-6)
        #expect(abs(p.unit.y - (1440 - 200) / 1440) < 1e-6)
        #expect(n.local(p) == CGPoint(x: 1280, y: 1240))
        let left = n.normalize(cocoa: CGPoint(x: -720, y: 350))
        #expect(left.displayID == 3)
        #expect(abs(left.unit.x - 0.5) < 1e-6 && abs(left.unit.y - 0.5) < 1e-6)
    }

    @Test func pointOffAllDisplaysSnapsToNearest() {
        let p = n.normalize(cocoa: CGPoint(x: 1900, y: 1300))  // in the notch above primary, next to display 2
        #expect(p.displayID == 2)
    }
}

@Suite("P3.1 clock alignment")
struct ClockAlignmentTests {
    @Test func instantsMapToAudioSecondsAndBack() {
        var fake: TimelineInstant = 1000
        let clock = TimelineClock(source: { fake })
        let align = CaptureAlignment.starting(now: clock)
        fake = 1002.5
        #expect(align.audioSeconds(at: clock.now()) == 2.5)
        #expect(align.instants(for: 1.0...1.4) == 1001.0...1001.4)
        #expect(align.audioRange(for: 1003...1004) == 3...4)
    }

    @Test func wordSpanLooksUpPointerOnSharedClock() {
        var fake: TimelineInstant = 50
        let clock = TimelineClock(source: { fake })
        let tl = InputTimeline()
        let align = CaptureAlignment.starting(now: clock)
        fake = 50.4; tl.record(.pointerMove(pt(100, 100)), at: clock.now())
        fake = 51.2; tl.record(.pointerMove(pt(700, 300)), at: clock.now())
        // "this" spoken at audio 0.3–0.5 → pointer was at (100,100); "there" at 1.3–1.5 → (700,300)
        #expect(tl.pointer(at: align.instants(for: 0.3...0.5).lowerBound) == pt(100, 100))
        #expect(tl.pointer(at: align.instants(for: 1.3...1.5).upperBound) == pt(700, 300))
    }

    @Test func sharedClockIsMonotonic() {
        let a = TimelineClock.shared.now(), b = TimelineClock.shared.now()
        #expect(b >= a && a > 0)
    }
}

@Suite("G1 region capture + recorder")
struct RegionCaptureTests {
    final class Sink: RegionSink {
        var began = 0, changed = 0, ended: [DrawnRegion] = [], discarded = 0
        func regionBegan(_ r: DrawnRegion) { began += 1 }
        func regionChanged(_ r: DrawnRegion) { changed += 1 }
        func regionEnded(_ r: DrawnRegion) { ended.append(r) }
        func regionDiscarded(_ r: DrawnRegion) { discarded += 1 }
    }

    static let twoDisplays = DisplayNormalizer(displays: [DisplayFrame(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 500)),
                                                          DisplayFrame(id: 2, frame: CGRect(x: 1000, y: 0, width: 800, height: 600))])

    @Test func dragBecomesBoxOnTimelineAndSink() {
        let tl = InputTimeline()
        let sink = Sink()
        let cap = RegionCapture(timeline: tl, normalizer: Self.twoDisplays, sink: sink)
        var finished: [DrawnRegion] = []
        cap.onRegion = { finished.append($0) }
        cap.begin(at: pt(300, 200), time: 1)
        cap.update(to: pt(200, 260), time: 1.05)     // dragged up-left: rect normalises
        let r = cap.end(time: 1.1)
        #expect(sink.began == 1 && sink.changed == 1 && sink.ended.count == 1 && finished.count == 1)
        #expect(r?.rect == CGRect(x: 200, y: 200, width: 100, height: 60))
        #expect(r?.isComplete == true && r?.displayID == 1)
        let boxes = tl.regions(in: 0...2)
        #expect(boxes.count == 1 && boxes[0].sample.rect == r?.rect && boxes[0].began == 1 && boxes[0].ended == 1.1)
        #expect(cap.current == nil && cap.completed.count == 1)
    }

    @Test func boxIsClampedToTheDisplayItStartedOn() {
        let cap = RegionCapture(timeline: InputTimeline(), normalizer: Self.twoDisplays)
        cap.begin(at: pt(900, 100), time: 0)
        cap.update(to: pt(1200, 700, d: 2), time: 0.1)   // runs onto display 2 and off its top
        let r = cap.end(time: 0.2)
        #expect(r?.displayID == 1)
        #expect(r?.rect == CGRect(x: 900, y: 100, width: 100, height: 400))
        #expect(r?.displayRect == r?.rect)                 // display 1 is at the origin
        cap.begin(at: pt(1100, 100, d: 2), time: 1)
        let second = cap.end(at: pt(1300, 300, d: 2), time: 1.1)
        #expect(second?.displayRect == CGRect(x: 100, y: 100, width: 200, height: 200))
    }

    @Test func clickOrNudgeIsNotABox() {
        let tl = InputTimeline()
        let sink = Sink()
        let cap = RegionCapture(timeline: tl, sink: sink)
        var started = 0
        cap.onBoxStarted = { _ in started += 1 }
        cap.begin(at: pt(10, 10), time: 0)
        cap.update(to: pt(40, 12), time: 0.05)          // wide but only 2 pt tall
        #expect(cap.end(time: 0.1) == nil)
        #expect(sink.discarded == 1 && sink.ended.isEmpty && started == 0)
        #expect(tl.regions(in: 0...1).isEmpty)
        cap.begin(at: pt(10, 10), time: 1)
        cap.update(to: pt(40, 40), time: 1.05)
        cap.update(to: pt(60, 60), time: 1.1)
        #expect(started == 1)                            // announced once, when it first became a box
        cap.cancel()
        #expect(sink.discarded == 2 && tl.regions(in: 0...2).isEmpty)
    }

    private static func ev(_ type: CGEventType, _ x: CGFloat, _ y: CGFloat) -> CGEvent {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)!
    }

    final class FakeTime: @unchecked Sendable { var now: TimelineInstant = 0 }

    /// Drives one drag (down, two drags, up) through the recorder's synthetic entry point.
    private static func drag(_ rec: EventTapRecorder, time: FakeTime) {
        rec.handle(.leftMouseDown, ev(.leftMouseDown, 10, 10)); time.now += 0.05
        rec.handle(.leftMouseDragged, ev(.leftMouseDragged, 50, 40)); time.now += 0.05
        rec.handle(.leftMouseDragged, ev(.leftMouseDragged, 90, 60)); time.now += 0.05
        rec.handle(.leftMouseUp, ev(.leftMouseUp, 90, 60))
    }

    /// The G1 gesture table: key down + drag → box; drag alone → nothing; latch + setting → box;
    /// latch without the setting → nothing; the setting never applies outside latch.
    @Test(arguments: [
        (keyDown: true, latched: false, drawWithoutKey: false, box: true),
        (keyDown: false, latched: false, drawWithoutKey: false, box: false),
        (keyDown: false, latched: true, drawWithoutKey: true, box: true),
        (keyDown: false, latched: true, drawWithoutKey: false, box: false),
        (keyDown: false, latched: false, drawWithoutKey: true, box: false),
        (keyDown: true, latched: true, drawWithoutKey: false, box: true),
    ])
    func gestureTable(row: (keyDown: Bool, latched: Bool, drawWithoutKey: Bool, box: Bool)) {
        #expect(RegionGesturePolicy.drawsRegion(keyDown: row.keyDown, latched: row.latched,
                                                drawWithoutKey: row.drawWithoutKey) == row.box)
        let time = FakeTime()
        let clock = TimelineClock(source: { time.now })
        let n = DisplayNormalizer(displays: [DisplayFrame(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 500))])
        let rec = EventTapRecorder(normalizer: n, clock: clock)
        rec.gate = RegionGate(isDictationKeyDown: { row.keyDown }, isLatched: { row.latched },
                              drawWithoutKey: { row.drawWithoutKey })
        let sink = Sink(); rec.regions.sink = sink
        Self.drag(rec, time: time)
        #expect((sink.ended.count == 1) == row.box)
        #expect(rec.timeline.regions(in: 0...10).count == (row.box ? 1 : 0))
        // Clicks and the pointer path are recorded either way.
        let clicks = rec.timeline.events.filter { if case .click = $0.kind { return true } else { return false } }
        #expect(clicks.count == 2)
        if row.box {
            // Quartz (10,10)→(90,60) on a 500-tall display → Cocoa x 10…90, y 440…490.
            #expect(sink.ended[0].rect == CGRect(x: 10, y: 440, width: 80, height: 50))
        }
    }

    @Test func closedGateByDefaultDrawsNothing() {
        let time = FakeTime()
        let rec = EventTapRecorder(normalizer: DisplayNormalizer(displays: [DisplayFrame(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100))]),
                                   clock: TimelineClock(source: { time.now }))
        let sink = Sink(); rec.regions.sink = sink
        Self.drag(rec, time: time)
        #expect(sink.began == 0 && sink.ended.isEmpty && !RegionGate.closed.isOpen)
    }

    @Test func keyPressedMidDragStartsTheBoxAtTheMouseDown() {
        final class Key: @unchecked Sendable { var down = false }
        let time = FakeTime(), key = Key()
        let rec = EventTapRecorder(normalizer: DisplayNormalizer(displays: [DisplayFrame(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 500))]),
                                   clock: TimelineClock(source: { time.now }))
        rec.gate = RegionGate(isDictationKeyDown: { key.down })
        let sink = Sink(); rec.regions.sink = sink
        rec.handle(.leftMouseDown, Self.ev(.leftMouseDown, 10, 10)); time.now += 0.05
        rec.handle(.leftMouseDragged, Self.ev(.leftMouseDragged, 30, 30)); time.now += 0.05
        key.down = true
        rec.handle(.leftMouseDragged, Self.ev(.leftMouseDragged, 90, 60)); time.now += 0.05
        key.down = false                                   // released before the mouse: the box stays
        rec.handle(.leftMouseUp, Self.ev(.leftMouseUp, 90, 60))
        #expect(sink.ended.count == 1)
        #expect(sink.ended.first?.rect == CGRect(x: 10, y: 440, width: 80, height: 50))
    }

    @Test func startWithoutPermissionThrowsOrStarts() {
        let n = DisplayNormalizer(displays: [DisplayFrame(id: 1, frame: CGRect(x: 0, y: 0, width: 10, height: 10))])
        let rec = EventTapRecorder(normalizer: n)
        if EventTapRecorder.hasListenAccess {
            try? rec.start(); rec.stop()
            #expect(rec.isRecording == false)
        } else {
            #expect(throws: InputRecorderError.inputMonitoringNotGranted) { try rec.start() }
        }
    }
}
