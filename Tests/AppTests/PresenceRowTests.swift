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
        // …and the old fixed row could not have held it, which is the bug.
        #expect(fit.width > PresenceGeometry.hoverSize.width)
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
            // Never narrower than the nominal row (unless the display itself is).
            #expect(narrow.width == min(PresenceGeometry.hoverSize.width, PresenceGeometry.maxRowWidth(on: metrics)))

            let layout = PresenceGeometry.layout(for: metrics, state: .ready, hovered: true, rowWidth: 320)
            #expect(PresenceGeometry.clearsHousing(layout.frame, on: metrics))
            // Same top boundary as everything else at this anchor.
            #expect(layout.frame.maxY == metrics.frame.maxY - metrics.topBand)
            // A row wider than the nominal size still counts as hovered under the pointer.
            #expect(layout.hoverRect.contains(CGPoint(x: layout.frame.midX, y: layout.frame.midY)))
            #expect(layout.hoverRect.contains(CGPoint(x: layout.frame.minX + 2, y: layout.frame.midY)))
        }
    }

    @Test func noNotchDisplaysHangTheRowUnderTheMenuBar() {
        let layout = PresenceGeometry.layout(for: Self.external, state: .ready, hovered: true, rowWidth: 400)
        #expect(Self.external.notchRect == nil)
        #expect(layout.frame.maxY == Self.external.frame.maxY - Self.external.menuBarHeight)
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

    // MARK: - Announcement

    @Test func announcesAtLaunchAndOnRecoveryButNotAfterEveryUtterance() {
        #expect(PresenceIntroduction.announces(from: nil, to: .ready))
        #expect(PresenceIntroduction.announces(from: .blocked(.modelMissing), to: .ready))
        #expect(PresenceIntroduction.announces(from: .blocked(.microphoneDenied), to: .ready))
        // The ordinary end of a dictation must not re-announce.
        #expect(!PresenceIntroduction.announces(from: .listening(level: 0.3), to: .ready))
        #expect(!PresenceIntroduction.announces(from: .processing, to: .ready))
        #expect(!PresenceIntroduction.announces(from: .ready, to: .ready))
        // Nor does un-suppressing (pill hidden, full screen exited).
        #expect(!PresenceIntroduction.announces(from: .off, to: .ready))
        // Only `ready` ever announces.
        #expect(!PresenceIntroduction.announces(from: nil, to: .muted))
        #expect(!PresenceIntroduction.announces(from: .blocked(.modelMissing), to: .paused))
    }

    @Test func theAnnouncementCollapsesOnItsOwn() {
        let start = Date()
        #expect(PresenceIntroduction.isShowing(since: start, now: start))
        #expect(PresenceIntroduction.isShowing(since: start, now: start.addingTimeInterval(PresenceIntroduction.duration - 0.5)))
        #expect(!PresenceIntroduction.isShowing(since: start, now: start.addingTimeInterval(PresenceIntroduction.duration + 0.1)))
        #expect(!PresenceIntroduction.isShowing(since: nil, now: start))
        // Long enough to read, short enough not to be furniture.
        #expect(PresenceIntroduction.duration >= 3 && PresenceIntroduction.duration <= 10)
    }

    // MARK: - The pill's own sizing

    @Test func thePillWidensToFitItsNotice() {
        let reason = "No speech model installed"
        let base = NotchGeometry.size(for: .unavailable(reason: reason))
        let fitted = NotchGeometry.size(for: .unavailable(reason: reason), on: Self.notched, measure: Self.ruler)
        #expect(fitted.width >= base.width)
        #expect(fitted.width >= Self.ruler(PillState.unavailableSubtitle))
        #expect(fitted.width <= Self.notched.frame.width - 16)
        // On a display too narrow for it, it is clamped rather than hanging off the edge.
        let onSliver = NotchGeometry.size(for: .unavailable(reason: reason), on: Self.sliver, measure: Self.ruler)
        #expect(onSliver.width <= Self.sliver.frame.width - 16)
        #expect(NotchGeometry.layout(for: Self.sliver, size: onSliver).shown.minX >= Self.sliver.frame.minX)
    }

    @Test func statesWithoutFixedTextKeepTheirNominalSize() {
        #expect(NotchGeometry.size(for: .listening(level: 0.5), on: Self.notched, measure: Self.ruler)
                == NotchGeometry.size(for: .listening(level: 0.5)))
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
