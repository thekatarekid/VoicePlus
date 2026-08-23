import Foundation
import CoreGraphics
import Testing
@testable import VoicePlusApp

@Suite("P4.3 agent cursor model")
struct AgentCursorModelTests {
    @Test func moveSpawnsContinuousTrailAndCaps() {
        var m = AgentCursorModel(position: .zero); m.spawnSpacing = 10; m.maxWisps = 15
        m.move(to: CGPoint(x: 100, y: 0))
        #expect(m.wisps.count == 10)
        #expect(m.position == CGPoint(x: 100, y: 0))
        let xs = m.wisps.map(\.position.x)
        #expect(xs == xs.sorted() && xs.first! >= 0 && xs.last! <= 100)     // along the segment, in order
        m.move(to: CGPoint(x: 100, y: 200))
        #expect(m.wisps.count == 15)                                          // capped, oldest dropped
        #expect(m.wisps.first!.position.y > 0)
    }

    @Test func tickAgesFadesAndCulls() {
        var m = AgentCursorModel(position: .zero); m.wispLifetime = 0.5
        m.move(to: CGPoint(x: 30, y: 0))
        let n = m.wisps.count; #expect(n > 0)
        m.tick(0.25)
        #expect(m.wisps.count == n && m.wisps.allSatisfy { abs($0.alpha - 0.5) < 1e-9 })
        m.tick(0.3)
        #expect(m.wisps.isEmpty)
    }

    @Test func wispsDeterministicPerSeed() {
        var a = AgentCursorModel(seed: 1), b = AgentCursorModel(seed: 1), c = AgentCursorModel(seed: 2)
        for m in [CGPoint(x: 50, y: 50), CGPoint(x: 0, y: 120)] { a.move(to: m); b.move(to: m); c.move(to: m) }
        #expect(a == b); #expect(a != c)
    }

    @Test func glideKeyframesEaseAndClampDuration() {
        let m = AgentCursorModel(position: .zero)
        let k = m.glideKeyframes(to: CGPoint(x: 120, y: 0), steps: 10)
        #expect(k.count == 11 && k.first!.position == .zero && k.last!.position == CGPoint(x: 120, y: 0))
        #expect(abs(k.last!.time - 0.25) < 1e-9)
        #expect(k[1].position.x < 12 && k[5].position.x == 60)                // slow start, symmetric midpoint
        #expect(k[5].glow > k[0].glow && abs(k.last!.glow - 0.6) < 1e-9)
        #expect(m.glideKeyframes(to: CGPoint(x: 1, y: 0)).last!.time == 0.15)
        #expect(m.glideKeyframes(to: CGPoint(x: 5000, y: 0)).last!.time == 0.6)
        let times = k.map(\.time); #expect(times == times.sorted())
    }

    @Test func clickAndTypingKeyframes() {
        let p = CGPoint(x: 3, y: 4)
        let c = AgentCursorModel.clickKeyframes(at: p)
        #expect(c.allSatisfy { $0.position == p } && c.map(\.scale).max()! > 1 && c.map(\.scale).min()! < 1 && c.last!.scale == 1)
        let t = AgentCursorModel.typingKeyframes(at: p, chars: 5)
        #expect(t.count == 6 && t.allSatisfy { $0.position == p } && t[0].glow != t[1].glow)
        #expect(AgentCursorModel.typingKeyframes(at: p, chars: 500).count == 61)
    }
}

@Suite("P4.3 agent cursor layer")
@MainActor
struct AgentCursorLayerTests {
    @Test func layerAnimatesWithoutTouchingPointer() {
        let before = NSEvent.mouseLocation
        let host = CALayer(); host.bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let l = AgentCursorLayer()
        l.attach(to: host); l.attach(to: host)
        #expect(host.sublayers?.count == 1)
        var done = false
        l.glide(to: CGPoint(x: 200, y: 100)) { done = true }
        #expect(l.model.visible && l.model.position == CGPoint(x: 200, y: 100) && !l.model.wisps.isEmpty)
        l.renderWisps()
        l.click(at: CGPoint(x: 200, y: 100))
        l.typing(at: CGPoint(x: 10, y: 10), characters: 3)
        l.highlight(CGRect(x: 0, y: 0, width: 50, height: 20))
        #expect(l.model.position == CGPoint(x: 25, y: 10))
        l.dismiss()
        #expect(!l.model.visible && l.model.wisps.isEmpty && l.root.opacity == 0)
        l.detach()
        #expect(host.sublayers?.isEmpty ?? true)
        #expect(NSEvent.mouseLocation == before)                              // never moves the user's pointer
        _ = done
    }
}
