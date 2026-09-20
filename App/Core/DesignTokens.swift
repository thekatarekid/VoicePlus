import AppKit
import SwiftUI

/// G0.3 — the Spool design system's tokens, and the **only** place in the app a hex colour may be
/// written (`DESIGN.md` §2, §12.4).
///
/// Sources, in the order of authority `DESIGN.md` §0 fixes: the prototype's `:root` / `body.light`
/// CSS custom properties and its `.notch` rules (`design/design_v1.html`), then `design/design_v1.md`
/// §3 (token table, typography, spacing, radii) and §3.1 (the six Spool material tokens, also in
/// `Fixtures/spool/spool_spec.json`). `DesignTokenTests` re-reads all three and fails on any drift.
///
/// Window colours are `NSColor(name:dynamicProvider:)`, so they follow the window's appearance
/// (light, dark, and Increase Contrast) without a second palette. The pill and Spool are always
/// dark / fixed material and never follow the window theme (design §3 "Pill · always dark").
enum Tokens {

    // MARK: - Colour primitives

    /// An sRGB colour exactly as the design writes it (`#RRGGBB`).
    struct RGB: Hashable, Sendable, CustomStringConvertible {
        let red: UInt8
        let green: UInt8
        let blue: UInt8

        init(red: UInt8, green: UInt8, blue: UInt8) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        /// `#RRGGBB` (or `RRGGBB`), any case. Traps on anything else: tokens are constants, and a
        /// typo must fail the first test run rather than render black.
        init(_ hex: String) {
            guard let parsed = RGB(parsing: hex) else { preconditionFailure("Not a #RRGGBB token: \(hex)") }
            self = parsed
        }

        init?(parsing hex: String) {
            var digits = Substring(hex.trimmingCharacters(in: .whitespaces))
            if digits.hasPrefix("#") { digits = digits.dropFirst() }
            guard digits.count == 6, digits.allSatisfy(\.isHexDigit), let value = UInt32(digits, radix: 16) else {
                return nil
            }
            self.init(red: UInt8((value >> 16) & 0xFF), green: UInt8((value >> 8) & 0xFF), blue: UInt8(value & 0xFF))
        }

        /// Upper-case `#RRGGBB`, the form `DESIGN.md` records.
        var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }
        var description: String { hex }

        var nsColor: NSColor {
            NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
        }

        var color: Color { Color(nsColor: nsColor) }

        /// WCAG 2.x relative luminance (sRGB, linearised; 0 = black, 1 = white).
        var relativeLuminance: Double {
            func channel(_ value: UInt8) -> Double {
                let c = Double(value) / 255
                return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
        }

        /// WCAG 2.x contrast ratio, 1…21, symmetric.
        func contrastRatio(against other: RGB) -> Double {
            let a = relativeLuminance, b = other.relativeLuminance
            return (max(a, b) + 0.05) / (min(a, b) + 0.05)
        }
    }

    /// The window theme. The pill has none: it is always dark.
    enum Theme: String, CaseIterable, Sendable {
        case dark, light
    }

    /// Standard, or the system's Increase Contrast (`accessibilityHighContrast*Aqua` appearances).
    enum Contrast: String, CaseIterable, Sendable {
        case standard, increased
    }

    /// What a dynamic colour resolves against.
    struct Appearance: Hashable, Sendable {
        var theme: Theme
        var contrast: Contrast

        static let candidates: [NSAppearance.Name] = [
            .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
        ]

        /// Pure mapping from the best-matching appearance name. `nil` (no match) reads as dark —
        /// the design is dark-first.
        static func resolve(_ name: NSAppearance.Name?) -> Appearance {
            switch name {
            case .some(.aqua): return Appearance(theme: .light, contrast: .standard)
            case .some(.accessibilityHighContrastAqua): return Appearance(theme: .light, contrast: .increased)
            case .some(.accessibilityHighContrastDarkAqua): return Appearance(theme: .dark, contrast: .increased)
            default: return Appearance(theme: .dark, contrast: .standard)
            }
        }

        static func resolve(_ appearance: NSAppearance) -> Appearance {
            resolve(appearance.bestMatch(from: candidates))
        }
    }

    // MARK: - Window colour roles (design §3 token table)

    enum Role: String, CaseIterable, Sendable {
        case canvas, sidebar, surface, elevated
        case ink, secondaryInk
        case separator, controlBorder
        case accent, onAccent
        case ready, attention, uncertainty
        case pill

