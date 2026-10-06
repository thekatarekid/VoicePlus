import AppKit

/// S6 — the menu-bar identity (design §4 "Hover presence and menu-bar identity", `DESIGN.md` §8.4).
///
/// The black-and-white cassette-face outline from the prototype's header and `.menu-glyph` button,
/// ported element for element from `Fixtures/spool/spool_spec.json` › `menuGlyph`: a 32 × 24 viewBox, a
/// rounded enclosure (1, 2, 30 × 21, r 4, stroke 1.5), two eye circles (r 4 at (10, 10) and (22, 10),
/// SVG's default stroke of 1) and the smile `M11 17q5 4 10 0`. `fill="none"` throughout: stroke only.
///
/// The prototype sized the SVG box to 18 × 16 pt, which left the 4 : 3 viewBox 13.5 pt tall in a
/// ~24 pt menu bar. The status item now uses a 24 × 18 pt box — exactly 4 : 3, so SVG's default
/// `xMidYMid meet` fits it at one uniform scale (0.75) with no letterboxing. Stroke widths scale with
/// it, exactly as they do in the browser.
///
/// The image is a **template**: macOS draws it white on a dark menu bar and black on a light one.
/// It is never tinted (no `contentTintColor`, no peach), never swapped for an SF symbol or the
/// detailed Spool, and it does not change with state — state is the menu's first line.
public enum MenuBarGlyph {
    /// One element of the glyph, in viewBox units.
    public struct Element: Equatable, Sendable {
        public enum Shape: Equatable, Sendable {
            case roundedRect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, radius: CGFloat)
            case circle(cx: CGFloat, cy: CGFloat, r: CGFloat)
            case path(String)
        }

        public var shape: Shape
        public var strokeWidth: CGFloat
    }

    /// `viewBox="0 0 32 24"`.
    public static let viewBox = CGSize(width: 32, height: 24)
    /// The status-item image size: 24 × 18 pt, the viewBox at 0.75 (the prototype's 18 × 16 pt box
    /// drew the glyph only 13.5 pt tall and left the menu bar's height unused).
    public static let statusItemSize = NSSize(width: 24, height: 18)
    /// The glyph beside "VoicePlus · Ready" in the menu's status line (prototype `.menu-heading svg`).
    public static let menuHeadingSize = NSSize(width: 24, height: 21)
    /// SVG's initial `stroke-width`, which the eyes and the mouth inherit.
    public static let defaultStrokeWidth: CGFloat = 1

    public static let enclosure = Element(shape: .roundedRect(x: 1, y: 2, width: 30, height: 21, radius: 4),
                                          strokeWidth: 1.5)
    public static let eyes = [
        Element(shape: .circle(cx: 10, cy: 10, r: 4), strokeWidth: defaultStrokeWidth),
        Element(shape: .circle(cx: 22, cy: 10, r: 4), strokeWidth: defaultStrokeWidth),
    ]
    public static let mouthPath = "M11 17q5 4 10 0"
    public static let mouth = Element(shape: .path(mouthPath), strokeWidth: defaultStrokeWidth)

    /// Document order, which is also paint order.
    public static let elements: [Element] = [enclosure] + eyes + [mouth]

    // MARK: The prototype's markup

    /// The glyph written as the prototype writes it (`<button class="menu-glyph">` in
    /// `design_v1.html`), so a test can compare the two strings instead of trusting a retyping.
    public static var svg: String {
        var out = "<svg viewBox=\"0 0 \(n(viewBox.width)) \(n(viewBox.height))\" fill=\"none\" aria-hidden=\"true\">"
        for element in elements {
            let width = element.strokeWidth == defaultStrokeWidth ? "" : " stroke-width=\"\(n(element.strokeWidth))\""
            switch element.shape {
            case .roundedRect(let x, let y, let w, let h, let r):
                out += "<rect x=\"\(n(x))\" y=\"\(n(y))\" width=\"\(n(w))\" height=\"\(n(h))\" rx=\"\(n(r))\" stroke=\"currentColor\"\(width)/>"
            case .circle(let cx, let cy, let r):
                out += "<circle cx=\"\(n(cx))\" cy=\"\(n(cy))\" r=\"\(n(r))\" stroke=\"currentColor\"\(width)/>"
            case .path(let d):
                out += "<path d=\"\(d)\" stroke=\"currentColor\"\(width)/>"
            }
        }
        return out + "</svg>"
    }

    private static func n(_ value: CGFloat) -> String {
        value == value.rounded() ? String(Int(value)) : String(Double(value))
    }

    // MARK: Geometry

    /// `xMidYMid meet`: the largest uniform scale that fits the viewBox in `size`, centred.
    public static func fit(in size: CGSize) -> (scale: CGFloat, offset: CGPoint) {
        let scale = min(size.width / viewBox.width, size.height / viewBox.height)
        return (scale, CGPoint(x: (size.width - viewBox.width * scale) / 2,
                               y: (size.height - viewBox.height * scale) / 2))
    }

    /// The element's outline in viewBox units (y down, as in SVG).
    public static func path(for element: Element) -> CGPath {
        switch element.shape {
        case .roundedRect(let x, let y, let w, let h, let r):
            return CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h),
                          cornerWidth: r, cornerHeight: r, transform: nil)
        case .circle(let cx, let cy, let r):
            return CGPath(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r), transform: nil)
        case .path(let d):
            return SVGPathData.path(d)
        }
    }

    // MARK: Drawing

    /// Strokes the glyph into `context`, fitted to `size`. The context must be y-down (a flipped
    /// `NSImage` drawing handler is). Black on transparent: a template image uses only the alpha.
    public static func draw(in context: CGContext, size: CGSize) {
        let (scale, offset) = fit(in: size)
        context.saveGState()
        context.translateBy(x: offset.x, y: offset.y)
        context.scaleBy(x: scale, y: scale)
        context.setStrokeColor(NSColor.black.cgColor)
        // SVG defaults: butt caps, miter joins.
        context.setLineCap(.butt)
        context.setLineJoin(.miter)
        for element in elements {
            context.addPath(path(for: element))
            context.setLineWidth(element.strokeWidth)
            context.strokePath()
        }
        context.restoreGState()
    }

    /// The template image. Drawn by a handler, so every backing scale (1×, 2×, 3×) is rendered from
    /// the vector outline rather than resampled from one bitmap.
    public static func image(size: NSSize = statusItemSize) -> NSImage {
        let image = NSImage(size: size, flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            context.translateBy(x: rect.minX, y: rect.minY)
            draw(in: context, size: rect.size)
            context.restoreGState()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "VoicePlus"
        return image
    }
}

