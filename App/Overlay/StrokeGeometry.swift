import Foundation
import CoreGraphics

/// Deterministic xorshift PRNG so a stroke's jitter is stable across redraws (and tests).
public struct SeededRandom: Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    public mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
    /// Uniform in -1…1.
    public mutating func signedUnit() -> CGFloat {
        CGFloat(Double(next() % 1_000_001) / 500_000.0 - 1)
    }
}

/// Excalidraw-style stroke: hand-drawn jitter along the path plus taper at both ends, produced as
/// a closed polygon (left edge forwards, right edge backwards) suitable for a filled `CGPath`.
public struct StrokeStyle: Equatable, Sendable {
    public var baseWidth: CGFloat = 4
    /// Max perpendicular jitter in points.
    public var jitter: CGFloat = 0.8
    /// Fraction of the stroke length (0…0.5) over which width ramps from `minWidthFraction` to full.
    public var taperFraction: CGFloat = 0.2
    public var minWidthFraction: CGFloat = 0.15
    public init() {}
}

public enum StrokeGeometry {
    /// Width at `t` (0…1 along the stroke): tapers in over `taperFraction` and out symmetrically.
    public static func width(at t: CGFloat, style: StrokeStyle, pressure: CGFloat = 1) -> CGFloat {
        let edge = min(t, 1 - t)
        let f = style.taperFraction <= 0 ? 1 : min(1, edge / style.taperFraction)
        // ease-out so the tip is pointed but the body reaches full width quickly
        let eased = 1 - (1 - f) * (1 - f)
        let w = style.baseWidth * (style.minWidthFraction + (1 - style.minWidthFraction) * eased)
        return w * max(0.3, pressure)
    }

    /// Resamples so the outline has evenly spaced vertices regardless of input density.
    public static func resample(_ pts: [CGPoint], spacing: CGFloat) -> [CGPoint] {
        guard pts.count > 1, spacing > 0 else { return pts }
        var out = [pts[0]]
        var carry: CGFloat = 0
        for i in 1..<pts.count {
            let a = pts[i - 1], b = pts[i]
            let seg = hypot(b.x - a.x, b.y - a.y)
            guard seg > 0 else { continue }
            var d = spacing - carry
            while d <= seg {
                out.append(CGPoint(x: a.x + (b.x - a.x) * d / seg, y: a.y + (b.y - a.y) * d / seg))
                d += spacing
            }
            carry = seg - (d - spacing)
        }
        if let l = pts.last, out.last != l { out.append(l) }
        return out
    }

    /// Closed outline polygon. Same `seed` + same input ⇒ identical output.
    public static func outline(points: [CGPoint], pressures: [CGFloat]? = nil, style: StrokeStyle = StrokeStyle(),
                               seed: UInt64) -> [CGPoint] {
        let pts = resample(points, spacing: max(2, style.baseWidth * 0.75))
        guard pts.count > 1 else {
            // dot: small circle
            guard let p = pts.first else { return [] }
            let r = style.baseWidth / 2
            return (0..<12).map { i in
                let a = CGFloat(i) / 12 * 2 * .pi
                return CGPoint(x: p.x + cos(a) * r, y: p.y + sin(a) * r)
            }
        }
        var rng = SeededRandom(seed: seed)
        var left: [CGPoint] = [], right: [CGPoint] = []
        let n = pts.count
        for i in 0..<n {
            let prev = pts[max(0, i - 1)], next = pts[min(n - 1, i + 1)]
            var nx = -(next.y - prev.y), ny = next.x - prev.x
            let len = hypot(nx, ny)
            if len > 0 { nx /= len; ny /= len } else { nx = 0; ny = 1 }
            let t = CGFloat(i) / CGFloat(n - 1)
            let pressure: CGFloat = pressures.map { ps in
                guard !ps.isEmpty else { return 1 }
                return ps[min(ps.count - 1, Int(t * CGFloat(ps.count - 1)))]
            } ?? 1
            let half = width(at: t, style: style, pressure: pressure) / 2
            let j = rng.signedUnit() * style.jitter
            let c = CGPoint(x: pts[i].x + nx * j, y: pts[i].y + ny * j)
            left.append(CGPoint(x: c.x + nx * half, y: c.y + ny * half))
            right.append(CGPoint(x: c.x - nx * half, y: c.y - ny * half))
        }
        return left + right.reversed()
    }

    public static func path(outline: [CGPoint]) -> CGPath {
        let p = CGMutablePath()
        guard let f = outline.first else { return p }
        p.move(to: f)
        outline.dropFirst().forEach { p.addLine(to: $0) }
        p.closeSubpath()
        return p
    }

    /// Stable seed from a stroke id so redraws during the drag do not re-roll the jitter.
    public static func seed(for id: UUID) -> UInt64 {
        let u = id.uuid
        return withUnsafeBytes(of: u) { $0.load(as: UInt64.self) }
    }
}

/// Pure scheduling model for the 1.5 s fade: holds fully opaque until `holdUntil`, then ramps to 0.
public struct FadeSchedule: Equatable, Sendable {
    public var start: TimeInterval
    public var hold: TimeInterval
    public var duration: TimeInterval

    public init(start: TimeInterval, hold: TimeInterval = 0, duration: TimeInterval = 1.5) {
        self.start = start; self.hold = hold; self.duration = duration
    }

    public var fadeBegins: TimeInterval { start + hold }
    public var end: TimeInterval { fadeBegins + duration }

    public func opacity(at t: TimeInterval) -> CGFloat {
        if t <= fadeBegins { return 1 }
        if t >= end { return 0 }
        let f = (t - fadeBegins) / duration
        return CGFloat(1 - f * f)   // ease-in: lingers, then drops away
    }

    public func isFinished(at t: TimeInterval) -> Bool { t >= end }

    /// Restart the hold (e.g. stroke extended / re-bound) keeping the same duration.
    public func extended(from t: TimeInterval) -> FadeSchedule { FadeSchedule(start: t, hold: hold, duration: duration) }
}

/// Resolution pulse on a bound region: one scale-up + glow-down cycle.
public struct PulseSpec: Equatable, Sendable {
    public var duration: TimeInterval = 0.45
    public var scale: CGFloat = 1.06
    public var peakOpacity: CGFloat = 0.9
    public var cornerRadius: CGFloat = 6
    public var inset: CGFloat = -3
    public init() {}

    public func frame(for region: CGRect) -> CGRect { region.insetBy(dx: inset, dy: inset) }
}
