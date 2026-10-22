import CryptoKit
import Foundation
import Testing
@testable import VoicePlusApp

/// S1 acceptance gate — the Swift Spool port against the verified prototype.
///
/// `Fixtures/spool/spool_golden.json` holds the SHA-256 of every SVG the prototype's Spool module
/// (`docs/design-history/design/design_v3.html`) draws for 624 scene frames (26 states × 11 times × 2 reel angles, plus the
/// 380 pt narrow layout and the still frames), 26 cameos and 8 three-line tape-flight frames. `SpoolSVG` writes
/// the Swift `SpoolDrawing` in the prototype's exact text, so equal hashes mean the same drawing to
/// the last attribute. `spool_spec.json` holds the constants; they must equal the Swift ones.
///
/// Fixtures are regenerated only with `node Scripts/spool_golden.mjs`, never by hand.
/// Scene fixtures supply explicit continuous expression state to V3’s motion-aware rig.
@Suite("Spool parity (S1)")
struct SpoolParityTests {

    static let packageRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url
    }()

    static func data(_ relativePath: String) throws -> Data {
        try Data(contentsOf: packageRoot.appendingPathComponent(relativePath))
    }

    struct SceneEntry: Decodable {
        var key: String
        var t: Double
        var width: Double
        var still: Bool
        var angle: Double
        var motion: SpoolMotionState?
        var sha256: String?
        var svg: String?
    }

    struct CameoEntry: Decodable {
        var key: String
        var sha256: String
    }

    struct FlightEntry: Decodable {
        var t: Double
        var from: [Double]
        var lines: [SpoolFlight.Line]
        var to: [Double] { lines.first.map { [$0.x, $0.y] } ?? [] }
        var w: Double
        var h: Double
        var sha256: String?
        var svg: String?
    }

    struct Golden: Decodable {
        var representative: [SceneEntry]
        var hashes: [SceneEntry]
        var cameos: [CameoEntry]
        var flights: [FlightEntry]
        var flightSample: FlightEntry
    }

    static let golden: Golden = {
        // swiftlint:disable:next force_try
        try! JSONDecoder().decode(Golden.self, from: data("Fixtures/spool/spool_golden.json"))
    }()

    static func spec() throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data("Fixtures/spool/spool_spec.json")) as? [String: Any])
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func key(_ raw: String) throws -> SpoolStateKey {
        try #require(SpoolStateKey(rawValue: raw), "unknown state key \(raw)")
    }

    static func sceneSVG(_ entry: SceneEntry) throws -> String {
        let frame = SpoolScene.frame(try key(entry.key), t: entry.t, width: entry.width, still: entry.still,
                                     angle: entry.angle, drive: .simulation, motion: entry.motion)
        return SpoolSVG.string(frame.drawing)
    }

    static func flightSVG(_ entry: FlightEntry) -> String {
        SpoolSVG.string(SpoolFlight.frame(t: entry.t, from: SpoolPoint(entry.from[0], entry.from[1]),
                                          lines: entry.lines, width: entry.w, height: entry.h))
    }

    /// Where two strings first differ, with a little context from each.
    static func firstDifference(_ swift: String, _ golden: String) -> String {
        let a = Array(swift.utf8), b = Array(golden.utf8)
        var i = 0
        while i < a.count, i < b.count, a[i] == b[i] { i += 1 }
        func slice(_ bytes: [UInt8]) -> String {
            let lo = max(0, i - 80), hi = min(bytes.count, i + 120)
            return String(decoding: bytes[lo..<hi], as: UTF8.self)
        }
        return "first difference at byte \(i)\n  swift : …\(slice(a))…\n  golden: …\(slice(b))…"
    }

    // MARK: - Golden frames

    @Test func everySceneFrameMatchesItsGoldenHash() throws {
        let golden = Self.golden
        #expect(golden.hashes.count == 624)
        var failures: [String] = []
        for entry in golden.hashes {
            let svg = try Self.sceneSVG(entry)
            guard Self.sha256(svg) != entry.sha256 else { continue }
            var report = "\(entry.key) t=\(entry.t) width=\(entry.width) still=\(entry.still) angle=\(entry.angle)"
            if failures.count < 3 {
                report += "\nswift SVG:\n\(svg)"
                if let rep = golden.representative.first(where: { $0.key == entry.key }), let repSVG = rep.svg {
                    report += "\nrepresentative golden SVG for \(entry.key) (t=\(rep.t)):\n\(repSVG)"
                    report += "\nswift at the representative frame vs golden: "
                        + Self.firstDifference(try Self.sceneSVG(rep), repSVG)
                }
                report += "\nRun `node Scripts/spool_golden.mjs --full` and diff this frame in "
                    + "Fixtures/spool/spool_full.local.json for the exact golden SVG."
            }
            failures.append(report)
        }
        #expect(failures.isEmpty, "\(failures.count) of \(golden.hashes.count) frames differ:\n\(failures.prefix(3).joined(separator: "\n\n"))")
    }

    @Test func representativeFramesAreByteIdentical() throws {
        let golden = Self.golden
        #expect(golden.representative.count == 26)
        for entry in golden.representative {
            let expected = try #require(entry.svg)
            let svg = try Self.sceneSVG(entry)
            #expect(svg == expected, "\(entry.key): \(Self.firstDifference(svg, expected))")
        }
    }

    @Test func everyCameoMatchesItsGoldenHash() throws {
        let golden = Self.golden
        #expect(golden.cameos.count == 26)
        for entry in golden.cameos {
            let svg = SpoolSVG.string(SpoolScene.cameo(try Self.key(entry.key)).drawing)
            #expect(Self.sha256(svg) == entry.sha256, "cameo \(entry.key) differs:\n\(svg)")
        }
    }

    @Test func everyFlightFrameMatchesItsGoldenHash() throws {
        let golden = Self.golden
        #expect(golden.flights.count == 8)
        for entry in golden.flights {
            let svg = Self.flightSVG(entry)
            #expect(Self.sha256(svg) == entry.sha256, "flight t=\(entry.t) differs:\n\(svg)")
        }
        let sample = golden.flightSample
        let expected = try #require(sample.svg)
        let svg = Self.flightSVG(sample)
        #expect(svg == expected, "flight sample: \(Self.firstDifference(svg, expected))")
    }

    /// The golden set iterates the prototype's `poses` object, so its order is the prototype's.
    @Test func stateKeysFollowThePrototypeOrder() {
        let order = Self.golden.representative.map(\.key)
        #expect(order == SpoolStateKey.allCases.map(\.rawValue))
    }

    // MARK: - spool_spec.json constants

    @Test func coloursEqualTheSpec() throws {
        let spec = try Self.spec()
        let character = try #require(spec["character"] as? [String: Any])
        #expect(character["color"] as? String == SpoolPalette.housing)
        #expect(character["id"] as? Int == 25)
        let tape = try #require(spec["tape"] as? [String: Any])
        #expect(tape["face"] as? String == SpoolPalette.tapeFace)
        #expect(tape["back"] as? String == SpoolPalette.tapeBack)
        #expect(tape["edge"] as? String == SpoolPalette.tapeEdge)
        #expect(tape["shadow"] as? String == SpoolPalette.tapeShadow)
        let shades = try #require(spec["housingShades"] as? [String: String])
        #expect(shades["gradientTop"] == SpoolPalette.gradientTop)
        #expect(shades["gradientMid"] == SpoolPalette.housing)
        #expect(shades["gradientBottom"] == SpoolPalette.gradientBottom)
        #expect(shades["dark"] == SpoolPalette.dark)
        #expect(shades["light"] == SpoolPalette.light)
        #expect(shades["ink"] == SpoolPalette.ink)
        #expect(shades["cream"] == SpoolPalette.cream)
    }

    @Test func poseTableEqualsTheSpec() throws {
        let spec = try Self.spec()
        let poses = try #require(spec["statePoses"] as? [String: String])
        #expect(poses.count == 26)
        #expect(Set(poses.keys) == Set(SpoolStateKey.allCases.map(\.rawValue)))
        for key in SpoolStateKey.allCases {
            #expect(poses[key.rawValue] == SpoolPoseTable.pose(for: key).rawValue, "\(key)")
        }
        #expect(Set(SpoolStateKey.allCases.map { SpoolPoseTable.pose(for: $0) }) == Set(SpoolPose.allCases))
        let live = try #require(spec["liveStates"] as? [String])
        #expect(Set(live) == Set(SpoolPoseTable.liveStates.map(\.rawValue)))
    }

    @Test func stillTimesEqualTheSpec() throws {
        let still = try #require(try Self.spec()["stillTimes"] as? [String: Double])
        #expect(still["default"] == SpoolPoseTable.defaultStillTime)
        for key in SpoolStateKey.allCases {
            #expect(SpoolPoseTable.stillTime(for: key) == (still[key.rawValue] ?? still["default"]), "\(key)")
        }
        #expect(Set(still.keys.filter { $0 != "default" }) == Set(SpoolPoseTable.stillTimes.keys.map(\.rawValue)))
    }

    @Test func sceneGeometryEqualsTheSpec() throws {
        let geometry = try #require(try Self.spec()["sceneGeometry"] as? [String: Any])
        #expect(geometry["viewBoxHeight"] as? Double == SpoolScene.height)
        let wide = try #require(geometry["wide"] as? [String: Double])
        #expect(wide["scale"] == SpoolScene.wide.scale)
        #expect(wide["cxFromRight"] == SpoolScene.wide.cxFromRight)
        #expect(wide["cy"] == SpoolScene.wide.cy)
        let narrow = try #require(geometry["narrow"] as? [String: Double])
        #expect(narrow["below"] == SpoolScene.narrowBelow)
        #expect(narrow["scale"] == SpoolScene.narrow.scale)
        #expect(narrow["cxFromRight"] == SpoolScene.narrow.cxFromRight)
        #expect(narrow["cy"] == SpoolScene.narrow.cy)
        #expect(geometry["tapeStart"] as? [Double] == [SpoolScene.tapeStart.x, SpoolScene.tapeStart.y])
        #expect(geometry["tapeSamples"] as? Int == SpoolScene.tapeSamples)
        #expect(geometry["tapeWidth"] as? Double == SpoolScene.tapeWidth)
        #expect(geometry["cameoViewBox"] as? [Double] == SpoolScene.cameoViewBox)
        // Placement at the two layouts the goldens cover.
        #expect(SpoolScene.placement(width: 560) == (0.8, 488, 76))
        #expect(SpoolScene.placement(width: 420) == (0.8, 348, 76))
        #expect(SpoolScene.placement(width: 380).scale == 0.65)
    }

    @Test func reelRulesAndTimeRemapsEqualTheSpec() throws {
        let spec = try Self.spec()
        let rules = try #require(spec["reelAngleRules"] as? [String: Any])
        #expect(rules["dtClamp"] as? Double == SpoolReelIntegrator.dtClamp)
        #expect((rules["live"] as? String)?.contains("\(Int(SpoolReelIntegrator.listeningSpeed)) * energy * dt") == true)
        #expect((rules["finishing"] as? String)?.contains("motion.level") == true)
        #expect((rules["inserting"] as? String)?.contains("\(Int(SpoolReelIntegrator.insertingSpeed)) * min(1,t/.12) * dt") == true)
        #expect((rules["inserting"] as? String)?.contains("t < \(SpoolReelIntegrator.insertingWindow)") == true)
        let remap = try #require(spec["timeRemap"] as? [String: String])
        #expect(remap["finishing"] == "min(t * 1.5 / 0.55, 1.5)")
        #expect(remap["inserting"] == "min(t, 1.2)")
        #expect(remap["editing"] == "1.5 (fixed)")
        #expect(SpoolPoseTable.remappedTime(.finishing, 0.11) == 0.11 * 1.5 / 0.55)
        #expect(SpoolPoseTable.remappedTime(.finishing, 2) == 1.5)
        #expect(SpoolPoseTable.remappedTime(.inserting, 3) == 1.2)
        #expect(SpoolPoseTable.remappedTime(.editing, 0.2) == 1.5)
        #expect(SpoolPoseTable.remappedTime(.listening, 7.25) == 7.25)
        let loop = try #require(spec["loopStops"] as? String)
        #expect(loop.contains("before \(SpoolPoseTable.insertingWindow) s"))
        #expect(loop.contains("within \(SpoolPoseTable.settleWindow) s"))
    }
}
