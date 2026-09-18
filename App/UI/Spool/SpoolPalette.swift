import Foundation

/// S1 — Spool's pigments, exactly as the prototype writes them (`design/design_v1.html`, Spool module).
///
/// The six material colours come from `Tokens.SpoolMaterial` (design §3.1), spelled in the prototype's
/// letter case because the parity hashes cover the SVG text. The shell's shading steps are computed
/// with the prototype's `shade()` from the housing colour, as `spool_spec.json` › `housingShades`
/// records. The remaining values are the art's own small details (hub, spokes, lamp, brows, label…);
/// they exist only inside the drawing, are pinned by the golden SVG hashes, and are kept here in one
/// place rather than in `DesignTokens.swift` because no other surface may use them.
enum SpoolPalette {
    // Materials (design §3.1 / Tokens.SpoolMaterial).
    static let tapeFace = Tokens.SpoolMaterial.tapeFace.value.hex        // #AD714F
    static let tapeBack = Tokens.SpoolMaterial.tapeReverse.value.hex     // #704A36
    static let tapeEdge = Tokens.SpoolMaterial.tapeEdge.value.hex        // #D3A582
    static let tapeShadow = Tokens.SpoolMaterial.tapeShadow.value.hex    // #573A2B
    static let housing = Tokens.SpoolMaterial.housing.value.hex          // #D6A07D
    static let cream = Tokens.SpoolMaterial.hub.value.hex.lowercased()   // #fff0d2

    // Shell shading (`shade(color, p)`).
    static let gradientTop = shade(housing, 0.38)
    static let gradientBottom = shade(housing, -0.2)
    static let dark = shade(housing, -0.25)
    static let light = shade(housing, 0.5)

    // Art details.
    static let ink = "#34372f"
    static let labelStrip = "#f0dcc1"
    static let labelText = "#665342"
    static let window = "#362f2a"
    static let roller = "#e8d5b6"
    static let inletBlock = "#2c3029"
    static let hub = "#f5e7c9"
    static let spoke = "#745d46"
    static let pupil = "#2f332c"
    static let brow = "#624c3e"
    static let pad = "#e3c4a0"
    static let mouthCavity = "#3c332b"
    static let lip = "#ca8874"
    static let feedSlot = "#342f29"
    static let mouthLine = "#4d382e"
    static let brake = "#cf9286"
    static let lampListening = "#e1b77a"
    static let lampReady = "#b7c999"
    static let lampIdle = "#a29279"
    static let shutterPlate = "#82634f"
    static let closedEye = "#c7a383"
    static let padlock = "#5c493c"
    static let padlockShackle = "#ead4b8"
    static let pauseBars = "#eedabb"

    /// The prototype's `shade(col, p)`: toward white by `p` when positive, toward black by `−p`
    /// otherwise; `Math.round` per channel; lower-case hex.
    static func shade(_ color: String, _ p: Double) -> String {
        let hex = Array(color.dropFirst())
        let channels = stride(from: 0, to: 6, by: 2).map { i -> String in
            let v = Double(Int(String(hex[i ..< i + 2]), radix: 16) ?? 0)
            let value = SpoolMath.round(p > 0 ? SpoolMath.mix(v, 255, p) : v * (1 + p))
            let text = String(Int(value), radix: 16)
            return text.count < 2 ? "0" + text : text
        }
        return "#" + channels.joined()
    }
}
