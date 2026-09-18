import Foundation

/// S1 — Spool's body: an exact port of the prototype's `rig()` case 25 plus the overlays `art()` adds
/// (`design/design_v1.html`, Spool module; build doc S1.1–S1.3). Nothing here is redrawn: every element,
/// coordinate, colour and expression is the prototype's, in the prototype's order.
///
/// `face()`, `glove()`, `limb()` and `lens()` in the prototype belong to earlier mascots and are never
/// called for Spool, so they are not ported.
enum SpoolRig {
    /// The rig's output: the body (one group transformed by `translate(0, lift) rotate(lean)`) and the
    /// tape inlet `(ex, ey)` — the rotated `(−62, 22)` plus lift — where the pill's tape lane must end.
    struct Output: Equatable, Sendable {
        var nodes: [SpoolNode]
        var inlet: SpoolPoint
        var lean: Double
        var lift: Double
    }

    /// The gradient the housing fills with; the SVG writes `url(#id)`.
    static let defaultGradientID = "g"

    /// `rig(character, pose, t, id, angle)`.
    ///
    /// - Parameters:
    ///   - t: seconds in the state **after** the time remap (`SpoolPoseTable.remappedTime`).
    ///   - angle: the accumulated reel angle in degrees (negative = counterclockwise). `nil` uses the
    ///     prototype's built-in fallback, which the pill never does: the host always owns the angle.
    static func rig(pose: SpoolPose, t: Double, angle: Double?, gradientID: String = defaultGradientID) -> Output {
        let listening = pose == .listen, fin = pose == .finish, pre = pose == .preview
        let ins = pose == .insert, rev = pose == .review, err = pose == .error
        let col = SpoolPalette.housing, dark = SpoolPalette.dark, light = SpoolPalette.light
        let inspect = sm(t / 0.7), p = sm(t / 1.5)
        let wind = ins ? sm(t / 0.45) * (1 - sm((t - 0.45) / 0.25)) : 0
        let send = ins ? sm((t - 0.45) / 0.65) : 0
        let land = ins ? sm((t - 1.45) / 0.45) : 0
        let pop = ins ? SpoolMath.sin(SpoolMath.clamp((t - 0.35) / 1.15) * Double.pi) : 0

        let settle = fin ? SpoolMath.exp(-t * 3) * SpoolMath.sin(t * 11) * 2 : 0
        let lean: Double = listening ? SpoolMath.sin(t * 2.3) * 1.6
            : fin ? settle
            : ins ? -3 * wind + 2.2 * pop
            : rev ? -4 * inspect
            : err ? -2 * inspect : 0
        let lift: Double = ins ? 2 * wind - 3 * pop : fin ? 2 * SpoolMath.sin(p * Double.pi) : 0
        let winding = SpoolMath.min(t, 1.5)
        let reelAngle: Double = angle ?? (listening ? -t * 150
            : fin ? -150 * (winding - winding * winding / 3)
            : pre ? -112.5
            : ins ? -112.5 + 472.5 * send : 0)
        let rad = lean * Double.pi / 180
        let ex = -62 * SpoolMath.cos(rad) - 22 * SpoolMath.sin(rad)
        let ey = -62 * SpoolMath.sin(rad) + 22 * SpoolMath.cos(rad) + lift

        var body: [SpoolNode] = []
        // Housing: dark body, gradient face, top highlight and left edge light.
        body.append(R(-63, -58, 126, 108, 13, .hex(dark), [A("stroke", SpoolPalette.ink), A("stroke-width", "2")]))
        body.append(R(-61, -60, 122, 105, 12, .gradient(gradientID), [A("stroke", SpoolPalette.ink), A("stroke-width", "1.6")]))
        body.append(P(Literal.topHighlight, .none, .hex(light), 2, [A("opacity", ".8")]))
        body.append(P(Literal.edgeLight, .none, .hex(light), 1.1, [A("opacity", ".45")]))
        // Write-protect notches, cream top tab, corner screws, SIDE A label, window.
        body.append(R(-42, -64, 23, 5, 2, .hex(dark)))
        body.append(R(19, -64, 23, 5, 2, .hex(dark)))
        body.append(R(-17, -65, 34, 7, 2, .hex(SpoolPalette.cream)))
        body.append(L(-10, -61, 10, -61, dark, 1))
        for x in [-53.0, 53] {
            for y in [-49.0, 35] {
                body.append(C(x, y, 2.5, .hex(light)))
                body.append(L(x - 1, y - 1, x + 1, y + 1, dark, 0.8))
            }
        }
        body.append(R(-47, -54, 94, 9, 2, .hex(SpoolPalette.labelStrip)))
        body.append(T(-40, -47.8, "SIDE A", 5.2, SpoolPalette.labelText, [A("letter-spacing", "1.5")]))
        body.append(T(35, -47.8, "01", 5.2, SpoolPalette.labelText))
        body.append(R(-51, -35, 102, 48, 13, .hex(SpoolPalette.window), [A("stroke", light), A("stroke-width", "1")]))
        // Internal tape from the inlet round the guide to the reels.
        body.append(TapeRibbon.node(internalRibbon, width: 8))
        let rollerY = 19 + (ins ? 1.7 * sm(t / 0.3) * (1 - sm((t - 1.4) / 0.3)) : fin ? p : 0)
        body.append(C(-51, rollerY, 4.2, .hex(SpoolPalette.roller)))
        body.append(C(-51, rollerY, 1.8, .hex(dark)))
        body.append(R(-65, 17, 6, 10, 2, .hex(SpoolPalette.inletBlock)))
        body.append(L(-65, 18, -65, 26, light, 1))

        // Reel eyes.
        let glance: Double = rev ? -3.5 * inspect : ins ? 2 * send : listening ? -1.5 : 0
        let blink: Double = listening
            ? SpoolMath.pow(SpoolMath.max(0, 1 - abs(t.truncatingRemainder(dividingBy: 4.8) - 4.35) / 0.13), 2) : 0
        for side in [-1.0, 1] {
            let x = side * 27, y = -12.0, r = 21.0
            body.append(C(x, y, r, .hex(SpoolPalette.tapeFace),
                          [A("stroke", SpoolPalette.tapeEdge), A("stroke-width", ".7"), A("data-tape-pack", "true")]))
            for rr in [20, 18.6, 17.2, 15.8, 14.4] {
                body.append(C(x, y, rr, .none,
                              [A("stroke", SpoolPalette.tapeShadow), A("stroke-width", ".38"), A("opacity", ".72")]))
            }
            var hub: [SpoolNode] = [C(0, 0, 12.7, .hex(SpoolPalette.hub))]
            for spokeAngle in [0.0, 120, 240] {
                hub.append(G(0, 0, [P(Literal.spoke, .hex(SpoolPalette.spoke), .none, 0)], spokeAngle))
            }
            body.append(G(x, y, hub, reelAngle, leading: [SpoolAttribute("data-reel-spin", number: f(reelAngle))]))
            body.append(C(x + glance, y, 4.8, .hex(SpoolPalette.pupil)))
            body.append(C(x + glance - 1.5, y - 1.6, 1.5, .hex(SpoolPalette.cream)))
            // Eyelids are shutters over the reel windows; hubs stay visible as pupils.
            let lidPose: Double = pre ? 6 : rev ? (side > 0 ? 10 : 0) * inspect : fin ? p * 5 : ins ? 5 * land : 0
            let lid = blink * 32 + lidPose
            if lid > 0 {
                body.append(P(SpoolPathData([
                    .init("M", [x - 21, -34]), .init("H", [x + 21]), .init("V", [-34 + lid]),
                    .init("Q", [x, -29 + lid, x - 21, -34 + lid]), .init("Z"),
                ]), .hex(col), .none, 0))
                body.append(P(SpoolPathData([
                    .init("M", [x - 20, -34 + lid]), .init("Q", [x, -29 + lid, x + 20, -34 + lid]),
                ]), .none, .hex(dark), 1.4))
            }
            let brow: Double = rev ? (side < 0 ? -5 : 3) * inspect
                : err ? side * 3 * inspect
                : fin ? 2 * p
                : pre ? -1
                : ins ? -3 * wind : 0
            body.append(P(SpoolPathData([
                .init("M", [x - 12, -38 + brow]),
                .init("Q", [x, -41 + brow, x + 12, -38 + (err ? -side * 2 : brow)]),
            ]), .none, .hex(SpoolPalette.brow), 2))
            body.append(P(SpoolPathData([.init("M", [x - 14, -24]), .init("q", [4, -6, 10, -6])]),
                          .none, .hex(SpoolPalette.cream), 1.5, [A("opacity", ".28")]))
        }

        // The pressure-pad opening is the mouth.
        body.append(P(Literal.mouthOpening, .hex(dark), .hex(SpoolPalette.ink), 1))
        body.append(R(-22, 21, 44, 13, 5, .hex(SpoolPalette.pad)))
        let mouthY = 27.0
        if listening {
            body.append(E(0, mouthY, 9 + SpoolMath.sin(t * 3) * 1.5, 3.1 + SpoolMath.sin(t * 5) * 0.7, .hex(SpoolPalette.mouthCavity)))
            body.append(P(Literal.listeningLip, .none, .hex(SpoolPalette.lip), 1.7))
        } else if fin {
            body.append(E(0, mouthY, SpoolMath.mix(8, 4, p), SpoolMath.mix(3, 1.7, p), .hex(SpoolPalette.mouthCavity)))
            body.append(L(-12, 24, -9, 24, light, 1))
            body.append(L(9, 24, 12, 24, light, 1))
        } else if ins {
            let opening = sm(t / 0.35) * (1 - sm((t - 1.4) / 0.35))
            body.append(R(-13, mouthY - 3, 26, 5 + 8 * opening, 3, .hex(SpoolPalette.feedSlot)))
            if land > 0.1 { body.append(P(Literal.feedSmile, .none, .hex(SpoolPalette.cream), 1.5)) }
        } else if err {
            body.append(P(SpoolPathData([.init("M", [-7, 29]), .init("Q", [0, 26 - 3 * inspect, 7, 29])]),
                          .none, .hex(SpoolPalette.mouthLine), 2))
        } else if rev {
            body.append(P(SpoolPathData([.init("M", [-8, 27]), .init("Q", [0, 30, 8, 27 - 3 * inspect])]),
                          .none, .hex(SpoolPalette.mouthLine), 2))
        } else {
            body.append(P(Literal.smile, .none, .hex(SpoolPalette.mouthLine), 2))
        }
        // Capstans.
        body.append(C(-39, 27, 3.2, .hex(light)))
        body.append(C(39, 27, 3.2, .hex(light)))
        body.append(C(-39, 27, 1.2, .hex(dark)))
        body.append(C(39, 27, 1.2, .hex(dark)))
        // A mechanical brake closes on errors; the tape is held, never snapped. Status lamp.
        if err {
            body.append(G(-57, 22 - 7 * (1 - inspect), [
                R(-4, -5, 8, 10, 2, .hex(SpoolPalette.brake)), L(-2, 0, 2, 0, SpoolPalette.cream, 1),
            ]))
            body.append(R(21, 40, 10, 3, 1, .hex(SpoolPalette.brake)))
        } else {
            let lamp = listening ? SpoolPalette.lampListening : pre || ins ? SpoolPalette.lampReady : SpoolPalette.lampIdle
            body.append(R(21, 40, 10, 3, 1, .hex(lamp)))
        }
        // Feet and the mouth anchor.
        body.append(R(-43, 44, 20, 6, 3, .hex(dark)))
        body.append(R(23, 44, 20, 6, 3, .hex(dark)))
        body.append(C(0, 31, 0.1, .transparent, [A(mouthAttribute, "true")]))

        return Output(nodes: [G(0, lift, body, lean)], inlet: SpoolPoint(ex, ey), lean: lean, lift: lift)
    }

