import Foundation

/// S1 — serialises a `SpoolDrawing` to SVG text exactly as the prototype's string builders do: same
/// element order, attribute order, spacing (including the space before `/>` that `P()`, `E()` and `R()`
/// leave when `extra` is empty) and JavaScript number printing. **Test only**: the pill renders with
/// `SpoolCanvas`; this exists so `SpoolParityTests` can hash the Swift drawing against the golden
/// frames generated from `design/design_v3.html`.
enum SpoolSVG {
    static func string(_ drawing: SpoolDrawing) -> String {
        var out = "<svg viewBox=\"" + drawing.viewBox.map(number).joined(separator: " ") + "\""
        for attribute in drawing.attributes { out += " " + attributeText(attribute) }
        out += ">"
        for node in drawing.nodes { write(node, into: &out) }
        return out + "</svg>"
    }

    /// The prototype writes `''` for a flight that is not drawn.
    static func string(_ flight: SpoolFlight.Frame?) -> String {
        flight.map { string($0.drawing) } ?? ""
    }

    static func write(_ node: SpoolNode, into out: inout String) {
        switch node {
        case let .path(data, fill, stroke, width, extra):
            out += "<path d=\"" + pathText(data) + "\" fill=\"" + paint(fill) + "\" stroke=\"" + paint(stroke)
                + "\" stroke-width=\"" + number(width) + "\" stroke-linecap=\"round\" stroke-linejoin=\"round\" "
                + extraText(extra) + "/>"
        case let .ellipse(cx, cy, rx, ry, fill, extra):
            out += "<ellipse cx=\"" + number(cx) + "\" cy=\"" + number(cy) + "\" rx=\"" + number(rx) + "\" ry=\""
                + number(ry) + "\" fill=\"" + paint(fill) + "\" " + extraText(extra) + "/>"
        case let .rect(x, y, width, height, radius, fill, extra):
            out += "<rect x=\"" + number(x) + "\" y=\"" + number(y) + "\" width=\"" + number(width) + "\" height=\""
                + number(height) + "\" rx=\"" + number(radius) + "\" fill=\"" + paint(fill) + "\" " + extraText(extra) + "/>"
        case let .text(x, y, content, size, fill, extra):
            out += "<text x=\"" + number(x) + "\" y=\"" + number(y)
                + "\" font-family=\"-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif\" font-size=\"" + number(size)
                + "\" fill=\"" + paint(fill) + "\" " + extraText(extra) + ">" + escape(content) + "</text>"
        case let .group(attributes, transform, children):
            out += "<g"
            for attribute in attributes { out += " " + attributeText(attribute) }
            if let transform {
                out += " transform=\"translate(" + number(transform.x) + " " + number(transform.y) + ") rotate("
                    + number(transform.rotation) + ") scale(" + number(transform.scale) + ")\""
            }
            out += ">"
            for child in children { write(child, into: &out) }
            out += "</g>"
        case let .gradient(id, top, mid, bottom):
            out += "<defs><linearGradient id=\"" + id + "\" x1=\"0\" y1=\"0\" x2=\".8\" y2=\"1\"><stop stop-color=\"" + top
                + "\"/><stop offset=\".6\" stop-color=\"" + mid + "\"/><stop offset=\"1\" stop-color=\"" + bottom
                + "\"/></linearGradient></defs>"
        case let .clip(id, x, y, width, height, children):
            out += "<defs><clipPath id=\"" + id + "\"><rect x=\"" + number(x) + "\" y=\"" + number(y) + "\" width=\""
                + number(width) + "\" height=\"" + number(height) + "\"/></clipPath></defs><g clip-path=\"url(#" + id + ")\">"
            for child in children { write(child, into: &out) }
            out += "</g>"
        }
    }

    static func pathText(_ data: SpoolPathData) -> String {
        data.segments.map { String($0.command) + $0.values.map(number).joined(separator: " ") }.joined()
    }

    static func paint(_ paint: SpoolPaint) -> String {
        switch paint {
        case .none: return "none"
        case .transparent: return "transparent"
        case .hex(let hex): return hex
        case .gradient(let id): return "url(#" + id + ")"
        }
    }

    static func attributeText(_ attribute: SpoolAttribute) -> String {
        switch attribute.value {
        case .literal(let text): return attribute.name + "=\"" + text + "\""
        case .number(let x): return attribute.name + "=\"" + number(x) + "\""
        }
    }

    static func extraText(_ extra: [SpoolAttribute]) -> String {
        extra.map(attributeText).joined(separator: " ")
    }

    /// The prototype's `esc()`.
    static func escape(_ text: String) -> String {
        var out = ""
        for ch in text {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(ch)
            }
        }
        return out
    }

    /// JavaScript's `Number.prototype.toString()` (ECMA-262 Number::toString): the shortest digits that
    /// round-trip, written in plain decimal for 1e-7 < |x| < 1e21 and `-0` written as `0`.
    static func number(_ x: Double) -> String {
        if x.isNaN { return "NaN" }
        if x == 0 { return "0" }
        if x.isInfinite { return x < 0 ? "-Infinity" : "Infinity" }
        let sign = x < 0 ? "-" : ""
        // Swift's description is also shortest-round-trip; only the layout differs.
        let description = abs(x).description
        var mantissa = Substring(description), exponent = 0
        if let e = description.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = description[..<e]
            exponent = Int(description[description.index(after: e)...].replacingOccurrences(of: "+", with: "")) ?? 0
        }
        var digits = "", pointOffset = 0, seenPoint = false
        for ch in mantissa {
            if ch == "." { seenPoint = true; continue }
            digits.append(ch)
            if !seenPoint { pointOffset += 1 }
        }
        // value = 0.d₁d₂… × 10^n
        var n = pointOffset + exponent
        while digits.hasPrefix("0") { digits.removeFirst(); n -= 1 }
        while digits.hasSuffix("0") { digits.removeLast() }
        let k = digits.count
        if k <= n && n <= 21 {
            return sign + digits + String(repeating: "0", count: n - k)
        }
        if 0 < n && n <= 21 {
            let index = digits.index(digits.startIndex, offsetBy: n)
            return sign + digits[..<index] + "." + digits[index...]
        }
        if -6 < n && n <= 0 {
            return sign + "0." + String(repeating: "0", count: -n) + digits
        }
        let e = n - 1
        let exponentText = (e < 0 ? "-" : "+") + String(abs(e))
        if k == 1 { return sign + digits + "e" + exponentText }
        return sign + String(digits.prefix(1)) + "." + String(digits.dropFirst()) + "e" + exponentText
    }
}
