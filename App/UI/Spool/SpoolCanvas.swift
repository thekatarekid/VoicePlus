import AppKit
import SwiftUI

/// S1 — maps a drawing's viewBox into a view the way SVG's default `preserveAspectRatio="xMidYMid
/// meet"` does: uniform scale to fit, centred.
struct SpoolViewport: Equatable, Sendable {
    var scale: Double
    var offsetX: Double
    var offsetY: Double

    init(viewBox: [Double], size: CGSize) {
        let vx = viewBox[0], vy = viewBox[1], vw = viewBox[2], vh = viewBox[3]
        let w = Double(size.width), h = Double(size.height)
        guard vw > 0, vh > 0, w > 0, h > 0 else {
            scale = 0
            offsetX = 0
            offsetY = 0
            return
        }
        scale = Swift.min(w / vw, h / vh)
        offsetX = (w - vw * scale) / 2 - vx * scale
        offsetY = (h - vh * scale) / 2 - vy * scale
    }

    func map(_ point: SpoolPoint) -> CGPoint {
        CGPoint(x: offsetX + point.x * scale, y: offsetY + point.y * scale)
    }
}

/// S1 — renders a `SpoolDrawing` with SwiftUI's `GraphicsContext` (the pill's `Canvas`). Same tree the
/// parity tests hash; SVG semantics for transforms (`translate · rotate · scale`), `rx` rounded
/// rectangles, round caps and joins on `P()` paths, element `opacity`, the housing's bounding-box
/// gradient and the cancelled retract clip.
enum SpoolCanvas {
    static func draw(_ drawing: SpoolDrawing, in context: inout GraphicsContext, size: CGSize) {
        let viewport = SpoolViewport(viewBox: drawing.viewBox, size: size)
        guard viewport.scale > 0 else { return }
        var ctx = context
        ctx.translateBy(x: viewport.offsetX, y: viewport.offsetY)
        ctx.scaleBy(x: viewport.scale, y: viewport.scale)
        var gradients: [String: SpoolNode] = [:]
        collectGradients(drawing.nodes, into: &gradients)
        for node in drawing.nodes { draw(node, in: ctx, gradients: gradients) }
    }

    private static func collectGradients(_ nodes: [SpoolNode], into map: inout [String: SpoolNode]) {
        for node in nodes {
            switch node {
            case .gradient(let id, _, _, _): map[id] = node
            case .group(_, _, let children), .clip(_, _, _, _, _, let children): collectGradients(children, into: &map)
            default: continue
            }
        }
    }

    private static func draw(_ node: SpoolNode, in parent: GraphicsContext, gradients: [String: SpoolNode]) {
        var ctx = parent
        switch node {
        case let .path(data, fill, stroke, width, extra):
            apply(opacity: extra, to: &ctx)
            let path = SpoolPathGeometry.path(data)
            fillShape(path, fill, in: ctx, gradients: gradients)
            strokeShape(path, stroke, width: width, round: true, in: ctx)
        case let .ellipse(cx, cy, rx, ry, fill, extra):
            apply(opacity: extra, to: &ctx)
            let path = Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
            fillShape(path, fill, in: ctx, gradients: gradients)
            strokeShape(path, stroke(extra), width: extra["stroke-width"]?.numberValue ?? 1, round: false, in: ctx)
        case let .rect(x, y, width, height, radius, fill, extra):
            apply(opacity: extra, to: &ctx)
            let rect = CGRect(x: x, y: y, width: width, height: height)
            let r = Swift.min(radius, width / 2, height / 2)
            let path = Path(roundedRect: rect, cornerSize: CGSize(width: r, height: r), style: .circular)
            fillShape(path, fill, in: ctx, gradients: gradients)
            strokeShape(path, stroke(extra), width: extra["stroke-width"]?.numberValue ?? 1, round: false, in: ctx)
        case let .text(x, y, content, size, fill, extra):
            guard case .hex(let hex) = fill, let colour = color(hex) else { return }
            let spacing = extra["letter-spacing"]?.numberValue ?? 0
            let resolved = ctx.resolve(Text(content).font(.system(size: size)).tracking(spacing).foregroundColor(colour))
            let measured = resolved.measure(in: CGSize(width: 1000, height: 1000))
            let baseline = resolved.firstBaseline(in: measured)
            ctx.draw(resolved, in: CGRect(x: x, y: y - baseline, width: measured.width, height: measured.height))
        case let .group(_, transform, children):
            if let transform {
                ctx.translateBy(x: transform.x, y: transform.y)
                ctx.rotate(by: .degrees(transform.rotation))
                ctx.scaleBy(x: transform.scale, y: transform.scale)
            }
            for child in children { draw(child, in: ctx, gradients: gradients) }
        case .gradient:
            return
        case let .clip(_, x, y, width, height, children):
            ctx.clip(to: Path(CGRect(x: x, y: y, width: width, height: height)))
            for child in children { draw(child, in: ctx, gradients: gradients) }
        }
    }

