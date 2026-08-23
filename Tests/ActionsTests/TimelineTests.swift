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

@Suite("P3.1 ink capture + recorder")
struct InkCaptureTests {
    final class Sink: InkStrokeSink {
        var began = 0, changed = 0, ended: [InkStroke] = []
        func strokeBegan(_ s: InkStroke) { began += 1 }
        func strokeChanged(_ s: InkStroke) { changed += 1 }
        func strokeEnded(_ s: InkStroke) { ended.append(s) }
    }

    @Test func strokeFeedsTimelineAndSink() {
        let tl = InputTimeline()
        let sink = Sink()
        let cap = InkStrokeCapture(timeline: tl, sink: sink)
        cap.begin(at: pt(0, 0), time: 1)
        cap.extend(to: pt(0.5, 0), time: 1.01)     // below min spacing → dropped
        cap.extend(to: pt(10, 0), time: 1.02)
        cap.extend(to: pt(20, 5, d: 2), time: 1.03) // crosses displays
        let s = cap.end(time: 1.05)
        #expect(sink.began == 1 && sink.changed == 2 && sink.ended.count == 1)
        #expect(s?.points.count == 3 && s?.isComplete == true)
        #expect(s?.displayIDs == [1, 2])
        #expect(s?.timeRange == 1.0...1.03)
        #expect(tl.strokes(in: 1...1.05)[s!.id]?.count == 3)
        #expect(cap.current == nil)
    }

    @Test func recorderSyntheticEventsProduceStrokeAndClicks() throws {
        var fake: TimelineInstant = 0
        let clock = TimelineClock(source: { fake })
        let n = DisplayNormalizer(displays: [DisplayFrame(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 500))])
        let rec = EventTapRecorder(normalizer: n, clock: clock)
        let sink = Sink(); rec.ink.sink = sink
        func ev(_ type: CGEventType, _ x: CGFloat, _ y: CGFloat) -> CGEvent {
            let e = try! #require(CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left))
            return e
        }
        rec.handle(.leftMouseDown, ev(.leftMouseDown, 10, 10)); fake += 0.05
        rec.handle(.leftMouseDragged, ev(.leftMouseDragged, 50, 10)); fake += 0.05
        rec.handle(.leftMouseDragged, ev(.leftMouseDragged, 90, 10)); fake += 0.05
        rec.handle(.leftMouseUp, ev(.leftMouseUp, 90, 10))
        #expect(sink.ended.count == 1 && sink.ended[0].points.count == 3)
        let clicks = rec.timeline.events.filter { if case .click = $0.kind { return true } else { return false } }
        #expect(clicks.count == 2)
        // Quartz y=10 on a 500-tall display → cocoa y=490
        #expect(sink.ended[0].points[0].point.y == 490)
        #expect(rec.isRecording == false)
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
