import CoreGraphics
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// The truncation bug, pinned down: a status message must never end in a dangling mid-word ellipsis,
/// and the panel must be sized to whatever it ends up saying.
@Suite struct PresenceRowTests {
    /// A deterministic ruler — 6 pt per character. Keeps these tests free of a font stack and of the
    /// window server (neither of which exists in this test environment).
    static let ruler: (String) -> CGFloat = { CGFloat($0.count) * 6 }

    static let notched = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                       topInset: 37, notchWidth: 200, menuBarHeight: 37,
                                       visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 945))
    static let external = ScreenMetrics(frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080),
                                        topInset: 0, notchWidth: nil, menuBarHeight: 24)
    /// A vertical/rotated or tiny display — the case that actually forces shortening.
    static let sliver = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 260, height: 900),
                                      topInset: 0, menuBarHeight: 24)

    // MARK: - The reported bug

    @Test func readyRowShowsTheWholeSentenceIncludingTheHotkey() {
        let fit = PresenceRow.fit(detail: PresenceState.ready.detail, hint: "hold Right ⌃",
                                  maxWidth: PresenceGeometry.maxRowWidth(on: Self.notched), measure: Self.ruler)
        #expect(fit.text == "VoicePlus · Ready — hold Right ⌃")
        #expect(!fit.truncated)
        // The panel is wider than the text it has to draw — the whole point.
        #expect(fit.width >= Self.ruler(fit.text))
        // …and the old fixed 190 pt row could not have held it, which is the bug.
        #expect(fit.width > NotchGeometry.hintMinimumWidth)
    }

    @Test func aMessageThatFitsIsNeverShortened() {
        for detail in [PresenceState.listening(level: 0.4).detail, PresenceState.muted.detail,
                       PresenceState.blocked(.modelMissing).detail, PresenceState.blocked(.relaunchNeeded).detail] {
            let fit = PresenceRow.fit(detail: detail, hint: "", maxWidth: 4000, measure: Self.ruler)
            #expect(fit.text == detail)
            #expect(!fit.truncated)
        }
    }

    @Test func neverEndsInAMidWordEllipsis() {
        // Every state, on the narrowest display we lay out for.
        let states: [PresenceState] = [.ready, .listening(level: 1), .processing, .muted, .paused,
                                       .blocked(.microphoneDenied), .blocked(.hotkeyUnavailable),
                                       .blocked(.relaunchNeeded), .blocked(.modelMissing),
                                       .blocked(.modelDownloading(0.42))]
        for state in states {
            let fit = PresenceRow.fit(detail: state.detail, hint: "hold Right ⌃",
                                      maxWidth: PresenceGeometry.maxRowWidth(on: Self.sliver), measure: Self.ruler)
            #expect(!fit.text.isEmpty)
            // Whatever survives, every word of it is a whole word from the original sentence.
            let source = Set(state.detail.split(separator: " ").map(String.init) + ["hold", "Right", "⌃", "—"])
            for word in fit.text.split(separator: " ").map(String.init) {
                #expect(source.contains(word) || (word.hasSuffix("…") && source.contains(String(word.dropLast()))),
                        "\(state.caseName): \(word) is not a whole word of \(state.detail)")
            }
            #expect(fit.width <= PresenceGeometry.maxRowWidth(on: Self.sliver))
        }
    }

    @Test func shortensByDroppingComponentsInOrder() {
        let detail = "VoicePlus · Ready"
        // Wide enough for everything.
        #expect(PresenceRow.fit(detail: detail, hint: "hold Right ⌃", maxWidth: 1000, measure: Self.ruler).text
                == "VoicePlus · Ready — hold Right ⌃")
        // Only wide enough for the sentence: the hint goes first.
        let chrome = PresenceRow.iconWidth + PresenceRow.horizontalPadding
        #expect(PresenceRow.fit(detail: detail, hint: "hold Right ⌃",
                                maxWidth: Self.ruler(detail) + chrome + 2, measure: Self.ruler).text == detail)
        // Only wide enough for the bare state: the brand prefix goes next.
        #expect(PresenceRow.fit(detail: detail, hint: "hold Right ⌃",
                                maxWidth: Self.ruler("Ready") + chrome + 2, measure: Self.ruler).text == "Ready")
    }

    @Test func dropsWholeWordsNotCharacters() {
        let text = "macOS isn't sending keys to VoicePlus"
        let clipped = PresenceRow.dropTrailingWords(text, toFit: 6 * 20, measure: Self.ruler)
        #expect(clipped.hasSuffix("…"))
        for word in clipped.dropLast().split(separator: " ") {
            #expect(text.split(separator: " ").contains(word))
        }
    }

    @Test func aSingleUnfittableWordIsShownWholeRatherThanCut() {
        #expect(PresenceRow.dropTrailingWords("Supercalifragilistic", toFit: 10, measure: Self.ruler)
                == "Supercalifragilistic")
    }

    // MARK: - Hint policy

    @Test func theHotkeyHintOnlyAppearsWhereThatKeyWouldWork() {
        #expect(PresenceRow.hint("hold Right ⌃", for: .ready) == "hold Right ⌃")
        #expect(PresenceRow.hint("hold Right ⌃", for: .blocked(.modelMissing)).isEmpty)
        #expect(PresenceRow.hint("hold Right ⌃", for: .muted).isEmpty)
        #expect(PresenceRow.hint("hold Right ⌃", for: .listening(level: 0.2)).isEmpty)
    }

    @Test func hotkeyLabelComesFromTheConfiguredBinding() {
        #expect(HotkeyHint.label(for: .rightControl) == "hold Right ⌃")
        #expect(HotkeyHint.label(for: .rightOption) == "hold Right ⌥")
        #expect(HotkeyHint.label(for: .fn) == "hold fn / 🌐")
        // A chord is pressed, not held — the verb has to follow the binding too.
        #expect(HotkeyHint.label(for: .controlOptionD) == "press ⌃⌥D")
        // Every binding the user can pick produces a usable label; none is hardcoded.
        for kind in HotkeyBinding.Kind.allCases {
            let label = HotkeyHint.label(for: kind)
            #expect(label.contains(kind.displayName))
            #expect(label.hasPrefix("hold ") || label.hasPrefix("press "))
        }
    }

    // MARK: - Geometry of the sized row

    @Test func theRowIsSizedToItsTextAndStaysOnTheDisplay() {
        for metrics in [Self.notched, Self.external, Self.sliver] {
            let wide = PresenceGeometry.rowSize(width: 5000, on: metrics)
            #expect(wide.width == PresenceGeometry.maxRowWidth(on: metrics))
            let narrow = PresenceGeometry.rowSize(width: 10, on: metrics)
            // Never narrower than 190 pt (unless the display itself is): the hint is text-sized (S2).
            #expect(narrow.width == min(NotchGeometry.hintMinimumWidth, PresenceGeometry.maxRowWidth(on: metrics)))

            let layout = PresenceGeometry.layout(for: metrics, state: .ready, hovered: true, rowWidth: 320)
            #expect(PresenceGeometry.clearsHousing(layout.frame, on: metrics))
            // Same top boundary as everything else at this anchor (the pill's top edge).
            #expect(layout.frame.maxY == NotchGeometry.pillTopEdge(on: metrics))
            // A row wider than the nominal size still counts as hovered under the pointer.
            #expect(layout.hoverRect.contains(CGPoint(x: layout.frame.midX, y: layout.frame.midY)))
            #expect(layout.hoverRect.contains(CGPoint(x: layout.frame.minX + 2, y: layout.frame.midY)))
        }
    }

    @Test func noNotchDisplaysHangTheRowUnderTheMenuBar() {
        let layout = PresenceGeometry.layout(for: Self.external, state: .ready, hovered: true, rowWidth: 400)
        #expect(Self.external.notchRect == nil)
        // Floating: 8 pt below the menu-bar band (design §4).
        #expect(layout.frame.maxY == Self.external.frame.maxY - Self.external.menuBarHeight - 8)
        #expect(Self.external.frame.contains(layout.frame))
    }

    // MARK: - Resting visibility (the "only on hover" complaint)

    @Test func theRestingReadyChinIsBigEnoughToSee() {
        // A 4 pt sliver at 35 % black under a black bezel is invisible; this is the regression guard.
        #expect(PresenceGeometry.restSize.height >= 8)
        #expect(PresenceGeometry.size(for: .ready) == PresenceGeometry.restSize)
        // …and it is still small: a status light, not a banner.
        #expect(PresenceGeometry.restSize.height <= 14)
        #expect(PresenceGeometry.restSize.width <= 96)
    }

    @Test func readyIsVisibleWithoutTheMouseBeingAnywhereNearIt() {
        let state = PresenceStateReducer.reduce(PresenceInputs())
        #expect(state == .ready)
        #expect(state.isVisible)
        #expect(PresenceGeometry.layout(for: Self.notched, state: state).visible)
    }

    // MARK: - No unprompted announcement (S2)

    /// Design §4: the hint is only ever a hover. Nothing expands on launch or on recovery; the idle
    /// chin's green dot is the at-rest affordance.
    @Test func theHintNeverExpandsUnprompted() {
        let hint = HotkeyBinding.default.readyHint()
        for state: PresenceState in [.ready, .muted, .paused, .blocked(.modelMissing)] {
            #expect(PresenceHover.presentation(state: state, pointerOn: false, readyHint: hint) == .chin)
        }
        #expect(PresenceGeometry.layout(for: Self.notched, state: .ready).frame.size == NotchGeometry.idleChinSize)
    }

    // MARK: - The pill's own sizing (S2: placement math, never content)

    /// The pill no longer widens to fit a notice: every turn state takes the ceiling width, and a
    /// display too narrow for it clamps the pill rather than letting it hang off an edge.
    @Test func thePillIsTheCeilingWidthAndClampsToTheDisplay() {
        let reason = "No speech model installed"
        let fitted = NotchGeometry.size(for: .unavailable(reason: reason), on: Self.notched, measure: Self.ruler)
        #expect(fitted == NotchGeometry.actionableSize)
        let onSliver = NotchGeometry.size(for: .unavailable(reason: reason), on: Self.sliver, measure: Self.ruler)
        #expect(onSliver.width <= Self.sliver.frame.width - 16)
        #expect(NotchGeometry.pillLayout(for: Self.sliver, size: onSliver).shown.minX >= Self.sliver.frame.minX)
    }

    @Test func liveTextNeverResizesThePill() {
        #expect(NotchGeometry.size(for: .listening(level: 0.5), on: Self.notched, measure: Self.ruler)
                == NotchGeometry.size(for: .preview(text: String(repeating: "word ", count: 80)), on: Self.notched,
                                      measure: Self.ruler))
        // A live transcript must not resize the pill on every syllable.
        #expect(PillState.preview(text: String(repeating: "word ", count: 80)).messageLines.isEmpty)
    }

    @Test func theWarningHeadlineIsOneStringForBothTheViewAndTheRuler() {
        #expect(PillState.warningHeadline(MicQuality(snr: 4, clipping: 0, lowLevel: true, verdict: .bad)) == "Mic level is very low")
        #expect(PillState.warningHeadline(MicQuality(snr: 20, clipping: 0.2, lowLevel: false, verdict: .poor)) == "Mic is clipping")
        #expect(PillState.warningHeadline(MicQuality(snr: 7, clipping: 0, lowLevel: false, verdict: .poor)) == "Noisy mic — 7 dB SNR")
        #expect(PillState.warning(MicQuality(snr: 7, clipping: 0, lowLevel: false, verdict: .poor)).messageLines.count == 2)
    }
}
