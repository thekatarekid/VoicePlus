import AppKit
import Testing
@testable import VoicePlusApp

@Suite("Pill Increase Contrast")
@MainActor
struct PillContrastTests {
    typealias P = Tokens.Pill.Token
    typealias RGB = Tokens.RGB

    @Test func actualStandardAppearancesResolveThroughTheDynamicProvider() throws {
        for token in P.allCases {
            let dynamic = token.nsColor
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                #expect(try resolved(dynamic, under: name) == token.value(.standard), "\(token), \(name)")
            }
        }
        for (color, token) in [(Tokens.Pill.secondaryInk, P.secondaryInk),
                               (Tokens.Pill.controlBorder, .controlBorder),
                               (Tokens.Pill.scrollTrack, .scrollTrack), (Tokens.Pill.scrollThumb, .scrollThumb)] {
            #expect(try resolved(color, under: .darkAqua) == token.value(.standard))
        }
    }

    // SDK: accessibilityHighContrast* names are only for bestMatch, not NSAppearance(named:).
    // Inject the match into the provider for unit coverage; this does not claim native setting QA.
    @Test func injectedHighContrastMatchesResolveAndCanReturnToNormal() throws {
        for token in P.allCases {
            var match = NSAppearance.Name.darkAqua
            let dynamic = token.dynamicColor { _ in Tokens.Appearance.resolve(match).contrast }
            for (name, contrast) in [(NSAppearance.Name.darkAqua, Tokens.Contrast.standard),
                                     (.accessibilityHighContrastAqua, .increased),
                                     (.accessibilityHighContrastDarkAqua, .increased), (.aqua, .standard)] {
                match = name
                #expect(try resolved(dynamic, under: .darkAqua) == token.value(contrast), "\(token), \(name)")
            }
        }
    }

    @Test func meaningfulBoundariesMeetThreeToOneOnBothAdjacentSurfaces() throws {
        for contrast in Tokens.Contrast.allCases {
            let border = P.controlBorder.value(contrast)
            for background in [P.background, .control, .scrollTrack] {
                let ratio = border.contrastRatio(against: background.value(contrast))
                #expect(ratio >= 3, "Control border on \(background): \(ratio)")
            }
            #expect(P.scrollThumb.value(contrast).contrastRatio(against: P.scrollTrack.value(contrast)) >= 3)
            // Primary actions have no outline: their peach fill identifies the boundary,
            // and the dark label owes text contrast against that fill.
            #expect(P.primary.value(contrast).contrastRatio(against: P.background.value(contrast)) >= 3)
            #expect(P.onPrimary.value(contrast).contrastRatio(against: P.primary.value(contrast)) >= 4.5)
        }
    }

    @Test func increasedContrastStrengthensSupportingInkBoundariesAndScrollThumb() {
        for token in [P.secondaryInk, .controlBorder, .scrollThumb] {
            #expect(token.value(.increased).contrastRatio(against: P.background.value)
                    > token.value(.standard).contrastRatio(against: P.background.value))
        }
        #expect(P.secondaryInk.value(.increased).contrastRatio(against: P.control.value) >= 7)
        #expect(P.controlBorder.value(.increased).contrastRatio(against: P.control.value) >= 7)
        #expect(P.ink.value(.increased) == P.ink.value)
        #expect(P.background.value(.increased) == P.background.value)
    }

    @Test func normalTextFillsAndRailMaterialStayApproved() {
        let expected: [(P, String)] = [(.background, "#080A09"), (.ink, "#FFF0E3"),
            (.secondaryInk, "#A19387"), (.ready, "#69D58B"), (.attention, "#F0C181"),
            (.uncertainty, "#FF8F95"), (.control, "#382A21"), (.primary, "#E9AD83"),
            (.onPrimary, "#352014"), (.scrollTrack, "#17110D"), (.scrollThumb, "#AB7859")]
        for (token, hex) in expected { #expect(token.value(.standard) == RGB(hex)) }
    }

    private func resolved(_ color: NSColor, under name: NSAppearance.Name) throws -> RGB {
        let appearance = try #require(NSAppearance(named: name))
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) }
        let rgb = try #require(resolved)
        return RGB(red: UInt8((rgb.redComponent * 255).rounded()),
                   green: UInt8((rgb.greenComponent * 255).rounded()),
                   blue: UInt8((rgb.blueComponent * 255).rounded()))
    }
}