        /// What a role is drawn as, which decides the contrast it owes (`DESIGN.md` §3.3).
        enum Usage: Sendable {
            /// A background other roles sit on (canvas, sidebar, surface, elevated).
            case background
            /// Text or a glyph that carries meaning: ≥ 4.5 : 1 on every background.
            case text
            /// A line that identifies a control or a state: ≥ 3 : 1 on every background.
            case line
            /// A 1 px rule between regions that are already told apart by space and fill. WCAG
            /// 1.4.11 does not apply; under Increase Contrast it resolves to `controlBorder`.
            case decorativeLine
            /// Text drawn on an `accent` fill only (primary button, selected segment).
            case textOnAccent
            /// The pill's own fill; its inks are `Tokens.Pill`.
            case fixedDark
        }

        var usage: Usage {
            switch self {
            case .canvas, .sidebar, .surface, .elevated: return .background
            case .ink, .secondaryInk, .accent, .ready, .attention, .uncertainty: return .text
            case .controlBorder: return .line
            case .separator: return .decorativeLine
            case .onAccent: return .textOnAccent
            case .pill: return .fixedDark
            }
        }

        /// The prototype's CSS custom property for this role, or `nil` when the role is an
        /// adjustment `DESIGN.md` §3.3 records (it has no prototype counterpart).
        var prototypeVariable: String? {
            switch self {
            case .canvas: return "--bg"
            case .sidebar: return "--side"
            case .surface: return "--surface"
            case .elevated: return "--raised"
            case .ink: return "--ink"
            case .secondaryInk: return "--muted"
            case .separator: return "--line"
            case .accent: return "--accent"
            case .onAccent: return "--accent-ink"
            case .ready: return "--green"
            case .attention: return "--amber"
            case .uncertainty: return "--red"
            case .pill: return "--pill"
            case .controlBorder: return nil
            }
        }

        /// The verified value for a theme at standard contrast — design §3 table / prototype CSS.
        func value(_ theme: Theme) -> RGB {
            switch (self, theme) {
            case (.canvas, .dark): return RGB("#181310")
            case (.canvas, .light): return RGB("#FFF6EE")
            case (.sidebar, .dark): return RGB("#211914")
            case (.sidebar, .light): return RGB("#F4E3D5")
            case (.surface, .dark): return RGB("#2B211B")
            case (.surface, .light): return RGB("#FFFBF7")
            case (.elevated, .dark): return RGB("#382A21")
            case (.elevated, .light): return RGB("#F8EADC")
            case (.ink, .dark): return RGB("#FFF0E3")
            case (.ink, .light): return RGB("#35251C")
            case (.secondaryInk, .dark): return RGB("#C3AA97")
            case (.secondaryInk, .light): return RGB("#786050")
            case (.separator, .dark): return RGB("#554035")
            case (.separator, .light): return RGB("#DFC3AD")
            // Adjusted (DESIGN.md §3.3): the separator mixed toward secondary ink until it reaches
            // 3 : 1 on every background, for lines that identify a control.
            case (.controlBorder, .dark): return RGB("#8A7364")
            case (.controlBorder, .light): return RGB("#967C6B")
            case (.accent, .dark): return RGB("#E9AD83")
            case (.accent, .light): return RGB("#984B23")
            case (.onAccent, .dark): return RGB("#352014")
            case (.onAccent, .light): return RGB("#FFFFFF")
            case (.ready, .dark): return RGB("#69D58B")
            case (.ready, .light): return RGB("#21753D")
            case (.attention, .dark): return RGB("#F0C181")
            case (.attention, .light): return RGB("#86540C")
            case (.uncertainty, .dark): return RGB("#FF8F95")
            case (.uncertainty, .light): return RGB("#B72F40")
            case (.pill, _): return RGB("#080A09")
            }
        }

        /// The value under a given contrast setting. Increase Contrast changes exactly two roles
        /// (`DESIGN.md` §3.3, §6): secondary ink rises to ≥ 7 : 1, and the decorative separator
        /// becomes a real line.
        func value(_ theme: Theme, _ contrast: Contrast) -> RGB {
            guard contrast == .increased else { return value(theme) }
            switch (self, theme) {
            // Secondary ink mixed toward primary ink until ≥ 7 : 1 on every background.
            case (.secondaryInk, .dark): return RGB("#CDB6A4")
            case (.secondaryInk, .light): return RGB("#5A4539")
            case (.separator, _): return Role.controlBorder.value(theme)
            default: return value(theme)
            }
        }

        func value(_ appearance: Appearance) -> RGB { value(appearance.theme, appearance.contrast) }

        /// A dynamic `NSColor` that resolves per drawing appearance.
        var nsColor: NSColor {
            let role = self
            return NSColor(name: NSColor.Name("VoicePlus.\(rawValue)")) { appearance in
                role.value(Appearance.resolve(appearance)).nsColor
            }
        }

        var color: Color { Color(nsColor: nsColor) }
    }

