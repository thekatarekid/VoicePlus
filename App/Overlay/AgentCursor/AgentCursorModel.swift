import Foundation
import CoreGraphics

/// Pure state for the agent cursor: where it is, how bright it glows, and the trail of wisp particles
/// it leaves behind. Display-local points (same frame as `InkLayerView`). No AppKit — unit-testable.
/// The cursor is purely visual: it never reads or moves the user's real pointer.
public struct AgentCursorModel: Equatable {
    public struct Wisp: Equatable {
        public var position: CGPoint
        public var velocity: CGVector
        public var age: TimeInterval = 0
        public var lifetime: TimeInterval
        public var size: CGFloat
        public var alpha: Double { max(0, 1 - age / lifetime) }
    }
    public struct Keyframe: Equatable {
        public var time: TimeInterval      // seconds from the animation start
        public var position: CGPoint
        public var glow: Double             // 0…1
        public var scale: CGFloat           // 1 = idle; >1 pulse on click
    }

    public var position: CGPoint
    public var glow: Double = 0.6
    public var scale: CGFloat = 1
    public var visible = false
    public var wisps: [Wisp] = []
    public var wispLifetime: TimeInterval = 0.45
    public var maxWisps = 40
    public var spawnSpacing: CGFloat = 6    // one wisp per N points travelled
    private var distanceSinceSpawn: CGFloat = 0
    private var rng: UInt64

    public init(position: CGPoint = .zero, seed: UInt64 = 0x9E3779B97F4A7C15) { self.position = position; rng = seed }

    /// Advance by `dt`: age/cull wisps and drift them along their velocity.
    public mutating func tick(_ dt: TimeInterval) {
        wisps = wisps.compactMap { w in
            var w = w; w.age += dt
            guard w.age < w.lifetime else { return nil }
            w.position.x += w.velocity.dx * dt; w.position.y += w.velocity.dy * dt
            w.velocity.dx *= 0.92; w.velocity.dy *= 0.92
            return w
        }
    }

    /// Move to `p`, spawning wisps along the travelled segment so the trail is continuous
    /// regardless of frame rate.
    public mutating func move(to p: CGPoint) {
        let dx = p.x - position.x, dy = p.y - position.y
        let dist = (dx * dx + dy * dy).squareRoot()
        if dist > 0 {
            distanceSinceSpawn += dist
            while distanceSinceSpawn >= spawnSpacing {
                distanceSinceSpawn -= spawnSpacing
                let t = 1 - distanceSinceSpawn / dist
                let at = CGPoint(x: position.x + dx * t, y: position.y + dy * t)
                let jitter = CGVector(dx: CGFloat(rand() - 0.5) * 30, dy: CGFloat(rand() - 0.5) * 30)
                wisps.append(Wisp(position: at, velocity: CGVector(dx: -dx / max(dist, 1) * 20 + jitter.dx, dy: -dy / max(dist, 1) * 20 + jitter.dy),
                                  lifetime: wispLifetime, size: 3 + CGFloat(rand()) * 3))
            }
            if wisps.count > maxWisps { wisps.removeFirst(wisps.count - maxWisps) }
        }
        position = p
    }

    /// Keyframes for a glide from the current position to `target`: ease-in-out, glow rising
    /// en route and settling. `duration` scales with distance (120 px ≈ 0.25 s, clamped 0.15–0.6 s).
    public func glideKeyframes(to target: CGPoint, steps: Int = 12) -> [Keyframe] {
        let d = hypot(target.x - position.x, target.y - position.y)
        let duration = min(0.6, max(0.15, Double(d) / 480))
        return (0...steps).map { i in
            let u = Double(i) / Double(steps)
            let e = u < 0.5 ? 2 * u * u : 1 - pow(-2 * u + 2, 2) / 2          // easeInOutQuad
            return Keyframe(time: u * duration,
                            position: CGPoint(x: position.x + (target.x - position.x) * e, y: position.y + (target.y - position.y) * e),
                            glow: 0.6 + 0.4 * sin(u * .pi), scale: 1)
        }
    }

    /// Click pulse: squash to 0.8, overshoot to 1.35 with full glow, settle. 0.28 s total.
    public static func clickKeyframes(at p: CGPoint) -> [Keyframe] {
        [Keyframe(time: 0, position: p, glow: 0.6, scale: 1), Keyframe(time: 0.06, position: p, glow: 1, scale: 0.8),
         Keyframe(time: 0.16, position: p, glow: 1, scale: 1.35), Keyframe(time: 0.28, position: p, glow: 0.6, scale: 1)]
    }

    /// Typing shimmer: glow oscillates while the cursor holds position. `chars` ticks at ~30 cps.
    public static func typingKeyframes(at p: CGPoint, chars: Int) -> [Keyframe] {
        let n = max(1, min(chars, 60))
        return (0...n).map { i in Keyframe(time: Double(i) / 30, position: p, glow: i % 2 == 0 ? 0.5 : 0.95, scale: 1) }
    }

    private mutating func rand() -> Double {          // splitmix64, deterministic per seed
        rng &+= 0x9E3779B97F4A7C15
        var z = rng; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }
}
