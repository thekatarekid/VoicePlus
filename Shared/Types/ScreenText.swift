#if os(macOS)
import CoreGraphics
import Foundation

/// G0.1 — text read off the screen for a rect (V4.53, Build doc V4 §2 "Screen text").
///
/// The shared seam behind screen capture + OCR. The live implementation (`ScreenTextService`,
/// G2) captures the window under the rect and runs text recognition; tests drive consumers with a
/// fixed reader. What it returns is kept in memory for one turn and never written; the captured
/// frame itself never leaves the service.
public protocol ScreenTextReader {
    /// Lines of text inside `rect` on `display`, in reading order. `rect` and every returned box
    /// are in global screen points (AppKit coordinates, origin bottom-left of the main display).
    func lines(in rect: CGRect, display: CGDirectDisplayID) async throws -> [ScreenTextLine]
}

/// One recognised line.
public struct ScreenTextLine: Codable, Equatable, Sendable {
    public var text: String
    /// Bounding box of the whole line, in screen points.
    public var box: CGRect
    /// Recogniser confidence, 0…1. Clamped on init and on decode; a NaN reads as 0 (untrusted),
    /// never as a confident line.
    public var confidence: Float
    /// Per-character boxes when the recogniser provides them (one per `Character` of `text`);
    /// `nil` when it does not. Used to aim at a word inside the line.
    public var characterBoxes: [CGRect]?

    public init(text: String, box: CGRect, confidence: Float, characterBoxes: [CGRect]? = nil) {
        self.text = text
        self.box = box
        self.confidence = confidence.isNaN ? 0 : min(max(confidence, 0), 1)
        self.characterBoxes = characterBoxes
    }

    private enum CodingKeys: String, CodingKey { case text, box, confidence, characterBoxes }

    /// Decodes through the clamping initializer so a stored or hand-written line cannot carry an
    /// out-of-range confidence.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            text: try c.decode(String.self, forKey: .text),
            box: try c.decode(CGRect.self, forKey: .box),
            confidence: try c.decode(Float.self, forKey: .confidence),
            characterBoxes: try c.decodeIfPresent([CGRect].self, forKey: .characterBoxes)
        )
    }

    /// Below this, a recognised line is shown as uncertain rather than trusted.
    public static let lowConfidenceThreshold: Float = 0.5

    public var isLowConfidence: Bool { confidence < Self.lowConfidenceThreshold }
}

public extension Array where Element == ScreenTextLine {
    /// The lines whose box intersects `rect`, order kept.
    func intersecting(_ rect: CGRect) -> [ScreenTextLine] {
        filter { $0.box.intersects(rect) }
    }

    /// The line whose box contains `point`, if any; the first in reading order wins.
    func line(at point: CGPoint) -> ScreenTextLine? {
        first { $0.box.contains(point) }
    }

    /// Plain text, one line per recognised line.
    var text: String { map(\.text).joined(separator: "\n") }
}
#endif