    /// Call-site names for the window colours: `Tokens.Colors.canvas`.
    enum Colors {
        static let canvas = Role.canvas.nsColor
        static let sidebar = Role.sidebar.nsColor
        static let surface = Role.surface.nsColor
        static let elevated = Role.elevated.nsColor
        static let ink = Role.ink.nsColor
        static let secondaryInk = Role.secondaryInk.nsColor
        static let separator = Role.separator.nsColor
        static let controlBorder = Role.controlBorder.nsColor
        static let accent = Role.accent.nsColor
        static let onAccent = Role.onAccent.nsColor
        static let ready = Role.ready.nsColor
        static let attention = Role.attention.nsColor
        static let uncertainty = Role.uncertainty.nsColor
        static let pill = Role.pill.nsColor
    }

    // MARK: - The pill (always dark; prototype `.notch` rules)

    /// The pill never follows the window theme: its inks are the dark values in both themes.
    enum Pill {
        enum Token: String, CaseIterable, Sendable {
            case background, ink, secondaryInk, ready, attention, uncertainty
            case control, controlBorder, primary, onPrimary

            var value: RGB {
                switch self {
                case .background: return RGB("#080A09")      // .notch background
                case .ink: return RGB("#FFF0E3")             // .notch color, .words
                case .secondaryInk: return RGB("#A19387")    // .status, .helper
                case .ready: return RGB("#69D58B")           // idle dot, verified mark
                case .attention: return RGB("#F0C181")       // ⚠ notices
                case .uncertainty: return RGB("#FF8F95")     // .uncertain dotted underline
                case .control: return RGB("#382A21")         // .actions button fill
                case .controlBorder: return RGB("#634B3A")   // .actions button border (decorative)
                case .primary: return RGB("#E9AD83")         // .actions .primary fill
                case .onPrimary: return RGB("#352014")       // .actions .primary label
                }
            }

            var nsColor: NSColor { value.nsColor }
            var color: Color { value.color }
        }

        static let background = Token.background.nsColor
        static let ink = Token.ink.nsColor
        static let secondaryInk = Token.secondaryInk.nsColor
        static let ready = Token.ready.nsColor
        static let attention = Token.attention.nsColor
        static let uncertainty = Token.uncertainty.nsColor
        static let control = Token.control.nsColor
        static let controlBorder = Token.controlBorder.nsColor
        static let primary = Token.primary.nsColor
        static let onPrimary = Token.onPrimary.nsColor
    }

    // MARK: - Spool material (design §3.1; spool_spec.json `tape`, `character`, `housingShades`)

    enum SpoolMaterial: String, CaseIterable, Sendable {
        /// Outside ribbon face, visible internal tape face, wound reel pack fill.
        case tapeFace
        /// Reverse surface exposed by a twist; not a different outside tape colour.
        case tapeReverse
        /// Thin edge reflection on the strip and reel rim.
        case tapeEdge
        /// Fine longitudinal grain, underside edge, subtle winding rings.
        case tapeShadow
        /// Warm cassette shell.
        case housing
        /// Cream hub and pressure-pad hardware, clearly different from the tape.
        case hub

        var value: RGB {
            switch self {
            case .tapeFace: return RGB("#AD714F")
            case .tapeReverse: return RGB("#704A36")
            case .tapeEdge: return RGB("#D3A582")
            case .tapeShadow: return RGB("#573A2B")
            case .housing: return RGB("#D6A07D")
            case .hub: return RGB("#FFF0D2")
            }
        }

        var nsColor: NSColor { value.nsColor }
        var color: Color { value.color }
    }

    // MARK: - Typography (design §3 "Typography")

    struct TypeRole: Hashable, Sendable {
        enum Weight: String, Sendable {
            case regular, medium, semibold

            var nsWeight: NSFont.Weight {
                switch self {
                case .regular: return .regular
                case .medium: return .medium
                case .semibold: return .semibold
                }
            }

            var fontWeight: Font.Weight {
                switch self {
                case .regular: return .regular
                case .medium: return .medium
                case .semibold: return .semibold
                }
            }
        }

        enum Design: String, Sendable {
            /// The system sans-serif (SF Pro). The product's only face for language.
            case system
            /// SF Mono, only where the prototype uses `--mono` (key caps, tags, identifiers).
            case monospaced
        }

        let name: String
        let size: CGFloat
        let lineHeight: CGFloat
        let weight: Weight
        let design: Design
        /// Tabular (fixed-width) digits, for durations, timers and counts that tick.
        let tabularDigits: Bool

        init(_ name: String, size: CGFloat, lineHeight: CGFloat, weight: Weight = .regular,
             design: Design = .system, tabularDigits: Bool = false) {
            self.name = name
            self.size = size
            self.lineHeight = lineHeight
            self.weight = weight
            self.design = design
            self.tabularDigits = tabularDigits
        }

