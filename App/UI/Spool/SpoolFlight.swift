import Foundation

/// V3's continuous mouth → text lines → flattened tape. Geometry is supplied by verified
/// destination rectangles; this renderer never measures, scrolls, writes, or guesses text.
enum SpoolFlight {
    static let samples = 71
    static let ribbonWidth = 6.4
    static let duration = 1.3

    /// Start of an underline centreline in overlay coordinates. A negative width follows RTL.
    struct Line: Equatable, Sendable, Codable {
        var x: Double
        var y: Double
        var width: Double
    }

    struct Frame: Equatable, Sendable {
        var drawing: SpoolDrawing
        var head: Double
        var tail: Double
        var points: [SpoolPoint]
        var flattening: Double
        var linePoints: [[SpoolPoint]]
    }

    static func head(_ t: Double) -> Double { SpoolMath.sm(t / 0.48) }
    static func tail(_ t: Double) -> Double { SpoolMath.sm((t - 0.78) / 0.42) }

    /// Caret-only fallback: no fabricated destination width before verification.
    static func frame(t: Double, from: SpoolPoint, to: SpoolPoint, width: Double, height: Double) -> Frame? {
        frame(t: t, from: from, lines: [Line(x: to.x, y: to.y, width: 0)], width: width, height: height)
    }

    static func frame(t: Double, from: SpoolPoint, lines: [Line], width: Double, height: Double,
                      verified: Bool = false) -> Frame? {
        guard let first = lines.first, t > 0, t < duration else { return nil }
        let to = SpoolPoint(first.x, first.y)
        let bend = SpoolMath.min(100, abs(to.y - from.y) * 0.45)
        var bridge: [SpoolPoint] = []
        for i in 0...64 {
            let u = Double(i) / 64, v = 1 - u, env = SpoolMath.sin(u * .pi)
            let x = v * v * v * from.x + 3 * v * v * u * (from.x + 16)
                + 3 * v * u * u * (to.x + 65) + u * u * u * to.x
                + env * SpoolMath.sin(u * SpoolMath.tau * 1.6 - t * 7) * 8
            let y = v * v * v * from.y + 3 * v * v * u * (from.y + bend)
                + 3 * v * u * u * (to.y - 35) + u * u * u * to.y
            bridge.append(SpoolPoint(x, y))
        }
        let head = head(t), tail = tail(t), flat = SpoolMath.sm((t - 0.88) / 0.42)
        let tapeWidth = SpoolMath.mix(ribbonWidth, 2.4, flat)
        var nodes: [SpoolNode] = [], points: [SpoolPoint] = [], linePoints: [[SpoolPoint]] = []
        if head - tail >= 0.008 {
            for i in 0...70 {
                let k = (tail + (head - tail) * Double(i) / 70) * Double(bridge.count - 1)
                let j = Swift.min(bridge.count - 2, Int(k.rounded(.down))), f = k - Double(j)
                points.append(SpoolPoint(SpoolMath.mix(bridge[j].x, bridge[j + 1].x, f),
                                         SpoolMath.mix(bridge[j].y, bridge[j + 1].y, f)))
            }
            nodes.append(TapeRibbon.node(points, width: tapeWidth) { q in
                (1 - flat) * 2.05 * SpoolMath.sin(q * SpoolMath.tau * 1.2 - t * 3.2) * SpoolMath.sin(q * .pi)
            })
        }
        let progress = SpoolMath.sm((t - 0.42) / 0.52) * Double(lines.count)
        for (i, line) in lines.enumerated() {
            let p = SpoolMath.clamp(progress - Double(i))
            guard p > 0, line.width != 0 else { continue }
            let ps = (0...48).map { j -> SpoolPoint in
                let u = Double(j) / 48
                return SpoolPoint(line.x + line.width * u * p,
                                  line.y + (1 - flat) * SpoolMath.sin(u * .pi) * SpoolMath.sin(u * SpoolMath.tau - t * 7) * 3)
            }
            linePoints.append(ps)
            nodes.append(TapeRibbon.node(ps, width: tapeWidth) { q in
                (1 - flat) * 2.05 * SpoolMath.sin(q * .pi * 1.6 - t * 3.2) * SpoolMath.sin(q * .pi)
            })
            if i < lines.count - 1, progress > Double(i + 1), flat < 1 {
                let next = lines[i + 1]
                let ps = (0...40).map { j -> SpoolPoint in
                    let u = Double(j) / 40
                    return SpoolPoint(SpoolMath.mix(line.x + line.width, next.x, SpoolMath.sm(u)),
                                      SpoolMath.mix(line.y, next.y, u) + SpoolMath.sin(u * .pi) * 5)
                }
                nodes.append(.group(attributes: [SpoolAttribute("opacity", number: 1 - flat)], transform: nil,
                                    children: [TapeRibbon.node(ps, width: tapeWidth)]))
            }
        }
        let drawing = SpoolDrawing(viewBox: [0, 0, width, height], attributes: [
            SpoolAttribute("xmlns", "http://www.w3.org/2000/svg"),
            SpoolAttribute("data-handoff", "continuous"),
            SpoolAttribute("data-settle", number: SpoolMath.fixed2(flat)),
            SpoolAttribute("data-verified", verified ? "true" : "false"),
        ], nodes: nodes)
        return Frame(drawing: drawing, head: head, tail: tail, points: points, flattening: flat, linePoints: linePoints)
    }
}
