import Foundation

/// S1 — the primitives Spool is drawn from. `SpoolRig`, `TapeRibbon`, `SpoolScene` and `SpoolFlight`
/// build a `SpoolDrawing`; `SpoolCanvas` renders it with SwiftUI and `SpoolSVG` serialises it for the
/// parity tests. Both read the same tree, so what the tests pin is what the pill draws.
///
/// The tree mirrors the prototype's SVG element for element and attribute for attribute. Numbers are
/// stored as the doubles the prototype prints: values it passes through `f()` are stored already
/// rounded (`SpoolMath.fixed2`), everything else raw.
struct SpoolDrawing: Equatable, Sendable {
    /// `min-x min-y width height`.
    var viewBox: [Double]
    /// Root attributes after `viewBox`, in the prototype's order.
    var attributes: [SpoolAttribute]
    var nodes: [SpoolNode]
}

/// One `name="value"` pair. Literal values keep the prototype's spelling (`".85"`, not `"0.85"`).
struct SpoolAttribute: Equatable, Sendable {
    enum Value: Equatable, Sendable {
        case literal(String)
        case number(Double)
    }

    var name: String
    var value: Value

    init(_ name: String, _ literal: String) {
        self.name = name
        value = .literal(literal)
    }

    init(_ name: String, number: Double) {
        self.name = name
        value = .number(number)
    }

    /// The value read as a number (`".72"` → 0.72), for the renderer.
    var numberValue: Double? {
        switch value {
        case .number(let x): return x
        case .literal(let text): return Double(text)
        }
    }

    var literalValue: String? {
        if case .literal(let text) = value { return text }
        return nil
    }
}

extension Array where Element == SpoolAttribute {
    subscript(_ name: String) -> SpoolAttribute? { first { $0.name == name } }
}

/// A fill or stroke.
enum SpoolPaint: Equatable, Sendable {
    case none
    case transparent
    /// `#rrggbb` or `#rrggbbaa`, kept in the prototype's letter case.
    case hex(String)
    /// `url(#id)` — the housing's linear gradient.
    case gradient(String)
}

/// One path command and its numbers (`M`, `L`, `H`, `V`, `Q`, `Z` and lower-case relative forms).
struct SpoolPathSegment: Equatable, Sendable {
    var command: Character
    var values: [Double]

    init(_ command: Character, _ values: [Double] = []) {
        self.command = command
        self.values = values
    }
}

/// Path data. Literal prototype paths are parsed once; computed ones are built segment by segment.
struct SpoolPathData: Equatable, Sendable {
    var segments: [SpoolPathSegment]

    init(_ segments: [SpoolPathSegment]) { self.segments = segments }

    /// Parses the prototype's compact form (`"M-4 20v-6q4 -8 8 0v6"`). Traps on anything else: the
    /// literals are constants and a typo must fail the first test run.
    init(_ literal: String) {
        var segments: [SpoolPathSegment] = []
        var number = ""
        func flush() {
            guard !number.isEmpty else { return }
            guard let value = Double(number), !segments.isEmpty else { preconditionFailure("Bad path literal: \(literal)") }
            segments[segments.count - 1].values.append(value)
            number = ""
        }
        for ch in literal {
            if ch.isLetter {
                flush()
                segments.append(SpoolPathSegment(ch))
            } else if ch == " " {
                flush()
            } else if ch == "-" {
                flush()
                number = "-"
            } else {
                number.append(ch)
            }
        }
        flush()
        self.segments = segments
    }

    /// A polyline `M p0 L p1 L p2 …`, optionally closed with `Z` (the tape ribbon's `path()`).
    static func polyline(_ points: [SpoolPoint], closed: Bool = false) -> SpoolPathData {
        var segments = points.enumerated().map { index, point in
            SpoolPathSegment(index == 0 ? "M" : "L", [SpoolMath.fixed2(point.x), SpoolMath.fixed2(point.y)])
        }
        if closed { segments.append(SpoolPathSegment("Z")) }
        return SpoolPathData(segments)
    }
}