    /// `art(key, t, id, angle)`: the state's pose at the remapped time, plus its overlays.
    static func art(_ key: SpoolStateKey, t: Double, angle: Double, gradientID: String = defaultGradientID) -> Output {
        var output = rig(pose: SpoolPoseTable.pose(for: key), t: SpoolPoseTable.remappedTime(key, t),
                         angle: angle, gradientID: gradientID)
        let overlays = SpoolPoseTable.overlays(for: key)
        if overlays.contains(.concernedBrows) {
            output.nodes.append(P(Literal.concernedBrows, .none, .hex(SpoolPalette.brow), 2))
        }
        if overlays.contains(.shutterLatch) {
            output.nodes.append(R(-52, -35, 104, 49, 12, .hex(SpoolPalette.shutterPlate)))
            output.nodes.append(L(-40, -8, -14, -8, SpoolPalette.closedEye, 2))
            output.nodes.append(L(14, -8, 40, -8, SpoolPalette.closedEye, 2))
            output.nodes.append(R(-9, 18, 18, 10, 3, .hex(SpoolPalette.padlock)))
            output.nodes.append(P(Literal.padlockShackle, .none, .hex(SpoolPalette.padlockShackle), 1.5))
        }
        if overlays.contains(.pauseBars) {
            output.nodes.append(R(-7, -20, 5, 16, 1, .hex(SpoolPalette.pauseBars)))
            output.nodes.append(R(3, -20, 5, 16, 1, .hex(SpoolPalette.pauseBars)))
        }
        return output
    }

