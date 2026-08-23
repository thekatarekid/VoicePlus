import Foundation
import CoreGraphics
import Testing
@testable import VoicePlusApp

@Suite("P3.2 stroke geometry")
struct StrokeGeometryTests {
    @Test func taperWidthsRampInAndOut() {
        var s = StrokeStyle(); s.baseWidth = 10; s.taperFraction = 0.2; s.minWidthFraction = 0.1
        #expect(StrokeGeometry.width(at: 0, style: s) == 1)          // tip
        #expect(StrokeGeometry.width(at: 1, style: s) == 1)
        #expect(StrokeGeometry.width(at: 0.5, style: s) == 10)       // body at full
        #expect(StrokeGeometry.width(at: 0.3, style: s) == 10)
        let w1 = StrokeGeometry.width(at: 0.05, style: s), w2 = StrokeGeometry.width(at: 0.15, style: s)
        #expect(w1 < w2 && w2 < 10)
        #expect(StrokeGeometry.width(at: 0.5, style: s, pressure: 0.5) == 5)
    }

    @Test func jitterIsDeterministicForSeed() {
        let pts = (0..<30).map { CGPoint(x: CGFloat($0) * 5, y: sin(CGFloat($0) / 3) * 20) }
        let a = StrokeGeometry.outline(points: pts, seed: 42)
        let b = StrokeGeometry.outline(points: pts, seed: 42)
        let c = StrokeGeometry.outline(points: pts, seed: 43)
        #expect(a == b)
        #expect(a != c)
        #expect(a.count == 2 * StrokeGeometry.resample(pts, spacing: 3).count)
        let id = UUID()
        #expect(StrokeGeometry.seed(for: id) == StrokeGeometry.seed(for: id))
    }

    @Test func jitterStaysWithinBound() {
        var s = StrokeStyle(); s.jitter = 1.5; s.baseWidth = 4
        let pts = [CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 0)]
        let o = StrokeGeometry.outline(points: pts, style: s, seed: 7)
        // straight horizontal line: every vertex's |y| ≤ jitter + half width
        #expect(o.allSatisfy { abs($0.y) <= s.jitter + s.baseWidth / 2 + 1e-9 })
        #expect(o.contains { $0.y != 0 })
    }

    @Test func singlePointBecomesDot() {
        let o = StrokeGeometry.outline(points: [CGPoint(x: 5, y: 5)], seed: 1)
        #expect(o.count == 12)
        #expect(!StrokeGeometry.path(outline: o).isEmpty)
    }
}

@Suite("P3.2 fade + pulse models")
struct FadeScheduleTests {
    @Test func holdsThenFadesOverOnePointFiveSeconds() {
        let f = FadeSchedule(start: 10, hold: 0.2, duration: 1.5)
        #expect(f.opacity(at: 10.1) == 1)
        #expect(f.opacity(at: 10.2) == 1)
        #expect(f.opacity(at: 11.7) == 0)
        #expect(f.isFinished(at: 11.7) && !f.isFinished(at: 11.69))
        let mid = f.opacity(at: 10.95)
        #expect(mid > 0 && mid < 1)
        #expect(f.opacity(at: 11.5) < mid)
        #expect(f.extended(from: 20).end == 21.7)
    }

    @Test func pulseFrameInsets() {
        let p = PulseSpec()
        #expect(p.frame(for: CGRect(x: 10, y: 10, width: 100, height: 50)) == CGRect(x: 7, y: 7, width: 106, height: 56))
        #expect(p.duration < 1)
    }
}

@Suite("P3.2 region bundle counter")
struct RegionBundleCounterTests {
    @Test func dedupesOverlappingAndCountsAcrossWindows() {
        var c = RegionBundleCounter()
        c.add(BoundRegion(frame: CGRect(x: 0, y: 0, width: 100, height: 100), displayID: 1, windowID: 7))
        c.add(BoundRegion(frame: CGRect(x: 2, y: 2, width: 100, height: 100), displayID: 1, windowID: 7))  // same
        #expect(c.count == 1 && c.pillText == nil)
        c.add(BoundRegion(frame: CGRect(x: 300, y: 0, width: 50, height: 50), displayID: 1, windowID: 7))
        #expect(c.count == 2 && c.pillText == nil)        // same window → no count shown
        c.add(BoundRegion(frame: CGRect(x: 0, y: 0, width: 50, height: 50), displayID: 2, windowID: 9))
        #expect(c.count == 3 && c.displayCount == 2 && c.pillText == "3 regions")
        c.reset()
        #expect(c.count == 0)
    }
}