        /// The same role with tabular digits.
        var tabular: TypeRole {
            TypeRole(name + ".tabular", size: size, lineHeight: lineHeight, weight: weight, design: design,
                     tabularDigits: true)
        }

        /// Window text scales with Settings › Appearance › Larger Text; the pill keeps its sizes
        /// and moves overflow to Review instead (design §3).
        func nsFont(scale: CGFloat = 1) -> NSFont {
            let pointSize = size * scale
            switch design {
            case .monospaced:
                return NSFont.monospacedSystemFont(ofSize: pointSize, weight: weight.nsWeight)
            case .system:
                return tabularDigits
                    ? NSFont.monospacedDigitSystemFont(ofSize: pointSize, weight: weight.nsWeight)
                    : NSFont.systemFont(ofSize: pointSize, weight: weight.nsWeight)
            }
        }

        func font(scale: CGFloat = 1) -> Font {
            let base = Font.system(size: size * scale, weight: weight.fontWeight,
                                   design: design == .monospaced ? .monospaced : .default)
            return tabularDigits ? base.monospacedDigit() : base
        }

        /// Extra leading that brings the face's natural line height up to `lineHeight` — the value
        /// for SwiftUI `.lineSpacing(_:)` and `NSParagraphStyle.lineSpacing`.
        func lineSpacing(scale: CGFloat = 1) -> CGFloat {
            let font = nsFont(scale: scale)
            let natural = font.ascender - font.descender + font.leading
            return max(0, lineHeight * scale - natural)
        }

        /// A paragraph style whose lines are exactly `lineHeight` tall.
        func paragraphStyle(scale: CGFloat = 1) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.minimumLineHeight = lineHeight * scale
            style.maximumLineHeight = lineHeight * scale
            return style
        }
    }

    enum Typography {
        /// Page title — one per window page (design "app title").
        static let title = TypeRole("title", size: 24, lineHeight: 30, weight: .semibold)
        /// Section / group heading.
        static let section = TypeRole("section", size: 17, lineHeight: 24, weight: .semibold)
        /// Body, rows, controls.
        static let body = TypeRole("body", size: 13, lineHeight: 20)
        /// Compact metadata: helper sentences, timestamps, counts.
        static let meta = TypeRole("meta", size: 11, lineHeight: 16)
        /// Words in the pill — natural-language text, never monospaced (design §4 "Transcript layout").
        static let pillTranscript = TypeRole("pillTranscript", size: 13.5, lineHeight: 21)
        /// The pill's status and helper lines.
        static let pillStatus = TypeRole("pillStatus", size: 11, lineHeight: 14)
        /// Key caps ("fn / 🌐", "Esc") — the prototype's `kbd` is 11 px `--mono`.
        static let key = TypeRole("key", size: 11, lineHeight: 16, design: .monospaced)
        /// Durations and timers ("12:04", latch elapsed) — tabular digits so they do not jitter.
        static let duration = meta.tabular
        /// The pill's timer.
        static let pillTimer = pillStatus.tabular

        static let all: [TypeRole] = [title, section, body, meta, pillTranscript, pillStatus, key, duration, pillTimer]
    }

    // MARK: - Spacing, sizes, radii (design §3 "Spacing")

    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        /// The whole scale. Nothing off-scale in the window (the pill's geometry is S2's table).
        static let scale: [CGFloat] = [xs, s, m, l, xl, xxl]
    }

    enum ControlSize {
        /// Minimum height of a compact control (row buttons, pill actions).
        static let compactMinimumHeight: CGFloat = 28
        /// Minimum height of a main control (page primary actions, form controls).
        static let mainMinimumHeight: CGFloat = 32
        /// Touch target on companion mobile surfaces.
        static let touchTarget: CGFloat = 44
    }

    enum Radius {
        static let window: CGFloat = 16
        static let group: CGFloat = 10
        /// Inputs and buttons.
        static let control: CGFloat = 7
        /// The pill: all four corners when floating (standalone, external display); lower corners
        /// only when attached under the notch / menu-bar band.
        static let pill: CGFloat = 18
        /// Idle presence chin (64 × 14), lower corners only — prototype `.notch.idle`.
        static let presenceChin: CGFloat = 6
        /// Hover hint (360 × 38), lower corners only — prototype `.notch.ready`.
        static let presenceHint: CGFloat = 10
        /// Key caps and tags — prototype `kbd`, `.tag`.
        static let keyCap: CGFloat = 4

        /// Corner radii for the pill. Attached = upper corners square (design §3, §4).
        static func pillCorners(attached: Bool) -> RectangleCornerRadii {
            RectangleCornerRadii(topLeading: attached ? 0 : pill, bottomLeading: pill,
                                 bottomTrailing: pill, topTrailing: attached ? 0 : pill)
        }
    }
}
