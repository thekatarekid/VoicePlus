import Foundation
import CoreGraphics

/// Deterministic xorshift PRNG so a box's corner jitter is stable across redraws (and tests).
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

/// G1 — how a drawn box looks (V4.27): an orange 1 px rectangle; hand-drawn corners optional.
public struct RegionStyle: Equatable, Sendable {
    /// Line width in points. 1 — the design's "1 px" (points, as the design measures everything).
    public var lineWidth: CGFloat = 1
    /// Hand-drawn corners: each edge is its own segment whose ends wander and overshoot the corner
    /// by up to this many points. 0 draws a crisp rectangle.
    public var cornerJitter: CGFloat = 0
    public init(lineWidth: CGFloat = 1, cornerJitter: CGFloat = 0) {
        self.lineWidth = lineWidth; self.cornerJitter = cornerJitter
    }

    public static let crisp = RegionStyle()
    public static let handDrawn = RegionStyle(cornerJitter: 2.5)
}

/// Pure geometry for the box overlay. Rects are display-local points (origin bottom-left).
public enum RegionGeometry {
    /// The rect to stroke so a line of `lineWidth` points lands on whole device pixels at `scale`:
    /// edges snapped to the pixel grid, then moved half a line in when the line is an odd number of
    /// pixels wide, so the stroke is never smeared across two pixels.
    public static func pixelAligned(_ rect: CGRect, scale: CGFloat, lineWidth: CGFloat = 1) -> CGRect {
        let s = max(scale, 1)
        let snapped = CGRect(x: (rect.minX * s).rounded() / s, y: (rect.minY * s).rounded() / s,
                             width: (rect.width * s).rounded() / s, height: (rect.height * s).rounded() / s)
        let px = (lineWidth * s).rounded()
        let inset = px.truncatingRemainder(dividingBy: 2) == 1 ? 0.5 / s : 0
        return snapped.insetBy(dx: inset, dy: inset)
    }

    /// The four edges as separate segments (bottom, right, top, left), each running corner to
    /// corner. With jitter, every endpoint is nudged and pushed past its corner by a seeded amount,
    /// which is what makes the corners read as hand-drawn; without it the segments meet exactly.
    public static func edges(of rect: CGRect, style: RegionStyle = .crisp, seed: UInt64) -> [(CGPoint, CGPoint)] {
        let bl = CGPoint(x: rect.minX, y: rect.minY), br = CGPoint(x: rect.maxX, y: rect.minY)
        let tr = CGPoint(x: rect.maxX, y: rect.maxY), tl = CGPoint(x: rect.minX, y: rect.maxY)
        let straight = [(bl, br), (br, tr), (tr, tl), (tl, bl)]
        guard style.cornerJitter > 0 else { return straight }
        var rng = SeededRandom(seed: seed)
        let j = style.cornerJitter
        return straight.map { a, b in
            let dx = b.x - a.x, dy = b.y - a.y
            let len = max(hypot(dx, dy), 0.001)
            let ux = dx / len, uy = dy / len
            // Overshoot past each end along the edge, then wobble across it.
            let overA = abs(rng.signedUnit()) * j, overB = abs(rng.signedUnit()) * j
            let wobA = rng.signedUnit() * j * 0.5, wobB = rng.signedUnit() * j * 0.5
            let start = CGPoint(x: a.x - ux * overA - uy * wobA, y: a.y - uy * overA + ux * wobA)
            let end = CGPoint(x: b.x + ux * overB - uy * wobB, y: b.y + uy * overB + ux * wobB)
            return (start, end)
        }
    }

    /// The stroke path for a box: a closed rectangle when crisp, four open segments when hand-drawn.
    public static func path(for rect: CGRect, style: RegionStyle = .crisp, seed: UInt64) -> CGPath {
        let p = CGMutablePath()
        guard style.cornerJitter > 0 else {
            p.addRect(rect)
            return p
        }
        for (a, b) in edges(of: rect, style: style, seed: seed) {
            p.move(to: a)
            p.addLine(to: b)
        }
        return p
    }

    /// Stable seed from a box id so redraws during the drag do not re-roll the jitter.
    public static func seed(for id: UUID) -> UInt64 {
        let u = id.uuid
        return withUnsafeBytes(of: u) { $0.load(as: UInt64.self) }
    }
}

/// Pure scheduling model for the 1.5 s fade after the utterance: holds fully opaque until
/// `fadeBegins`, then ramps to 0.
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

    /// Restart the hold (e.g. a box re-bound) keeping the same duration.
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
