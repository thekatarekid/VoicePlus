import CoreGraphics
import CoreVideo
import Foundation
import Vision

/// What one camera frame yields: the LR1 scalars, plus (for LR2/LR3) where the mouth is.
public struct FaceAnalysis: Equatable, Sendable {
    public var frame: FaceFrame
    /// The outer-lip bounding box in normalized image coordinates (Vision's: origin bottom-left),
    /// nil when no face.
    public var mouthRect: CGRect?

    public init(frame: FaceFrame, mouthRect: CGRect? = nil) { self.frame = frame; self.mouthRect = mouthRect }
}

/// Turns a camera frame into a `FaceAnalysis`. The pixel buffer is borrowed for the call only.
public protocol FaceLandmarking: Sendable {
    func analyze(_ pixelBuffer: CVPixelBuffer, time: TimeInterval) -> FaceAnalysis
}

/// Pure geometry over Vision's landmark points, split out so it is testable without a camera.
public enum MouthGeometry {
    /// Inner-lip opening ÷ inner-lip width; 0 for degenerate input.
    public static func openness(innerLips points: [CGPoint]) -> Double {
        guard points.count >= 3 else { return 0 }
        let xs = points.map(\.x), ys = points.map(\.y)
        let width = (xs.max()! - xs.min()!), height = (ys.max()! - ys.min()!)
        guard width > 1e-6 else { return 0 }
        return Double(height / width)
    }

    /// Bounding box of landmark points given in face-box-normalized coordinates, mapped into
    /// image-normalized coordinates.
    public static func imageRect(points: [CGPoint], faceBox: CGRect) -> CGRect? {
        guard !points.isEmpty else { return nil }
        let mapped = points.map { CGPoint(x: faceBox.minX + $0.x * faceBox.width, y: faceBox.minY + $0.y * faceBox.height) }
        let xs = mapped.map(\.x), ys = mapped.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }
}

/// Apple Vision face landmarks (`VNDetectFaceLandmarksRequest`). Licence-clean, on-device, no model
/// download. Picks the largest face (the person nearest the screen).
public final class VisionFaceLandmarker: FaceLandmarking, @unchecked Sendable {
    public init() {}

    public func analyze(_ pixelBuffer: CVPixelBuffer, time: TimeInterval) -> FaceAnalysis {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        // Head yaw comes from the face-rectangles request (revision 3 reports yaw/roll/pitch); the
        // landmarks request alone leaves `yaw` nil, which would make "facing the screen" mean only
        // "a face is present". The largest face is detected once and handed to the landmarks pass.
        let rects = VNDetectFaceRectanglesRequest()
        rects.revision = VNDetectFaceRectanglesRequestRevision3
        do { try handler.perform([rects]) } catch { return FaceAnalysis(frame: .noFace(at: time)) }
        guard let detected = (rects.results ?? []).max(by: { $0.boundingBox.visionArea < $1.boundingBox.visionArea }) else {
            return FaceAnalysis(frame: .noFace(at: time))
        }
        let request = VNDetectFaceLandmarksRequest()
        request.inputFaceObservations = [detected]
        try? handler.perform([request])
        guard let face = request.results?.first else {
            return FaceAnalysis(frame: FaceFrame(time: time, facePresent: true, yaw: detected.yaw?.doubleValue))
        }
        let inner = face.landmarks?.innerLips?.normalizedPoints ?? []
        let outer = face.landmarks?.outerLips?.normalizedPoints ?? []
        let open = MouthGeometry.openness(innerLips: inner)
        let mouth = MouthGeometry.imageRect(points: outer.isEmpty ? inner : outer, faceBox: face.boundingBox)
        let frame = FaceFrame(time: time, facePresent: true, mouthOpen: open, yaw: (face.yaw ?? detected.yaw)?.doubleValue)
        return FaceAnalysis(frame: frame, mouthRect: mouth)
    }
}

extension CGRect {
    var visionArea: CGFloat { width * height }
}