    /// The attribute marking the mouth anchor (`data-spool-mouth`), a 0.1 pt circle at (0, 31).
    static let mouthAttribute = "data-spool-mouth"

    /// The 17-point internal ribbon: inlet (−62, 22) round the guide to the reels.
    static let internalRibbon: [SpoolPoint] = ([
        (-62, 22), (-57, 22), (-53, 22), (-50, 21), (-48, 18), (-48, 13), (-48, 8), (-46, 6), (-42, 6),
        (-36, 7), (-27, 9), (-18, 9), (-9, 9), (0, 9), (9, 9), (18, 9), (27, 9),
    ] as [(Double, Double)]).map { SpoolPoint($0.0, $0.1) }

    enum Literal {
        static let topHighlight = SpoolPathData("M-52 -48Q-52 -52 -45 -52H43")
        static let edgeLight = SpoolPathData("M-56 30V-42")
        static let spoke = SpoolPathData("M-3 -5L-5 -10Q0 -13 5 -10L3 -5Z")
        static let mouthOpening = SpoolPathData("M-27 18H27L35 38H-35Z")
        static let listeningLip = SpoolPathData("M-6 29Q0 27 6 29")
        static let feedSmile = SpoolPathData("M-8 25Q0 33 8 25")
        static let smile = SpoolPathData("M-9 25Q0 34 9 25")
        static let concernedBrows = SpoolPathData("M-38 -40l14 -5M15 -45l15 5")
        static let padlockShackle = SpoolPathData("M-4 20v-6q4 -8 8 0v6")
    }

