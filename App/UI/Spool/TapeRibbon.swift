import Foundation

/// S1 — the prototype's `tapeRibbon(points, width, rollAt)`: a filled flat ribbon, not a stroked cable
/// (design §3.1).
///
/// Each sample gets a top and bottom edge at `± width/2 · cos(roll)` along the local normal, so a twist
/// turns the strip edge-on and the edges cross. Flat quads between samples use the reverse colour
/// where `cos` of the mean roll is negative. Highlights sit on the cut edges: the top edge in the edge
/// colour (0.65, 85 %), the bottom edge in shadow (0.8), three faint grain lanes at ±0.28 and centre
/// (0.3, 22 %), and an end cap in the edge colour.
enum TapeRibbon {
    struct Edge: Equatable, Sendable {
        var point: SpoolPoint
        var roll: Double
        var top: SpoolPoint
        var bottom: SpoolPoint
    }

    /// The projected edges, one per sample.
    static func edges(_ points: [SpoolPoint], width: Double, roll: (Double) -> Double = { _ in 0 }) -> [Edge] {
        let last = points.count - 1
        return points.indices.map { i in
            let p = points[i]
            let prev = points[Swift.max(0, i - 1)], next = points[Swift.min(last, i + 1)]
            let dx = next.x - prev.x, dy = next.y - prev.y
            var length = SpoolMath.hypot(dx, dy)
            if length == 0 || length.isNaN { length = 1 }
            let r = roll(Double(i) / Double(last))
            let w = width * 0.5 * SpoolMath.cos(r)
            return Edge(point: p, roll: r,
                        top: SpoolPoint(p.x + dy / length * w, p.y - dx / length * w),
                        bottom: SpoolPoint(p.x - dy / length * w, p.y + dx / length * w))
        }
    }

    static func node(_ points: [SpoolPoint], width: Double, roll: (Double) -> Double = { _ in 0 }) -> SpoolNode {
        let edges = edges(points, width: width, roll: roll)
        var children: [SpoolNode] = []
        children.reserveCapacity(edges.count + 5)
        for i in 0 ..< Swift.max(0, edges.count - 1) {
            let a = edges[i], z = edges[i + 1]
            let back = SpoolMath.cos((a.roll + z.roll) * 0.5) < 0
            let colour = SpoolPaint.hex(back ? SpoolPalette.tapeBack : SpoolPalette.tapeFace)
            children.append(.path(data: .polyline([a.top, z.top, z.bottom, a.bottom], closed: true),
                                  fill: colour, stroke: colour, strokeWidth: 0.35, extra: []))
        }
        children.append(.path(data: .polyline(edges.map(\.top)), fill: .none, stroke: .hex(SpoolPalette.tapeEdge),
                              strokeWidth: 0.65, extra: [SpoolAttribute("opacity", ".85")]))
        children.append(.path(data: .polyline(edges.map(\.bottom)), fill: .none, stroke: .hex(SpoolPalette.tapeShadow),
                              strokeWidth: 0.8, extra: []))
        for lane in [-0.28, 0, 0.28] {
            let t = 0.5 + lane
            let lanePoints = edges.map {
                SpoolPoint(SpoolMath.mix($0.top.x, $0.bottom.x, t), SpoolMath.mix($0.top.y, $0.bottom.y, t))
            }
            children.append(.path(data: .polyline(lanePoints), fill: .none, stroke: .hex(SpoolPalette.tapeShadow),
                                  strokeWidth: 0.3, extra: [SpoolAttribute("opacity", ".22")]))
        }
        if let first = edges.first {
            children.append(.path(data: .polyline([first.top, first.bottom]), fill: .none,
                                  stroke: .hex(SpoolPalette.tapeEdge), strokeWidth: 0.7, extra: []))
        }
        return .group(attributes: [SpoolAttribute("data-tape-ribbon", "true")], transform: nil, children: children)
    }
}
