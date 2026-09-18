import Foundation

/// S1 — the mouth-to-caret tape flight maths, exactly as the prototype's `flight()` (design §4
/// "Mouth-to-caret tape path", §5 step 6). S4 draws it in a pointer-transparent overlay; S1 owns the
/// geometry so the flight and the pill share one ribbon.
///
/// The leading end grows to the caret (`head = sm(t/0.65)`), then the tail feeds in
/// (`tail = sm((t − 0.72)/0.33)`, gone by 1.05 s). The strip follows a cubic Bézier with
/// `bend = min(110, |dy|·0.46)`, `c1 = from + (24, bend)`, `c2 = to + (max(45, |dx|·0.25), −bend/2)`,
/// sampled 121 times between tail and head, with a lateral wave `sin(πu)·sin(2π·2.2u − 9t)·13` on x
/// (0.4× on y), width 9, roll `2.4·sin(2π·1.8u − 5t)·sin(πu)`.
enum SpoolFlight {
    static let samples = 121
    static let ribbonWidth = 9.0
    /// The flight is finished (tail fully fed) by this time.
    static let duration = 1.05

    struct Frame: Equatable, Sendable {
        var drawing: SpoolDrawing
        /// `head`, 0…1: how far the leading end has travelled.
        var head: Double
        var tail: Double
        /// The strip's centre samples, tail to head, in the overlay's coordinates.
        var points: [SpoolPoint]
    }

    static func head(_ t: Double) -> Double { SpoolMath.sm(t / 0.65) }
    static func tail(_ t: Double) -> Double { SpoolMath.sm((t - 0.72) / 0.33) }

    /// `flight(t, from, to, w, h)`; `nil` where the prototype returns `''` (not started, finished, or
    /// a zero-length strip).
    static func frame(t: Double, from: SpoolPoint, to: SpoolPoint, width: Double, height: Double) -> Frame? {
        let head = head(t), tail = tail(t)
        if t <= 0 || tail >= 1 { return nil }
        let span = head - tail
        if span <= 0.001 { return nil }
        let dy = to.y - from.y, dx = to.x - from.x
        let bend = SpoolMath.min(110, abs(dy) * 0.46)
        let c1 = SpoolPoint(from.x + 24, from.y + bend)
        let c2 = SpoolPoint(to.x + SpoolMath.max(45, abs(dx) * 0.25), to.y - bend * 0.5)
        var points: [SpoolPoint] = []
        points.reserveCapacity(samples)
        for i in 0 ..< samples {
            let u = tail + span * Double(i) / Double(samples - 1), v = 1 - u
            // Left to right, as the prototype sums: ((b0 + b1) + b2) + b3.
            let b0 = v * v * v, b1 = 3 * v * v * u, b2 = 3 * v * u * u, b3 = u * u * u
            var x = b0 * from.x + b1 * c1.x
            x = x + b2 * c2.x
            x = x + b3 * to.x
            var y = b0 * from.y + b1 * c1.y
            y = y + b2 * c2.y
            y = y + b3 * to.y
            let wave = SpoolMath.sin(u * Double.pi) * SpoolMath.sin(u * SpoolMath.tau * 2.2 - t * 9) * 13
            x += wave
            y += wave * 0.4
            points.append(SpoolPoint(x, y))
        }
        let ribbon = TapeRibbon.node(points, width: ribbonWidth) { q in
            2.4 * SpoolMath.sin((tail + span * q) * SpoolMath.tau * 1.8 - t * 5) * SpoolMath.sin((tail + span * q) * Double.pi)
        }
        let drawing = SpoolDrawing(viewBox: [0, 0, width, height], attributes: [
            SpoolAttribute("xmlns", "http://www.w3.org/2000/svg"),
            SpoolAttribute("data-flight-head", number: SpoolMath.fixed2(head)),
            SpoolAttribute("data-caret-x", number: SpoolMath.fixed2(to.x)),
            SpoolAttribute("data-caret-y", number: SpoolMath.fixed2(to.y)),
        ], nodes: [ribbon])
        return Frame(drawing: drawing, head: head, tail: tail, points: points)
    }
}