    // MARK: - The prototype's element helpers

    private static func sm(_ x: Double) -> Double { SpoolMath.sm(x) }
    private static func f(_ x: Double) -> Double { SpoolMath.fixed2(x) }
    private static func A(_ name: String, _ value: String) -> SpoolAttribute { SpoolAttribute(name, value) }

    /// `P(d, fill, stroke, w, extra)`.
    static func P(_ d: SpoolPathData, _ fill: SpoolPaint, _ stroke: SpoolPaint, _ width: Double,
                  _ extra: [SpoolAttribute] = []) -> SpoolNode {
        .path(data: d, fill: fill, stroke: stroke, strokeWidth: width, extra: extra)
    }

    /// `E(x, y, rx, ry, fill, extra)`: centre through `f()`, radii raw.
    static func E(_ x: Double, _ y: Double, _ rx: Double, _ ry: Double, _ fill: SpoolPaint,
                  _ extra: [SpoolAttribute] = []) -> SpoolNode {
        .ellipse(cx: f(x), cy: f(y), rx: rx, ry: ry, fill: fill, extra: extra)
    }

    /// `C(x, y, r, fill, extra)`.
    static func C(_ x: Double, _ y: Double, _ r: Double, _ fill: SpoolPaint, _ extra: [SpoolAttribute] = []) -> SpoolNode {
        E(x, y, r, r, fill, extra)
    }

    /// `R(x, y, w, h, r, fill, extra)`: origin through `f()`, size and radius raw.
    static func R(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ r: Double, _ fill: SpoolPaint,
                  _ extra: [SpoolAttribute] = []) -> SpoolNode {
        .rect(x: f(x), y: f(y), width: w, height: h, radius: r, fill: fill, extra: extra)
    }

    /// `G(x, y, body, a, s)`: translation and rotation through `f()`, scale raw.
    static func G(_ x: Double, _ y: Double, _ children: [SpoolNode], _ a: Double = 0, _ s: Double = 1,
                  leading: [SpoolAttribute] = []) -> SpoolNode {
        .group(attributes: leading, transform: SpoolTransform(x: f(x), y: f(y), rotation: f(a), scale: s), children: children)
    }

    /// `L(x, y, xx, yy, col, w)`: a two-point path, every coordinate through `f()`.
    static func L(_ x: Double, _ y: Double, _ xx: Double, _ yy: Double, _ colour: String, _ width: Double) -> SpoolNode {
        P(SpoolPathData([.init("M", [f(x), f(y)]), .init("L", [f(xx), f(yy)])]), .none, .hex(colour), width)
    }

    /// `T(x, y, s, z, col, extra)`.
    static func T(_ x: Double, _ y: Double, _ content: String, _ size: Double, _ colour: String,
                  _ extra: [SpoolAttribute] = []) -> SpoolNode {
        .text(x: x, y: y, content: content, size: size, fill: .hex(colour), extra: extra)
    }
}