/// The subset of SVG path data the glyph uses (`M m L l Q q Z z`), turned into a `CGPath`. Kept to
/// what the prototype draws; anything else is a programming error caught by the glyph tests.
enum SVGPathData {
    enum Command: Equatable {
        case move(CGPoint)
        case line(CGPoint)
        case quad(control: CGPoint, end: CGPoint)
        case close
    }

    /// Absolute commands, relative forms resolved against the current point.
    static func commands(_ d: String) -> [Command] {
        var tokens = tokenize(d)[...]
        var out: [Command] = []
        var current = CGPoint.zero
        var start = CGPoint.zero
        var command: Character = "M"

        func number() -> CGFloat? {
            guard case .number(let value)? = tokens.first else { return nil }
            tokens.removeFirst()
            return value
        }
        func point(relative: Bool) -> CGPoint? {
            guard let x = number(), let y = number() else { return nil }
            return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
        }

        while let token = tokens.first {
            if case .command(let c) = token {
                command = c
                tokens.removeFirst()
                if c == "Z" || c == "z" {
                    out.append(.close)
                    current = start
                    continue
                }
            }
            let relative = command.isLowercase
            switch command.uppercased() {
            case "M":
                guard let p = point(relative: relative) else { return out }
                out.append(.move(p))
                current = p
                start = p
                // Further pairs after a moveto are implicit linetos.
                command = relative ? "l" : "L"
            case "L":
                guard let p = point(relative: relative) else { return out }
                out.append(.line(p))
                current = p
            case "Q":
                guard let control = point(relative: relative), let end = point(relative: relative) else { return out }
                out.append(.quad(control: control, end: end))
                current = end
            default:
                return out
            }
        }
        return out
    }

    static func path(_ d: String) -> CGPath {
        let path = CGMutablePath()
        for command in commands(d) {
            switch command {
            case .move(let p): path.move(to: p)
            case .line(let p): path.addLine(to: p)
            case .quad(let control, let end): path.addQuadCurve(to: end, control: control)
            case .close: path.closeSubpath()
            }
        }
        return path
    }

    private enum Token: Equatable {
        case command(Character)
        case number(CGFloat)
    }

    private static func tokenize(_ d: String) -> [Token] {
        var tokens: [Token] = []
        var buffer = ""
        func flush() {
            if let value = Double(buffer) { tokens.append(.number(CGFloat(value))) }
            buffer = ""
        }
        for character in d {
            if "MmLlQqZz".contains(character) {
                flush()
                tokens.append(.command(character))
            } else if character == "-" {
                flush()
                buffer = "-"
            } else if character.isNumber || character == "." {
                buffer.append(character)
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }
}