struct SpoolPoint: Equatable, Sendable {
    var x: Double
    var y: Double

    init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }
}

/// `translate(x y) rotate(a) scale(s)`, applied in that order to the children (SVG semantics).
struct SpoolTransform: Equatable, Sendable {
    var x: Double
    var y: Double
    var rotation: Double
    var scale: Double

    func apply(_ point: SpoolPoint) -> SpoolPoint {
        let radians = rotation * Double.pi / 180
        let sx = point.x * scale, sy = point.y * scale
        let c = Foundation.cos(radians), s = Foundation.sin(radians)
        return SpoolPoint(x + sx * c - sy * s, y + sx * s + sy * c)
    }
}

indirect enum SpoolNode: Equatable, Sendable {
    /// `P()`: always carries fill, stroke, stroke-width and round caps and joins.
    case path(data: SpoolPathData, fill: SpoolPaint, stroke: SpoolPaint, strokeWidth: Double, extra: [SpoolAttribute])
    /// `E()` / `C()`.
    case ellipse(cx: Double, cy: Double, rx: Double, ry: Double, fill: SpoolPaint, extra: [SpoolAttribute])
    /// `R()`.
    case rect(x: Double, y: Double, width: Double, height: Double, radius: Double, fill: SpoolPaint, extra: [SpoolAttribute])
    /// `T()`.
    case text(x: Double, y: Double, content: String, size: Double, fill: SpoolPaint, extra: [SpoolAttribute])
    /// `G()` (with a transform) or a plain `<g …>` wrapper (the tape ribbon's).
    case group(attributes: [SpoolAttribute], transform: SpoolTransform?, children: [SpoolNode])
    /// `defs()`: the housing's linear gradient, `(0,0) → (0.8,1)` in the element's bounding box.
    case gradient(id: String, top: String, mid: String, bottom: String)
    /// The cancelled pill's retract clip: `<defs><clipPath id>…<rect/></clipPath></defs><g clip-path>`.
    case clip(id: String, x: Double, y: Double, width: Double, height: Double, children: [SpoolNode])
}

extension SpoolDrawing {
    /// Depth-first search for the first element carrying `attribute` (e.g. `data-spool-mouth`), with the
    /// transforms of every enclosing group composed, outermost last.
    func transforms(toElementWith attribute: String) -> (node: SpoolNode, chain: [SpoolTransform])? {
        func search(_ nodes: [SpoolNode], _ chain: [SpoolTransform]) -> (SpoolNode, [SpoolTransform])? {
            for node in nodes {
                switch node {
                case .path(_, _, _, _, let extra), .ellipse(_, _, _, _, _, let extra),
                     .rect(_, _, _, _, _, _, let extra), .text(_, _, _, _, _, let extra):
                    if extra[attribute] != nil { return (node, chain) }
                case .group(let attributes, let transform, let children):
                    if attributes[attribute] != nil { return (node, chain) }
                    let inner = transform.map { [$0] + chain } ?? chain
                    if let hit = search(children, inner) { return hit }
                case .clip(_, _, _, _, _, let children):
                    if let hit = search(children, chain) { return hit }
                case .gradient:
                    continue
                }
            }
            return nil
        }
        return search(nodes, []).map { (node: $0.0, chain: $0.1) }
    }

    /// The centre of the element carrying `attribute`, in viewBox coordinates.
    func anchor(of attribute: String) -> SpoolPoint? {
        guard let (node, chain) = transforms(toElementWith: attribute) else { return nil }
        var point: SpoolPoint
        switch node {
        case .ellipse(let cx, let cy, _, _, _, _): point = SpoolPoint(cx, cy)
        case .rect(let x, let y, let w, let h, _, _, _): point = SpoolPoint(x + w / 2, y + h / 2)
        default: return nil
        }
        for transform in chain { point = transform.apply(point) }
        return point
    }
}