    private static func apply(opacity extra: [SpoolAttribute], to ctx: inout GraphicsContext) {
        if let opacity = extra["opacity"]?.numberValue { ctx.opacity *= opacity }
    }

    private static func stroke(_ extra: [SpoolAttribute]) -> SpoolPaint {
        guard let text = extra["stroke"]?.literalValue else { return .none }
        return text == "none" ? .none : .hex(text)
    }

    private static func fillShape(_ path: Path, _ paint: SpoolPaint, in ctx: GraphicsContext, gradients: [String: SpoolNode]) {
        switch paint {
        case .none, .transparent:
            return
        case .hex(let hex):
            if let colour = color(hex) { ctx.fill(path, with: .color(colour)) }
        case .gradient(let id):
            guard case let .gradient(_, top, mid, bottom)? = gradients[id],
                  let c0 = color(top), let c1 = color(mid), let c2 = color(bottom) else { return }
            // objectBoundingBox units: the vector (0,0) → (0.8,1) lives in the unit square of the
            // shape's bounds, so draw the gradient in that space.
            let box = path.boundingRect
            guard box.width > 0, box.height > 0 else { return }
            var inner = ctx
            inner.clip(to: path)
            inner.translateBy(x: box.minX, y: box.minY)
            inner.scaleBy(x: box.width, y: box.height)
            let gradient = Gradient(stops: [.init(color: c0, location: 0), .init(color: c1, location: 0.6), .init(color: c2, location: 1)])
            inner.fill(Path(CGRect(x: 0, y: 0, width: 1, height: 1)),
                       with: .linearGradient(gradient, startPoint: .zero, endPoint: CGPoint(x: 0.8, y: 1)))
        }
    }

    private static func strokeShape(_ path: Path, _ paint: SpoolPaint, width: Double, round: Bool, in ctx: GraphicsContext) {
        guard width > 0, case .hex(let hex) = paint, let colour = color(hex) else { return }
        let style = StrokeStyle(lineWidth: width, lineCap: round ? .round : .butt, lineJoin: round ? .round : .miter)
        ctx.stroke(path, with: .color(colour), style: style)
    }

    /// `#rrggbb` or `#rrggbbaa` in sRGB.
    static func color(_ hex: String) -> Color? {
        guard let rgba = rgba(hex) else { return nil }
        return Color(.sRGB, red: rgba.r, green: rgba.g, blue: rgba.b, opacity: rgba.a)
    }

    static func rgba(_ hex: String) -> (r: Double, g: Double, b: Double, a: Double)? {
        guard hex.hasPrefix("#") else { return nil }
        let digits = hex.dropFirst()
        guard digits.count == 6 || digits.count == 8, let value = UInt64(digits, radix: 16) else { return nil }
        let v = digits.count == 6 ? (value << 8) | 0xFF : value
        return (Double((v >> 24) & 0xFF) / 255, Double((v >> 16) & 0xFF) / 255,
                Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }
}

/// S1 — SVG path data (`M L H V Q Z` and their relative forms) to a SwiftUI `Path`.
enum SpoolPathGeometry {
    static func path(_ data: SpoolPathData) -> Path {
        var path = Path()
        var current = CGPoint.zero, start = CGPoint.zero
        for segment in data.segments {
            let v = segment.values.map { CGFloat($0) }
            let relative = segment.command.isLowercase
            let origin = relative ? current : .zero
            switch Character(segment.command.uppercased()) {
            case "M":
                guard v.count >= 2 else { continue }
                current = CGPoint(x: origin.x + v[0], y: origin.y + v[1])
                start = current
                path.move(to: current)
                // Extra pairs after a moveto are implicit linetos.
                var i = 2
                while i + 1 < v.count {
                    let base = relative ? current : .zero
                    current = CGPoint(x: base.x + v[i], y: base.y + v[i + 1])
                    path.addLine(to: current)
                    i += 2
                }
            case "L":
                var i = 0
                while i + 1 < v.count {
                    let base = relative ? current : .zero
                    current = CGPoint(x: base.x + v[i], y: base.y + v[i + 1])
                    path.addLine(to: current)
                    i += 2
                }
            case "H":
                for x in v {
                    current = CGPoint(x: (relative ? current.x : 0) + x, y: current.y)
                    path.addLine(to: current)
                }
            case "V":
                for y in v {
                    current = CGPoint(x: current.x, y: (relative ? current.y : 0) + y)
                    path.addLine(to: current)
                }
            case "Q":
                var i = 0
                while i + 3 < v.count {
                    let base = relative ? current : .zero
                    let control = CGPoint(x: base.x + v[i], y: base.y + v[i + 1])
                    current = CGPoint(x: base.x + v[i + 2], y: base.y + v[i + 3])
                    path.addQuadCurve(to: current, control: control)
                    i += 4
                }
            case "Z":
                path.closeSubpath()
                current = start
            default:
                continue
            }
        }
        return path
    }
}
