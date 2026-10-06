import AppKit
import Foundation
import Testing
@testable import VoicePlusApp

/// S6 — the menu-bar glyph against the verified prototype (`spool_spec.json` › `menuGlyph`, the
/// `.menu-glyph` button in `design_v1.html`), and its rendering at 1× and 2×.
@Suite("Menu-bar glyph (S6)")
struct MenuBarGlyphTests {
    static let packageRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url
    }()

    static func text(_ relativePath: String) throws -> String {
        try String(contentsOf: packageRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: Parity with the prototype

    @Test func constantsEqualTheSpoolSpec() throws {
        let data = try Data(contentsOf: Self.packageRoot.appendingPathComponent("Fixtures/spool/spool_spec.json"))
        let spec = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let glyph = try #require(spec["menuGlyph"] as? [String: Any])

        let viewBox = try #require(glyph["viewBox"] as? [Double])
        #expect(viewBox == [0, 0, Double(MenuBarGlyph.viewBox.width), Double(MenuBarGlyph.viewBox.height)])

        let rect = try #require(glyph["rect"] as? [String: Double])
        guard case .roundedRect(let x, let y, let w, let h, let r) = MenuBarGlyph.enclosure.shape else {
            Issue.record("the enclosure is not a rounded rect")
            return
        }
        #expect(rect["x"] == Double(x) && rect["y"] == Double(y) && rect["w"] == Double(w) && rect["h"] == Double(h))
        #expect(rect["rx"] == Double(r))
        #expect(rect["stroke"] == Double(MenuBarGlyph.enclosure.strokeWidth))

        let eyes = try #require(glyph["eyes"] as? [[String: Double]])
        #expect(eyes.count == MenuBarGlyph.eyes.count)
        for (json, eye) in zip(eyes, MenuBarGlyph.eyes) {
            guard case .circle(let cx, let cy, let r) = eye.shape else {
                Issue.record("an eye is not a circle")
                continue
            }
            #expect(json["cx"] == Double(cx) && json["cy"] == Double(cy) && json["r"] == Double(r))
            // No stroke-width in the spec or the markup: SVG's initial value, 1.
            #expect(eye.strokeWidth == 1)
        }

        #expect(glyph["mouth"] as? String == MenuBarGlyph.mouthPath)
        #expect(MenuBarGlyph.mouth.strokeWidth == 1)
        #expect(glyph["template"] as? Bool == true)
        #expect(MenuBarGlyph.image().isTemplate)
    }

    /// The Swift markup is the prototype's markup, character for character — both the status-bar
    /// button and the header mark the design points at ("the cassette-face outline shown beside
    /// VoicePlus in the document header").
    @Test func markupEqualsThePrototype() throws {
        let html = try Self.text("design/design_v1.html")
        let button = try #require(html.range(of: #"<button class="menu-glyph"[^>]*>(<svg.*?</svg>)</button>"#,
                                             options: .regularExpression))
        let buttonSVG = String(html[button]).replacingOccurrences(of: #"^<button[^>]*>|</button>$"#, with: "",
                                                                  options: .regularExpression)
        #expect(buttonSVG == MenuBarGlyph.svg)

        let mark = try #require(html.range(of: #"<span class="mark">(<svg.*?</svg>)</span>"#, options: .regularExpression))
        let markSVG = String(html[mark]).replacingOccurrences(of: #"^<span[^>]*>|</span>$"#, with: "",
                                                              options: .regularExpression)
        #expect(markSVG == MenuBarGlyph.svg)
        // The prototype's CSS box was `.menu-glyph svg{width:18px;height:16px}`; the status item is
        // deliberately larger — the viewBox at 0.75, filling the menu bar's height.
        #expect(html.contains(".menu-glyph svg{width:18px;height:16px}"))
        #expect(MenuBarGlyph.statusItemSize == NSSize(width: 24, height: 18))
        #expect(html.contains(".menu-heading svg{width:24px;height:21px}"))
        #expect(MenuBarGlyph.menuHeadingSize == NSSize(width: 24, height: 21))
    }

    @Test func mouthPathParsesToTheQuadraticSmile() {
        let commands = SVGPathData.commands(MenuBarGlyph.mouthPath)
        #expect(commands == [.move(CGPoint(x: 11, y: 17)),
                             .quad(control: CGPoint(x: 16, y: 21), end: CGPoint(x: 21, y: 17))])
        // Absolute and relative spellings, implicit linetos and closepath.
        #expect(SVGPathData.commands("M1 2 3 4l1-1Z") == [.move(CGPoint(x: 1, y: 2)), .line(CGPoint(x: 3, y: 4)),
                                                           .line(CGPoint(x: 4, y: 3)), .close])
        #expect(SVGPathData.commands("m1,1 Q2,2 3,3") == [.move(CGPoint(x: 1, y: 1)),
                                                          .quad(control: CGPoint(x: 2, y: 2), end: CGPoint(x: 3, y: 3))])
    }

    /// SVG's default `preserveAspectRatio="xMidYMid meet"`: one uniform scale, centred.
    @Test func fitsTheViewBoxLikeTheBrowser() {
        let status = MenuBarGlyph.fit(in: MenuBarGlyph.statusItemSize)
        #expect(status.scale == 0.75)
        #expect(status.offset == CGPoint(x: 0, y: 0))
        let heading = MenuBarGlyph.fit(in: MenuBarGlyph.menuHeadingSize)
        #expect(heading.scale == 0.75)
        #expect(heading.offset == CGPoint(x: 0, y: 1.5))
    }

    // MARK: Rendering

    /// Draws the template image into a bitmap of `size` points at `scale` pixels per point.
    static func render(scale: Int, size: NSSize = MenuBarGlyph.statusItemSize) throws -> NSBitmapImageRep {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
                                                pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        MenuBarGlyph.image(size: size).draw(in: NSRect(origin: .zero, size: size))
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    static func alpha(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> CGFloat {
        rep.colorAt(x: x, y: y)?.alphaComponent ?? 0
    }

    static func inkedPixels(_ rep: NSBitmapImageRep) -> Int {
        var count = 0
        for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide where alpha(rep, x, y) > 0.05 { count += 1 } }
        return count
    }

    /// A viewBox point → the bitmap pixel it lands on (bitmap rows run top-down).
    static func pixel(_ point: CGPoint, scale: Int) -> (Int, Int) {
        let fit = MenuBarGlyph.fit(in: MenuBarGlyph.statusItemSize)
        return (Int((point.x * fit.scale + fit.offset.x) * CGFloat(scale)),
                Int((point.y * fit.scale + fit.offset.y) * CGFloat(scale)))
    }

    @Test(arguments: [1, 2])
    func rendersNonEmpty(scale: Int) throws {
        let rep = try Self.render(scale: scale)
        #expect(rep.pixelsWide == 24 * scale && rep.pixelsHigh == 18 * scale)
        let inked = Self.inkedPixels(rep)
        #expect(inked > 20 * scale, "the glyph drew \(inked) pixels at \(scale)×")
        // Stroke only: a filled enclosure would ink ~70 % of the box; the outline stays well under.
        #expect(inked < rep.pixelsWide * rep.pixelsHigh * 3 / 4, "the glyph looks filled at \(scale)×")
        let eye = Self.pixel(CGPoint(x: 10, y: 10), scale: scale)
        #expect(Self.alpha(rep, eye.0, eye.1) == 0, "the left eye is filled at \(scale)×")
    }

    /// The silhouette where it matters: the enclosure's edge is inked, the eyes are rings (their
    /// centres are empty), and the face between the eyes is empty.
    @Test func silhouetteIsTheOutline() throws {
        let rep = try Self.render(scale: 2)
        let leftEdge = Self.pixel(CGPoint(x: 1, y: 12.5), scale: 2)
        #expect(Self.alpha(rep, leftEdge.0, leftEdge.1) > 0.5)
        let topEdge = Self.pixel(CGPoint(x: 16, y: 2), scale: 2)
        #expect(Self.alpha(rep, topEdge.0, topEdge.1) > 0.3)
        for eye in [CGPoint(x: 10, y: 10), CGPoint(x: 22, y: 10)] {
            let centre = Self.pixel(eye, scale: 2)
            #expect(Self.alpha(rep, centre.0, centre.1) == 0, "an eye is filled at \(eye)")
            let rim = Self.pixel(CGPoint(x: eye.x - 4, y: eye.y), scale: 2)
            #expect(Self.alpha(rep, rim.0, rim.1) > 0.3, "an eye ring is missing at \(eye)")
        }
        let face = Self.pixel(CGPoint(x: 16, y: 11), scale: 2)
        #expect(Self.alpha(rep, face.0, face.1) == 0)
        // The smile's lowest point: the quadratic's midpoint, (16, 19).
        let smile = Self.pixel(CGPoint(x: 16, y: 19), scale: 2)
        #expect(Self.alpha(rep, smile.0, smile.1) > 0.2)
        // Nothing outside the viewBox: the 0.94 pt band above the enclosure's stroke stays clear.
        for x in 0..<rep.pixelsWide { #expect(Self.alpha(rep, x, 0) == 0) }
    }

    @Test func statusLineGlyphRendersAtItsHeadingSize() throws {
        let rep = try Self.render(scale: 2, size: MenuBarGlyph.menuHeadingSize)
        #expect(Self.inkedPixels(rep) > 60)
    }

    // MARK: The status item uses it, untinted

    @Test func statusItemShowsTheGlyphNeverAnSFSymbolOrATint() throws {
        let source = try Self.text("App/UI/StatusItemController.swift")
        let code = source.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(!code.contains("systemSymbolName"), "the status item still draws an SF symbol")
        #expect(code.contains("MenuBarGlyph.image()"))
        #expect(code.contains("button.contentTintColor = nil"))
        #expect(!code.contains("contentTintColor = ."), "the glyph is tinted")
        #expect(code.contains("button.appearsDisabled = false"))
    }
}
