import Foundation
#if canImport(CoreImage)
import CoreImage
import CoreGraphics

/// QR rendering via CoreImage's CIQRCodeGenerator. Returns nil if the filter is unavailable (headless CI).
public enum QRCode {
    public static func image(for payload: PairingPayload, scale: CGFloat = 8) -> CGImage? {
        image(for: payload.qrString, scale: scale)
    }

    public static func image(for string: String, scale: CGFloat = 8) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else { return nil }
        return CIContext(options: [.useSoftwareRenderer: true]).createCGImage(out, from: out.extent)
    }

    public static func pngData(for payload: PairingPayload, scale: CGFloat = 8) -> Data? {
        guard let img = image(for: payload, scale: scale) else { return nil }
        let ci = CIImage(cgImage: img)
        return CIContext(options: [.useSoftwareRenderer: true])
            .pngRepresentation(of: ci, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
    }
}
#endif
