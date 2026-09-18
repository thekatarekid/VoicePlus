import Foundation

/// What drives the pill's tape amplitude.
enum SpoolTapeDrive: Equatable, Sendable {
    /// The prototype's labelled simulation (design §14): live states wave at full amplitude with no
    /// audio at all. Used only to reproduce the golden frames; the product never draws it.
    case simulation
    /// The real product (build doc S1.6 rule 1, design §5 step 2): the prototype's `activity` times the
    /// smoothed capture level, 0…1 (`SpoolLevelSmoother`). Silence flattens the tape; no audio, no wave.
    case capture(level: Double)
}

/// S1 — the pill scene (`scene()`) and the still cameo (`cameo()`) of the prototype (build doc S1.5):
/// the tape lane from the text side to the cassette inlet, the character at the right, the cancelled
/// clip and the editing/notes progress marker.
enum SpoolScene {
    /// One rendered frame and the points hosts need from it, all in viewBox coordinates.
    struct Frame: Equatable, Sendable {
        var drawing: SpoolDrawing
        /// The cassette's tape inlet — where the lane ends.
        var inlet: SpoolPoint
        /// The mouth slot (`data-spool-mouth`), where the tape flight starts.
        var mouth: SpoolPoint
        /// The lane's 97 centre samples (empty for a cameo).
        var lane: [SpoolPoint]
        /// The tape activity this frame used (0 = flat).
        var activity: Double
    }

    // MARK: Geometry (spool_spec.json › sceneGeometry)

    static let height = 164.0
    static let narrowBelow = 460.0
    static let wide = (scale: 1.0, cxFromRight: 78.0, cy: 80.0)
    static let narrow = (scale: 0.69, cxFromRight: 54.0, cy: 74.0)
    static let tapeStart = SpoolPoint(16, 104)
    static let tapeSamples = 97
    static let tapeWidth = 8.0
    static let cameoViewBox: [Double] = [-76, -72, 152, 132]
    /// The cancelled tape retracts over this many seconds.
    static let retractSeconds = 0.32
    /// The editing/notes marker travels at 40 pt/s.
    static let markerSpeed = 40.0

    /// Character centre and scale for a pill `width` pt wide: scale 1 at (width − 78, 80); below 460 pt
    /// scale 0.69 at (width − 54, 74).
    static func placement(width: Double) -> (scale: Double, cx: Double, cy: Double) {
        let narrowLayout = width < narrowBelow
        let g = narrowLayout ? narrow : wide
        return (g.scale, width - g.cxFromRight, g.cy)
    }

    /// `activity`: 1 in live states, `1 − sm(t/0.55)` while finishing, 0 otherwise and in still frames;
    /// multiplied by the capture level in the product.
    static func activity(_ key: SpoolStateKey, t: Double, still: Bool, drive: SpoolTapeDrive) -> Double {
        let settle = key == .finishing ? 1 - SpoolMath.sm(t / 0.55) : 0
        let base: Double = still ? 0 : SpoolPoseTable.isLive(key) ? 1 : settle
        switch drive {
        case .simulation: return base
        case .capture(let level): return base * SpoolMath.clamp(level.isNaN ? 0 : level)
        }
    }

    /// `scene(key, t, id, width, still, angle)`.
    static func frame(_ key: SpoolStateKey, t tIn: Double, width: Double = 560, still: Bool = false, angle angleIn: Double = 0,
                      drive: SpoolTapeDrive, gradientID: String = SpoolRig.defaultGradientID) -> Frame {
        let t = still ? SpoolPoseTable.stillTime(for: key) : tIn
        let angle = still ? 0 : angleIn
        let (scale, cx, cy) = placement(width: width)
        let art = SpoolRig.art(key, t: t, angle: angle, gradientID: gradientID)
        let end = SpoolPoint(cx + art.inlet.x * scale, cy + art.inlet.y * scale)
        let activity = activity(key, t: t, still: still, drive: drive)
        let phase = key == .finishing ? 0 : t * 4

        var lane: [SpoolPoint] = []
        lane.reserveCapacity(tapeSamples)
        for i in 0 ..< tapeSamples {
            let u = Double(i) / Double(tapeSamples - 1)
            let envelope = SpoolMath.sin(u * Double.pi)
            let x = SpoolMath.mix(tapeStart.x, end.x, u)
            var y = SpoolMath.mix(tapeStart.y, end.y, SpoolMath.pow(u, 9))
            y += activity * 10 * envelope * (0.75 * SpoolMath.sin(u * SpoolMath.tau * 1.65 - phase)
                + 0.2 * SpoolMath.sin(u * SpoolMath.tau * 3 - t * 2))
            lane.append(SpoolPoint(x, y))
        }
        let tape = TapeRibbon.node(lane, width: tapeWidth * scale) { u in
            activity * 2.25 * SpoolMath.sin(u * SpoolMath.tau * 1.65 - t * 1.8)
                * SpoolMath.pow(SpoolMath.sin(u * Double.pi), 0.6)
        }

        var nodes: [SpoolNode] = [gradient(gradientID)]
        if key == .cancelled {
            let x = SpoolMath.mix(tapeStart.x, end.x, SpoolMath.sm(t / retractSeconds))
            nodes.append(.clip(id: gradientID + "-retract", x: x, y: 84, width: SpoolMath.max(0, end.x - x), height: 44,
                               children: [tape]))
        } else {
            nodes.append(tape)
        }
        nodes.append(SpoolRig.G(cx, cy, art.nodes, 0, scale))
        if SpoolPoseTable.overlays(for: key).contains(.progressMarker) {
            let x = still ? 180 : tapeStart.x + (t * markerSpeed).truncatingRemainder(dividingBy: end.x - 40)
            nodes.append(SpoolRig.R(x, 101, 18, 6, 1, .hex(SpoolPalette.tapeEdge)))
        }
        let drawing = SpoolDrawing(viewBox: [0, 0, width, height], attributes: [
            SpoolAttribute("aria-hidden", "true"), SpoolAttribute("focusable", "false"),
            SpoolAttribute("xmlns", "http://www.w3.org/2000/svg"),
        ], nodes: nodes)
        return Frame(drawing: drawing, inlet: end, mouth: drawing.anchor(of: SpoolRig.mouthAttribute) ?? end,
                     lane: lane, activity: activity)
    }

    /// `cameo(key, id)`: the still character alone, at t = 1.4 and angle 0, in the viewBox
    /// (−76, −72, 152, 132).
    static func cameo(_ key: SpoolStateKey, gradientID: String = SpoolRig.defaultGradientID) -> Frame {
        let art = SpoolRig.art(key, t: SpoolPoseTable.cameoTime, angle: 0, gradientID: gradientID)
        let drawing = SpoolDrawing(viewBox: cameoViewBox, attributes: [
            SpoolAttribute("aria-hidden", "true"), SpoolAttribute("focusable", "false"),
        ], nodes: [gradient(gradientID)] + art.nodes)
        let inlet = SpoolPoint(art.inlet.x, art.inlet.y)
        return Frame(drawing: drawing, inlet: inlet, mouth: drawing.anchor(of: SpoolRig.mouthAttribute) ?? inlet,
                     lane: [], activity: 0)
    }

    /// `defs(character, id)`: top `shade(+0.38)` → housing at 60 % → `shade(−0.2)`.
    static func gradient(_ id: String) -> SpoolNode {
        .gradient(id: id, top: SpoolPalette.gradientTop, mid: SpoolPalette.housing, bottom: SpoolPalette.gradientBottom)
    }
}
