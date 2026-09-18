import Actions
import AppKit
import Foundation
import CoreGraphics
import Testing
@testable import VoicePlusApp

@Suite("G1 region geometry")
struct RegionGeometryTests {
    @Test func crispBoxIsOneClosedRectangle() {
        let r = CGRect(x: 10, y: 20, width: 100, height: 50)
        let edges = RegionGeometry.edges(of: r, seed: 1)
        #expect(edges.count == 4)
        #expect(edges[0].0 == CGPoint(x: 10, y: 20) && edges[0].1 == CGPoint(x: 110, y: 20))
        #expect(edges[2].0 == CGPoint(x: 110, y: 70) && edges[2].1 == CGPoint(x: 10, y: 70))
        #expect(RegionGeometry.path(for: r, seed: 1).boundingBox == r)
        #expect(RegionStyle().lineWidth == 1 && RegionStyle().cornerJitter == 0)   // 1 px, crisp by default
    }

    @Test func handDrawnCornersAreDeterministicAndBounded() {
        let r = CGRect(x: 0, y: 0, width: 200, height: 80)
        let style = RegionStyle.handDrawn
        let a = RegionGeometry.edges(of: r, style: style, seed: 42)
        let b = RegionGeometry.edges(of: r, style: style, seed: 42)
        let c = RegionGeometry.edges(of: r, style: style, seed: 43)
        #expect(a.map { [$0.0, $0.1] } == b.map { [$0.0, $0.1] })
        #expect(a.map { [$0.0, $0.1] } != c.map { [$0.0, $0.1] })
        // Every endpoint stays within the jitter of the true box.
        let bound = r.insetBy(dx: -style.cornerJitter - 0.001, dy: -style.cornerJitter - 0.001)
        #expect(a.allSatisfy { bound.contains($0.0) && bound.contains($0.1) })
        #expect(!RegionGeometry.path(for: r, style: style, seed: 42).isEmpty)
        let id = UUID()
        #expect(RegionGeometry.seed(for: id) == RegionGeometry.seed(for: id))
    }

    @Test func oneLineLandsOnWholePixels() {
        // 1 pt at 1×: one pixel wide → centred on the half pixel.
        #expect(RegionGeometry.pixelAligned(CGRect(x: 10.2, y: 20.7, width: 99.6, height: 50.4), scale: 1)
                == CGRect(x: 10.5, y: 21.5, width: 99, height: 49))
        // 1 pt at 2×: two pixels wide → edges on the pixel grid, no half-pixel shift.
        #expect(RegionGeometry.pixelAligned(CGRect(x: 10.2, y: 20.7, width: 99.6, height: 50.4), scale: 2)
                == CGRect(x: 10, y: 20.5, width: 99.5, height: 50.5))
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

@Suite("G1 box layer + bundle")
@MainActor
struct RegionOverlayTests {
    static func box(_ rect: CGRect, display: UInt32 = 1) -> DrawnRegion {
        DrawnRegion(anchor: GlobalPoint(x: rect.minX, y: rect.minY, displayID: display),
                    corner: GlobalPoint(x: rect.maxX, y: rect.maxY, displayID: display),
                    rect: rect, displayID: display, displayRect: rect, began: 0, ended: 0.3, isComplete: true)
    }

    @Test func boxIsAnOrangeOnePointOutlineThatFadesOverOnePointFiveSeconds() {
        let view = RegionLayerView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let id = UUID()
        view.draw(region: id, localRect: CGRect(x: 10, y: 20, width: 200, height: 80))
        view.draw(region: id, localRect: CGRect(x: 10, y: 20, width: 220, height: 90))   // dragged further: same layer
        #expect(view.boxLayers.count == 1)
        let layer = view.boxLayers[id]
        #expect(layer?.lineWidth == 1 && layer?.fillColor == nil)
        #expect(layer?.strokeColor == NSColor.systemOrange.cgColor)
        #expect(layer?.path?.boundingBox.width ?? 0 >= 219 && layer?.path?.boundingBox.height ?? 0 >= 89)
        #expect(view.fadeAll() == 1.5 && view.boxLayers.isEmpty)
        let small = UUID()
        view.draw(region: small, localRect: CGRect(x: 0, y: 0, width: 3, height: 3))
        view.discard(region: small)
        #expect(view.boxLayers.isEmpty)
    }

    @Test func boxesInOneUtteranceBundle() {
        let overlay = RegionOverlayController(normalizer: DisplayNormalizer(displays: [
            DisplayFrame(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 800)),
            DisplayFrame(id: 2, frame: CGRect(x: 1000, y: 0, width: 1000, height: 800)),
        ]))
        var texts: [String?] = []
        overlay.onBundleChanged = { texts.append($0) }
        overlay.noteBox(Self.box(CGRect(x: 10, y: 10, width: 100, height: 60)))
        overlay.noteBox(Self.box(CGRect(x: 12, y: 12, width: 100, height: 60)))          // the same box again
        #expect(overlay.bundle.count == 1 && texts.last == .some(nil))
        overlay.noteBox(Self.box(CGRect(x: 1100, y: 10, width: 100, height: 60), display: 2))
        #expect(overlay.bundle.count == 2 && texts.last == "2 regions")
    }
}
