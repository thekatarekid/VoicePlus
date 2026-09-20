import AppKit
import Foundation
import SwiftUI
import Testing
@testable import VoicePlusApp

/// G0.3 — the design tokens against the verified design, and the WCAG contrast audit.
///
/// Three sources are re-read on every run so the Swift values cannot drift from them: the prototype
/// (`design/design_v1.html` `:root`, `body.light`, `.notch` rules), the specification's token tables
/// (`design/design_v1.md` §3, §3.1) and the Spool spec fixture (`Fixtures/spool/spool_spec.json`).
/// The contrast audit's measured ratios must also appear verbatim in `DESIGN.md` §3.3, so the
/// document can never claim a number the code does not produce.
@Suite("Design tokens (G0.3)")
struct DesignTokenTests {
    typealias RGB = Tokens.RGB
    typealias Role = Tokens.Role

    static let packageRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url
    }()

    static func read(_ relativePath: String) throws -> String {
        try String(contentsOf: packageRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    static let backgrounds = Role.allCases.filter { $0.usage == .background }

    // MARK: - WCAG maths

    @Test func contrastMathMatchesWCAGReferencePoints() {
        #expect(abs(RGB("#FFFFFF").contrastRatio(against: RGB("#000000")) - 21) < 0.001)
        #expect(RGB("#777777").contrastRatio(against: RGB("#777777")) == 1)
        // WCAG's own worked value: #767676 on white is the lightest grey that passes 4.5 : 1.
        #expect(RGB("#767676").contrastRatio(against: RGB("#FFFFFF")) >= 4.5)
        #expect(RGB("#777777").contrastRatio(against: RGB("#FFFFFF")) < 4.5)
        // Symmetric.
        #expect(RGB("#AD714F").contrastRatio(against: RGB("#080A09"))
                == RGB("#080A09").contrastRatio(against: RGB("#AD714F")))
    }

    @Test func hexParsingIsStrict() {
        #expect(RGB(parsing: "#e9ad83") == RGB(red: 0xE9, green: 0xAD, blue: 0x83))
        #expect(RGB(parsing: "E9AD83")?.hex == "#E9AD83")
        #expect(RGB(parsing: "#E9AD8") == nil)
        #expect(RGB(parsing: "#+9AD83") == nil)
        #expect(RGB(parsing: "#GGAD83") == nil)
    }

    // MARK: - The contrast audit (acceptance: ≥ 4.5 : 1 text, ≥ 3 : 1 lines, both themes)

    /// Every text ink on every window background, both themes, standard and increased contrast.
    @Test(arguments: Tokens.Theme.allCases, Tokens.Contrast.allCases)
    func everyTextInkPassesOnEveryBackground(theme: Tokens.Theme, contrast: Tokens.Contrast) {
        for ink in Role.allCases where ink.usage == .text {
            let required = Self.requiredRatio(ink, contrast)
            for background in Self.backgrounds {
                let ratio = ink.value(theme, contrast).contrastRatio(against: background.value(theme, contrast))
                #expect(ratio >= required,
                        "\(theme)/\(contrast): \(ink) on \(background) is \(Self.format(ratio)) : 1, needs \(required)")
            }
        }
    }

    /// Lines that identify a control or a state: ≥ 3 : 1 on every background. Under Increase
    /// Contrast the separator is one of them.
    @Test(arguments: Tokens.Theme.allCases, Tokens.Contrast.allCases)
    func everyMeaningfulLinePassesOnEveryBackground(theme: Tokens.Theme, contrast: Tokens.Contrast) {
        var lines = Role.allCases.filter { $0.usage == .line }
        if contrast == .increased { lines.append(.separator) }
        #expect(lines.contains(.controlBorder))
        for line in lines {
            for background in Self.backgrounds {
                let ratio = line.value(theme, contrast).contrastRatio(against: background.value(theme, contrast))
                #expect(ratio >= 3, "\(theme)/\(contrast): \(line) on \(background) is \(Self.format(ratio)) : 1")
            }
        }
    }

    /// The design's 1 px separator measures below 3 : 1 (1.34–1.91). It is classified decorative,
    /// kept exactly as verified, and becomes `controlBorder` under Increase Contrast — `DESIGN.md`
    /// §3.3 records the pair and the adjustment. If a future design change lifts it above 3 : 1,
    /// this test fails so the classification is revisited rather than left stale.
    @Test func decorativeSeparatorIsTheOnlySubThresholdPairAndIsAdjusted() {
        for theme in Tokens.Theme.allCases {
            let ratios = Self.backgrounds.map { Role.separator.value(theme).contrastRatio(against: $0.value(theme)) }
            #expect(ratios.allSatisfy { $0 < 3 }, "separator no longer sub-threshold in \(theme): \(ratios)")
            #expect(Role.separator.value(theme, .increased) == Role.controlBorder.value(theme))
            #expect(Role.separator.value(theme, .standard) == Role.separator.value(theme))
        }
        #expect(Role.allCases.filter { $0.usage == .decorativeLine } == [.separator])
    }

    @Test(arguments: Tokens.Theme.allCases)
    func textOnAccentPasses(theme: Tokens.Theme) {
        for contrast in Tokens.Contrast.allCases {
            let ratio = Role.onAccent.value(theme, contrast).contrastRatio(against: Role.accent.value(theme, contrast))
            #expect(ratio >= 4.5, "\(theme): onAccent on accent is \(Self.format(ratio))")
        }
    }

    /// The pill is always dark: its inks are measured against its own fill and its button fills,
    /// never against a window theme.
    @Test func pillInksPassOnThePill() {
        typealias P = Tokens.Pill.Token
        for pair in Self.pillPairs {
            let ratio = pair.fg.value.contrastRatio(against: pair.bg.value)
            #expect(ratio >= pair.required, "pill \(pair.fg) on \(pair.bg) is \(Self.format(ratio))")
        }
        // The idle dot is the design's `ready` green, not the light-theme green, in both themes.
        #expect(P.ready.value == Role.ready.value(.dark))
        #expect(P.background.value == Role.pill.value(.dark) && Role.pill.value(.light) == Role.pill.value(.dark))
    }

    /// `DESIGN.md` §3.3 must record every measured ratio verbatim (the acceptance says failing pairs
    /// are "adjusted and recorded in DESIGN.md"; recording all of them keeps the document honest).
    @Test func designDocumentRecordsTheMeasuredRatios() throws {
        let doc = try Self.read("DESIGN.md")
        let missing = Self.auditRows().filter { !doc.contains($0) }
        #expect(missing.isEmpty, "DESIGN.md §3.3 is missing or has stale rows:\n\(missing.joined(separator: "\n"))")
    }

    // MARK: - Parity with the verified design

    @Test func windowColoursEqualThePrototypeCSS() throws {
        let html = try Self.read("design/design_v1.html")
        let dark = try #require(Self.cssBlock(html, selector: ":root{color-scheme:dark;"))
        let light = try #require(Self.cssBlock(html, selector: "body.light{"))
        for role in Role.allCases {
            guard let variable = role.prototypeVariable else {
                #expect(role == .controlBorder, "\(role) has no prototype variable")
                continue
            }
            let darkHex = try #require(Self.cssValue(dark, variable), "\(variable) missing in :root")
            #expect(Self.cssColor(darkHex) == role.value(.dark), "\(role) dark ≠ prototype \(variable) \(darkHex)")
            // `body.light` only overrides what changes; the pill inherits :root.
            let lightHex = Self.cssValue(light, variable) ?? darkHex
            #expect(Self.cssColor(lightHex) == role.value(.light), "\(role) light ≠ prototype \(variable) \(lightHex)")
        }
    }

    @Test func pillColoursEqualThePrototypeNotchRules() throws {
        let html = try Self.read("design/design_v1.html")
        typealias P = Tokens.Pill.Token
        let expectations: [(String, String, P)] = [
            (".notch{position:relative;", "background", .background),
            (".notch{position:relative;", "color", .ink),
            (".notch .words{font-size:14px;", "color", .ink),
            (".notch .actions button{background:", "background", .control),
            (".notch .actions button{background:", "border-color", .controlBorder),
            (".notch .actions .primary{", "background", .primary),
            (".notch .actions .primary{", "color", .onPrimary),
            (".notch .uncertain{", "border-color", .uncertainty),
            (".dot{display:inline-block;", "background", .ready),
        ]
        for (selector, property, token) in expectations {
            let block = try #require(Self.cssBlock(html, selector: selector), "no rule \(selector)")
            let value = try #require(Self.cssValue(block, property), "\(selector) has no \(property)")
            #expect(Self.cssColor(value) == token.value, "\(token) ≠ \(selector) \(property) \(value)")
        }
        #expect(P.secondaryInk.value == RGB("#A19387")) // V3 supporting ink
        // Attention in the pill is the dark `--amber`: the pill never takes the light theme.
        #expect(P.attention.value == Role.attention.value(.dark))
    }

    @Test func windowColoursEqualTheSpecificationTable() throws {
        let md = try Self.read("design/design_v1.md")
        let names: [(String, Role)] = [
            ("Canvas", .canvas), ("Sidebar", .sidebar), ("Surface", .surface), ("Elevated", .elevated),
            ("Primary ink", .ink), ("Secondary ink", .secondaryInk), ("Separator", .separator),
            ("Accent", .accent), ("Ready", .ready), ("Attention", .attention),
            ("Uncertainty", .uncertainty), ("Pill", .pill),
        ]
        for (name, role) in names {
            let cells = try #require(Self.tableRow(md, firstCell: name), "design_v1.md §3 has no row \(name)")
            #expect(RGB(parsing: cells[1]) == role.value(.dark), "\(name) dark \(cells[1])")
            #expect(RGB(parsing: cells[2]) == role.value(.light), "\(name) light \(cells[2])")
        }
    }

    @Test func spoolMaterialsEqualTheSpecificationAndTheFixture() throws {
        let md = try Self.read("design/design_v1.md")
        let rows: [(String, Tokens.SpoolMaterial)] = [
            ("Tape oxide face", .tapeFace), ("Tape reverse", .tapeReverse), ("Tape cut edge", .tapeEdge),
            ("Tape shadow / grain", .tapeShadow), ("Cassette housing", .housing), ("Hub / pressure pad", .hub),
        ]
        for (name, material) in rows {
            let cells = try #require(Self.tableRow(md, firstCell: name), "design_v1.md §3.1 has no row \(name)")
            #expect(RGB(parsing: cells[1]) == material.value, "\(name) \(cells[1]) ≠ \(material.value)")
        }
        #expect(Tokens.SpoolMaterial.allCases.count == 6)

        let data = try Data(contentsOf: Self.packageRoot.appendingPathComponent("Fixtures/spool/spool_spec.json"))
        let spec = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let tape = try #require(spec["tape"] as? [String: String])
        let character = try #require(spec["character"] as? [String: Any])
        let shades = try #require(spec["housingShades"] as? [String: String])
        #expect(RGB(parsing: tape["face"] ?? "") == Tokens.SpoolMaterial.tapeFace.value)
        #expect(RGB(parsing: tape["back"] ?? "") == Tokens.SpoolMaterial.tapeReverse.value)
        #expect(RGB(parsing: tape["edge"] ?? "") == Tokens.SpoolMaterial.tapeEdge.value)
        #expect(RGB(parsing: tape["shadow"] ?? "") == Tokens.SpoolMaterial.tapeShadow.value)
        #expect(RGB(parsing: character["color"] as? String ?? "") == Tokens.SpoolMaterial.housing.value)
        #expect(RGB(parsing: shades["cream"] ?? "") == Tokens.SpoolMaterial.hub.value)
    }

    // MARK: - Dynamic colours

    @Test func dynamicColoursResolvePerAppearance() throws {
        for (name, theme) in [(NSAppearance.Name.darkAqua, Tokens.Theme.dark), (.aqua, .light)] {
            let appearance = try #require(NSAppearance(named: name))
            #expect(Tokens.Appearance.resolve(appearance) == Tokens.Appearance(theme: theme, contrast: .standard))
            for role in Role.allCases {
                var resolved: NSColor?
                appearance.performAsCurrentDrawingAppearance {
                    resolved = role.nsColor.usingColorSpace(.sRGB)
                }
                let color = try #require(resolved)
                let expected = role.value(theme)
                #expect(Self.byte(color.redComponent) == expected.red, "\(role) \(theme) red")
                #expect(Self.byte(color.greenComponent) == expected.green, "\(role) \(theme) green")
                #expect(Self.byte(color.blueComponent) == expected.blue, "\(role) \(theme) blue")
            }
        }
    }

    @Test func increasedContrastAppearancesMapToTheIncreasedValues() {
        #expect(Tokens.Appearance.resolve(.accessibilityHighContrastDarkAqua)
                == Tokens.Appearance(theme: .dark, contrast: .increased))
        #expect(Tokens.Appearance.resolve(.accessibilityHighContrastAqua)
                == Tokens.Appearance(theme: .light, contrast: .increased))
        #expect(Tokens.Appearance.resolve(.darkAqua) == Tokens.Appearance(theme: .dark, contrast: .standard))
        #expect(Tokens.Appearance.resolve(nil) == Tokens.Appearance(theme: .dark, contrast: .standard))
        // Increase Contrast touches exactly two roles.
        for theme in Tokens.Theme.allCases {
            let changed = Role.allCases.filter { $0.value(theme, .increased) != $0.value(theme, .standard) }
            #expect(changed == [.secondaryInk, .separator], "\(theme): \(changed)")
        }
    }

    // MARK: - Typography, spacing, radii (design §3)

    @Test func typographyRolesAreTheDesignsRoles() {
        typealias T = Tokens.Typography
        let expected: [(Tokens.TypeRole, CGFloat, CGFloat, Tokens.TypeRole.Weight)] = [
            (T.title, 24, 30, .semibold), (T.section, 17, 24, .semibold), (T.body, 13, 20, .regular),
            (T.meta, 11, 16, .regular), (T.pillTranscript, 13.5, 21, .regular), (T.pillStatus, 11, 14, .regular),
            (T.key, 11, 16, .regular),
        ]
        for (role, size, lineHeight, weight) in expected {
            #expect(role.size == size && role.lineHeight == lineHeight && role.weight == weight, "\(role.name)")
            #expect(role.nsFont().pointSize == size, "\(role.name) font size")
            #expect(role.nsFont(scale: 1.25).pointSize == size * 1.25, "\(role.name) scaled")
        }
        // The pill's words are natural language, never monospaced (design §4 "Transcript layout").
        #expect(T.pillTranscript.design == .system)
        #expect(T.key.design == .monospaced)
        #expect(T.duration.tabularDigits && T.pillTimer.tabularDigits)
        #expect(T.duration.size == T.meta.size && T.pillTimer.size == T.pillStatus.size)
        #expect(!T.body.tabularDigits)
        #expect(Set(T.all.map(\.name)).count == T.all.count)
    }

    /// Every role's line height is reachable: the face's natural line never exceeds it, so the
    /// spacing added is ≥ 0 and natural + spacing is exactly the design's line height.
    @Test func lineHeightsAreAttainable() {
        for role in Tokens.Typography.all {
            let font = role.nsFont()
            let natural = font.ascender - font.descender + font.leading
            #expect(natural <= role.lineHeight, "\(role.name): natural \(natural) > \(role.lineHeight)")
            #expect(abs(natural + role.lineSpacing() - role.lineHeight) < 0.001, "\(role.name)")
            #expect(role.paragraphStyle().minimumLineHeight == role.lineHeight)
            #expect(role.paragraphStyle().maximumLineHeight == role.lineHeight)
        }
    }

    @Test func tabularDigitsAreFixedWidth() {
        let font = Tokens.Typography.duration.nsFont()
        let widths = "0123456789".map { digit in
            (String(digit) as NSString).size(withAttributes: [.font: font]).width
        }
        #expect(Set(widths.map { ($0 * 100).rounded() }).count == 1, "\(widths)")
    }

    @Test func spacingAndRadiiAreTheDesignsScale() {
        #expect(Tokens.Spacing.scale == [4, 8, 12, 16, 24, 32])
        #expect(Tokens.Radius.window == 16 && Tokens.Radius.group == 10 && Tokens.Radius.control == 7)
        #expect(Tokens.Radius.pill == 18)
        let attached = Tokens.Radius.pillCorners(attached: true)
        #expect(attached.topLeading == 0 && attached.topTrailing == 0)
        #expect(attached.bottomLeading == 18 && attached.bottomTrailing == 18)
        let floating = Tokens.Radius.pillCorners(attached: false)
        #expect(floating.topLeading == 18 && floating.topTrailing == 18)
        #expect(floating.bottomLeading == 18 && floating.bottomTrailing == 18)
        #expect(Tokens.ControlSize.compactMinimumHeight == 28 && Tokens.ControlSize.mainMinimumHeight == 32)
    }

    // MARK: - DESIGN.md v2 content

    @Test func designDocumentRecordsAuthorityAndOwnerDecisions() throws {
        let doc = try Self.read("DESIGN.md")
        #expect(doc.contains("prototype code → `design/design_v1.md` → `VoicePlus_ImplementationBuild_V4_Wave1+Design.md` → this file → `VoicePlus_Improvements_V4.md`"))
        for decision in ["fn / 🌐", "Voice enrollment", "Deixis box", "latch pause"] {
            #expect(doc.contains(decision), "owner decision missing: \(decision)")
        }
    }

    @Test func handsFreeRuleIsReplacedByTheVerifiedLatchedCopy() throws {
        let doc = try Self.read("DESIGN.md")
        #expect(!doc.contains("Never write \"hands-free\""))
        let data = try Data(contentsOf: Self.packageRoot.appendingPathComponent("Fixtures/design/design_copy.json"))
        let copy = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let pill = try #require(copy["pill"] as? [String: Any])
        let latched = try #require(pill["latched"] as? [String: Any])
        let status = try #require(latched["status"] as? String)
        #expect(status == "Latched · hands-free")
        #expect(doc.contains(status))
    }

    /// §8 carries the design's full 26-row state inventory, one row per fixture state.
    @Test func designDocumentCarriesTheWholeStateInventory() throws {
        let doc = try Self.read("DESIGN.md")
        let data = try Data(contentsOf: Self.packageRoot.appendingPathComponent("Fixtures/design/design_copy.json"))
        let copy = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let states = try #require(copy["states"] as? [[String]])
        #expect(states.count == 26)
        for state in states {
            let id = state[1], key = state[0]
            #expect(doc.contains("| \(id) | `\(key)` |"), "DESIGN.md §8.6 has no row for \(id) \(key)")
        }
    }

    /// Every hex value in the code is written down in the document, so the document is the index.
    @Test func designDocumentListsEveryTokenValue() throws {
        let doc = try Self.read("DESIGN.md").uppercased()
        var values = Set<String>()
        for role in Role.allCases {
            for theme in Tokens.Theme.allCases {
                for contrast in Tokens.Contrast.allCases { values.insert(role.value(theme, contrast).hex) }
            }
        }
        Tokens.Pill.Token.allCases.forEach { values.insert($0.value.hex) }
        Tokens.SpoolMaterial.allCases.forEach { values.insert($0.value.hex) }
        let missing = values.filter { !doc.contains($0) }.sorted()
        #expect(missing.isEmpty, "DESIGN.md does not list \(missing)")
    }

    // MARK: - Helpers

    static func requiredRatio(_ role: Role, _ contrast: Tokens.Contrast) -> Double {
        switch role.usage {
        case .text, .textOnAccent:
            return contrast == .increased && (role == .ink || role == .secondaryInk) ? 7 : 4.5
        case .line: return 3
        case .decorativeLine: return contrast == .increased ? 3 : 0
        case .background, .fixedDark: return 0
        }
    }

    struct PillPair {
        let fg: Tokens.Pill.Token
        let bg: Tokens.Pill.Token
        let required: Double
    }

    static let pillPairs: [PillPair] = [
        PillPair(fg: .ink, bg: .background, required: 4.5),
        PillPair(fg: .secondaryInk, bg: .background, required: 4.5),
        PillPair(fg: .attention, bg: .background, required: 4.5),
        PillPair(fg: .ready, bg: .background, required: 3),
        PillPair(fg: .uncertainty, bg: .background, required: 3),
        PillPair(fg: .ink, bg: .control, required: 4.5),
        PillPair(fg: .onPrimary, bg: .primary, required: 4.5),
        PillPair(fg: .primary, bg: .background, required: 3),
        PillPair(fg: .controlBorder, bg: .background, required: 0),
    ]

    static func format(_ ratio: Double) -> String { String(format: "%.2f", ratio) }

    static func needs(_ role: Role, _ contrast: Tokens.Contrast) -> String {
        let required = requiredRatio(role, contrast)
        return required == 0 ? "decorative" : "≥ \(required == 4.5 ? "4.5" : String(Int(required)))"
    }

    /// The rows `DESIGN.md` §3.3 must contain, exactly.
    static func auditRows() -> [String] {
        var rows: [String] = []
        for contrast in Tokens.Contrast.allCases {
            for theme in Tokens.Theme.allCases {
                for role in Role.allCases where [.text, .line, .decorativeLine].contains(role.usage) {
                    if contrast == .increased && role.value(theme, .increased) == role.value(theme, .standard) {
                        continue
                    }
                    let ratios = backgrounds.map {
                        format(role.value(theme, contrast).contrastRatio(against: $0.value(theme, contrast)))
                    }
                    rows.append("| \(theme.rawValue) · \(contrast.rawValue) | `\(role.rawValue)` \(role.value(theme, contrast).hex) | "
                                + ratios.joined(separator: " | ") + " | \(needs(role, contrast)) |")
                }
                if contrast == .standard {
                    let ratio = Role.onAccent.value(theme).contrastRatio(against: Role.accent.value(theme))
                    rows.append("| \(theme.rawValue) · on accent | `onAccent` \(Role.onAccent.value(theme).hex) on `accent` \(Role.accent.value(theme).hex) | \(format(ratio)) | ≥ 4.5 |")
                }
            }
        }
        for pair in pillPairs {
            let ratio = pair.fg.value.contrastRatio(against: pair.bg.value)
            let need = pair.required == 0 ? "decorative" : (pair.required == 4.5 ? "≥ 4.5" : "≥ 3")
            rows.append("| pill | `\(pair.fg.rawValue)` \(pair.fg.value.hex) on `\(pair.bg.rawValue)` \(pair.bg.value.hex) | \(format(ratio)) | \(need) |")
        }
        return rows
    }

    /// The body of the first CSS rule whose text starts with `selector` (selector included).
    static func cssBlock(_ css: String, selector: String) -> String? {
        guard let start = css.range(of: selector) else { return nil }
        guard let end = css[start.lowerBound...].firstIndex(of: "}") else { return nil }
        return String(css[start.lowerBound..<end])
    }

    /// `property:value` inside a rule body, matched on a declaration boundary.
    static func cssValue(_ block: String, _ property: String) -> String? {
        for declaration in block.split(whereSeparator: { $0 == ";" || $0 == "{" }) {
            let parts = declaration.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == property { return parts[1] }
        }
        return nil
    }

    /// Cells of the Markdown table row whose first cell is `firstCell`.
    static func tableRow(_ markdown: String, firstCell: String) -> [String]? {
        for line in markdown.split(separator: "\n") where line.hasPrefix("|") {
            let cells = line.split(separator: "|", omittingEmptySubsequences: false)
                .dropFirst().dropLast().map { $0.trimmingCharacters(in: .whitespaces) }
            if cells.first == firstCell { return Array(cells) }
        }
        return nil
    }

    /// A CSS hex colour, including the `#rgb` shorthand the prototype uses for `--accent-ink:#fff`.
    static func cssColor(_ value: String) -> RGB? {
        let digits = value.hasPrefix("#") ? String(value.dropFirst()) : value
        if digits.count == 3 { return RGB(parsing: digits.map { "\($0)\($0)" }.joined()) }
        return RGB(parsing: digits)
    }

    static func byte(_ component: CGFloat) -> UInt8 { UInt8((component * 255).rounded()) }
}
