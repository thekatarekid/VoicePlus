import CoreGraphics
import CoreVideo
import Foundation

// V5 LR2/LR3 — the mouth region Auto-AVSR reads: an 88×88 grayscale crop centred on the lips,
// sampled straight out of the camera frame inside the capture callback. Only these 7.7 KB crops are
// kept (a 1 s pre-roll, or the current utterance — `CropRetention`, LR5); the camera frame itself is
// released when the callback returns (LR5).

/// An 8-bit grayscale image, row-major, origin top-left.
public struct GrayImage: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var pixels: [UInt8]
    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height)
        self.width = width; self.height = height; self.pixels = pixels
    }
}

public enum MouthCropper {
    /// Auto-AVSR's input side (96 crop, 88 centre-crop at inference).
    public static let side = 88
    /// The crop square is this many times the larger lip dimension.
    public static let scale: CGFloat = 1.8

    /// The crop square in **pixel** coordinates (origin top-left) for a mouth rect in Vision's
    /// normalized coordinates (origin bottom-left). nil when the rect is degenerate.
    public static func cropSquare(mouthRect r: CGRect, imageWidth w: Int, imageHeight h: Int) -> CGRect? {
        guard r.width > 0, r.height > 0, w > 0, h > 0 else { return nil }
        let cx = r.midX * CGFloat(w), cy = (1 - r.midY) * CGFloat(h)
        let size = max(r.width * CGFloat(w), r.height * CGFloat(h)) * scale
        guard size >= 4 else { return nil }
        return CGRect(x: cx - size / 2, y: cy - size / 2, width: size, height: size)
    }

    /// Bilinear resample of `square` into `side`×`side`, reading luminance through `luma(x, y)`
    /// (clamped to the image). Shared by the gray-image and pixel-buffer paths.
    static func resample(square: CGRect, width: Int, height: Int, side: Int,
                         luma: (Int, Int) -> Float) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: side * side)
        let step = square.width / CGFloat(side)
        for oy in 0..<side {
            let sy = Float(square.minY + (CGFloat(oy) + 0.5) * step - 0.5)
            let y0 = Int(floor(sy)), fy = sy - Float(y0)
            for ox in 0..<side {
                let sx = Float(square.minX + (CGFloat(ox) + 0.5) * step - 0.5)
                let x0 = Int(floor(sx)), fx = sx - Float(x0)
                func px(_ x: Int, _ y: Int) -> Float { luma(min(max(x, 0), width - 1), min(max(y, 0), height - 1)) }
                let top = px(x0, y0) * (1 - fx) + px(x0 + 1, y0) * fx
                let bottom = px(x0, y0 + 1) * (1 - fx) + px(x0 + 1, y0 + 1) * fx
                out[oy * side + ox] = UInt8(max(0, min(255, (top * (1 - fy) + bottom * fy).rounded())))
            }
        }
        return out
    }

    public static func crop(_ image: GrayImage, mouthRect: CGRect, side: Int = MouthCropper.side) -> [UInt8]? {
        guard let square = cropSquare(mouthRect: mouthRect, imageWidth: image.width, imageHeight: image.height) else { return nil }
        return resample(square: square, width: image.width, height: image.height, side: side) {
            Float(image.pixels[$1 * image.width + $0])
        }
    }

    /// Crop straight from a camera frame (32BGRA or a bi-planar 420 luma plane). The buffer is
    /// locked read-only for the duration of the call and not retained.
    public static func crop(_ buffer: CVPixelBuffer, mouthRect: CGRect, side: Int = MouthCropper.side) -> [UInt8]? {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        switch format {
        case kCVPixelFormatType_32BGRA:
            let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
            guard let base = CVPixelBufferGetBaseAddress(buffer),
                  let square = cropSquare(mouthRect: mouthRect, imageWidth: w, imageHeight: h) else { return nil }
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            let p = base.assumingMemoryBound(to: UInt8.self)
            return resample(square: square, width: w, height: h, side: side) { x, y in
                let o = y * stride + x * 4
                return 0.114 * Float(p[o]) + 0.587 * Float(p[o + 1]) + 0.299 * Float(p[o + 2])
            }
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            let w = CVPixelBufferGetWidthOfPlane(buffer, 0), h = CVPixelBufferGetHeightOfPlane(buffer, 0)
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
                  let square = cropSquare(mouthRect: mouthRect, imageWidth: w, imageHeight: h) else { return nil }
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let p = base.assumingMemoryBound(to: UInt8.self)
            return resample(square: square, width: w, height: h, side: side) { x, y in Float(p[y * stride + x]) }
        default:
            return nil
        }
    }
}
