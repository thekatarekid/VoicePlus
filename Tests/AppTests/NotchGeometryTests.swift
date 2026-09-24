import CoreGraphics
import Shared
import Testing
@testable import VoicePlusApp

/// S2 — the Spool pill's geometry (design §4, DESIGN.md §8.3): every state's size, the compact
/// ceiling, the narrow review layout, attached vs floating placement, and the camera-housing guard.
/// Display values are measured from real hardware (2026-08-29, MacBook with camera housing + AirPlay
/// external display), so the regression guard matches the display the original bug was reported on.
@Suite("Notch geometry (S2)")
struct NotchGeometryTests {
    /// Built-in Retina display: frame 1800x1169, safeAreaInsets.top 38, aux areas 790 pt wide each
    /// (housing 220 pt), visibleFrame.maxY 1130 (menu-bar delta 39).
    let notched = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1800, height: 1169),
                                topInset: 38, notchWidth: 220, menuBarHeight: 39)
    /// Same panel, but not at the global origin (built-in placed right of an external display).
    let notchedOffOrigin = ScreenMetrics(frame: CGRect(x: -1800, y: 200, width: 1800, height: 1169),
                                         topInset: 38, notchWidth: 220, menuBarHeight: 39)
    /// Notched panel with the menu bar auto-hidden / a full-screen space.
    let autoHiddenMenuBar = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1800, height: 1169),
                                          topInset: 38, notchWidth: 220, menuBarHeight: 0)
    /// External display carrying the menu bar.
    let external = ScreenMetrics(frame: CGRect(x: 1800, y: 89, width: 1920, height: 1080),
                                 topInset: 0, notchWidth: nil, menuBarHeight: 30)
    /// Secondary display with no menu bar ("Displays have separate Spaces" off).
    let externalNoMenuBar = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                          topInset: 0, notchWidth: nil, menuBarHeight: 0)
    /// A small display: usable width 440, so the ceiling is 408 and the review layout is narrow.
    let narrow = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 400, height: 700), topInset: 0, menuBarHeight: 24)

    var all: [ScreenMetrics] { [notched, notchedOffOrigin, autoHiddenMenuBar, external, externalNoMenuBar, narrow] }

    // MARK: - Sizes

    @Test func theDesignsNominalSizes() {
        #expect(NotchGeometry.idleChinSize == CGSize(width: 64, height: 14))
        #expect(NotchGeometry.hintSize == CGSize(width: 360, height: 38))
        #expect(NotchGeometry.hintMinimumWidth == 190)
        #expect(NotchGeometry.activeSize == CGSize(width: 560, height: 160))
        #expect(NotchGeometry.actionableSize == CGSize(width: 560, height: 160))
        #expect(NotchGeometry.characterBay == 126)
        #expect(NotchGeometry.cameoBay == 84)
        #expect(NotchGeometry.narrowBelow == 400)
        #expect(NotchGeometry.cornerRadius == Tokens.Radius.pill)
    }

    /// Every pill state's size: 160 without actions, 160 with an action row, the hint text-sized,
    /// hidden nothing.
    @Test func everyStateSize() {
        let active = NotchGeometry.activeSize, actionable = NotchGeometry.actionableSize
        let poor = MicQuality(snr: 8, clipping: 0, lowLevel: false, verdict: .poor)
        let expected: [(PillState, CGSize)] = [
            (.hidden, .zero),
            (.idle, active), (.starting, active), (.listening(level: 0.3), active), (.listeningQuiet, active),
            (.latched(elapsed: 3), actionable),                       // Finish
            (.warning(poor), actionable),                             // Check microphone
            (.landing, active), (.finishing(elapsedWarning: false), active), (.finishing(elapsedWarning: true), active),
            (.finalPreview(FinalPreviewInfo(text: "x", dwellRemaining: 0.9)), active),
            (.finalPreview(FinalPreviewInfo(text: "x", dwellRemaining: 0, manual: true)), actionable),
            (.finalPreview(FinalPreviewInfo(text: "x", uncertainCount: 1, dwellRemaining: 1.8)), active),
            (.inserting(text: "x"), active),
            (.landed(LandedPillInfo(text: "x", verified: true)), active),
            (.landed(LandedPillInfo(text: "x", verified: false)), actionable),
            (.landedPartial(text: "x"), actionable),
            (.held(HeldPillInfo(text: "x", destination: "Mail", reason: "destination changed")), actionable),
            (.cancelled, active),
            (.muted, actionable),
            (.unavailable(reason: "no model"), actionable),
            (.error(message: "Text was not typed — Try again"), actionable),   // Dismiss
            (.error(message: DeliveryCopy.noSpeechDetected), active),         // a quiet return has no actions
            (.correcting, actionable), (.editing, active), (.undoAvailable, actionable),
            (.transform(TransformPillInfo(editingWords: 3, stage: .editing)), active),
            (.meeting(MeetingPillInfo(phase: .recording, elapsed: 1)), actionable),
            (.meeting(MeetingPillInfo(phase: .paused, elapsed: 1)), actionable),
            (.meeting(MeetingPillInfo(phase: .preparingNotes, elapsed: 1)), actionable),
            (.ready(hint: "Hold or Double Tap fn / 🌐 to dictate"), CGSize(width: 360, height: 38)),
        ]
        for (state, size) in expected {
            #expect(NotchGeometry.size(for: state) == size, "\(state.caseName)")
        }
    }

    @Test func theHintIsTextSizedAndNeverUnder190() {
        #expect(NotchGeometry.size(for: .hint(textWidth: 100), on: notched) == CGSize(width: 360, height: 38))
        #expect(NotchGeometry.size(for: .hint(textWidth: 300), on: notched) == CGSize(width: 360, height: 38))
        let measured = NotchGeometry.size(for: .ready(hint: "Hold or Double Tap fn / 🌐 to dictate"), on: notched) { _ in 236 }
        #expect(measured == CGSize(width: 360, height: 38))
        let sliver = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 160, height: 600), menuBarHeight: 24)
        #expect(NotchGeometry.size(for: .hint(textWidth: 300), on: sliver).width == 144)
    }

    // MARK: - The compact ceiling

    @Test func theCompactCeilingIsMin560UsableMinus32By160() {
        #expect(NotchGeometry.ceiling(on: notched) == CGSize(width: 560, height: 160))
        #expect(NotchGeometry.ceiling(on: external) == CGSize(width: 560, height: 160))
        #expect(NotchGeometry.ceiling(on: narrow) == CGSize(width: 368, height: 160))
        // The Dock on the side narrows the usable width, and the ceiling follows it.
        let docked = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 520, height: 800), menuBarHeight: 24,
                                   visibleFrame: CGRect(x: 60, y: 0, width: 460, height: 776))
        #expect(NotchGeometry.ceiling(on: docked).width == 428)
        // A short display: never taller than the room below the top edge.
        let short = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1200, height: 150), menuBarHeight: 24)
        #expect(NotchGeometry.ceiling(on: short).height == CGFloat(150 - 24 - 8 - 8))
        for metrics in all {
            for surface: NotchGeometry.Surface in [.active, .actionable] {
                let size = NotchGeometry.size(for: surface, on: metrics)
                #expect(size.width <= NotchGeometry.ceiling(on: metrics).width)
                #expect(size.height <= 160)
            }
        }
    }

    @Test func turnStatesKeepStableDimensionsThroughTheTurn() {
        let states: [PillState] = [.starting, .listening(level: 0.1), .listening(level: 0.9),
                                   .preview(text: String(repeating: "word ", count: 200)), .finishing(elapsedWarning: true),
                                   .finalPreview(FinalPreviewInfo(text: String(repeating: "long ", count: 300), dwellRemaining: 1)),
                                   .inserting(text: "x"), .landed(LandedPillInfo(text: "x", verified: true))]
        let sizes = Set(states.map { NotchGeometry.size(for: $0, on: notched) { $0.count > 0 ? 9_999 : 0 } }.map { "\($0)" })
        #expect(sizes == ["\(NotchGeometry.activeSize)"])
    }

    // MARK: - Narrow review layout

    @Test func belowFourSixtyTheBayIsAnEightyFourPointCameo() {
        #expect(NotchGeometry.bayWidth(forPillWidth: 560) == 126)
        #expect(NotchGeometry.bayWidth(forPillWidth: 400) == 126)
        #expect(NotchGeometry.bayWidth(forPillWidth: 399) == 84)
        let size = NotchGeometry.size(for: .actionable, on: narrow)
        #expect(size == CGSize(width: 368, height: 160))
        #expect(NotchGeometry.isNarrow(width: size.width))
        let lanes = PillLaneLayout(size: size, hasChip: false, hasActions: true)
        #expect(lanes.bay.width == CGFloat(84 + 20))
        #expect(lanes.wordsLane.width == CGFloat(368 - 40 - 84 - 18))
        // The Spool scene agrees: scale 0.69 below the same width.
        #expect(SpoolScene.placement(width: Double(size.width)).scale == 0.65)
        #expect(SpoolScene.placement(width: 560).scale == 0.8)
    }

    // MARK: - Placement: attached vs floating

    @Test func attachedUnderTheHousingWithSquareUpperCorners() throws {
        let l = NotchGeometry.pillLayout(for: notched)
        #expect(l.attached)
        #expect(l.contentFrame == CGRect(x: 620, y: 970, width: 560, height: 160))
        #expect(l.contentFrame.maxY == 1130)          // flush under the menu bar / housing band
        #expect(l.retracted == CGRect(x: 620, y: 1129, width: 560, height: 1))
        #expect(l.shown.maxY == notched.frame.maxY)
        #expect(l.backgroundCap == notched.topBand)
        #expect(l.cornerRadius == 18)
        let corners = Tokens.Radius.pillCorners(attached: l.attached)
        #expect(corners.topLeading == 0 && corners.topTrailing == 0)
        #expect(corners.bottomLeading == 18 && corners.bottomTrailing == 18)
    }

    @Test func floatingEightPointsBelowAnExternalMenuBarWithAllCornersRounded() {
        let l = NotchGeometry.pillLayout(for: external)
        #expect(l.backgroundCap == 0)
        #expect(!l.attached)
        #expect(l.shown.maxY == CGFloat(1169 - 30 - 8))
        #expect(l.shown.midX == 2760)
        #expect(external.frame.contains(l.shown))
        let corners = Tokens.Radius.pillCorners(attached: l.attached)
        #expect(corners.topLeading == 18 && corners.topTrailing == 18 && corners.bottomLeading == 18)
        // No menu bar at all: still floats 8 pt below the top edge.
        #expect(NotchGeometry.pillLayout(for: externalNoMenuBar).shown.maxY == CGFloat(1080 - 8))
    }

    @Test func menuBarHiddenStillClearsTheHousing() throws {
        let l = NotchGeometry.pillLayout(for: autoHiddenMenuBar, size: NotchGeometry.actionableSize)
        #expect(autoHiddenMenuBar.topBand == 38)
        #expect(l.contentFrame.maxY == 1131)              // exactly the bottom edge of the housing
        #expect(!l.contentFrame.intersects(try #require(autoHiddenMenuBar.notchRect)))
    }

    @Test func offTheGlobalOriginStaysOnItsOwnScreen() {
        let l = NotchGeometry.pillLayout(for: notchedOffOrigin)
        #expect(l.contentFrame == CGRect(x: -1180, y: 1170, width: 560, height: 160))
        #expect(notchedOffOrigin.frame.contains(l.shown))
    }

    // MARK: - The camera housing

    /// Nothing is ever drawn behind the camera housing: every surface, shown or retracted, on every
    /// notched fixture, and every surface lands on its own display.
    @Test func nothingBehindTheCameraHousing() throws {
        let surfaces: [NotchGeometry.Surface] = [.hint(textWidth: 200), .active, .actionable]
        for metrics in all {
            for surface in surfaces {
                let l = NotchGeometry.pillLayout(for: metrics, size: NotchGeometry.size(for: surface, on: metrics))
                #expect(NotchGeometry.clearsHousing(l.contentFrame, on: metrics), "\(surface)")
                #expect(metrics.frame.contains(l.shown))
                if let housing = metrics.notchRect {
                    #expect(!l.retracted.intersects(housing))
                    #expect(l.contentFrame.maxY <= metrics.frame.maxY - metrics.topInset)
                }
            }
        }
    }

    /// The 1.7.9 "black slab": no message, at any length, and no requested size makes the pill bigger
    /// than the compact ceiling.
    @Test func noMessageAndNoRequestProducesASlab() {
        let monstrous = String(repeating: "The file “weight.bin.partial” doesn’t exist and nothing was typed. ", count: 40)
        for metrics in all {
            let ceiling = NotchGeometry.ceiling(on: metrics)
            for state: PillState in [.error(message: monstrous), .unavailable(reason: monstrous), .preview(text: monstrous)] {
                let size = NotchGeometry.size(for: state, on: metrics) { CGFloat($0.count) * 7 }
                #expect(size.width <= ceiling.width && size.height <= ceiling.height)
            }
            let absurd = NotchGeometry.pillLayout(for: metrics, size: CGSize(width: 9_000, height: 9_000))
            #expect(absurd.shown.width <= ceiling.width && absurd.contentFrame.height <= 160)
            #expect(metrics.frame.contains(absurd.shown))
        }
    }

    // MARK: - Display arrangement

    @Test func multiDisplayFollowsTheMouse() throws {
        let screens = [notched, external]
        let onBuiltIn = try #require(NotchGeometry.hostScreen(screens: screens, mouse: CGPoint(x: 900, y: 600), main: notched))
        #expect(onBuiltIn == notched)
        #expect(NotchGeometry.pillLayout(for: onBuiltIn).attached)
        let onExternal = try #require(NotchGeometry.hostScreen(screens: screens, mouse: CGPoint(x: 2700, y: 500), main: notched))
        #expect(onExternal == external)
        #expect(!NotchGeometry.pillLayout(for: onExternal).attached)
        #expect(NotchGeometry.hostScreen(screens: [externalNoMenuBar, external], mouse: CGPoint(x: -5, y: 10), main: external) == external)
        #expect(NotchGeometry.hostScreen(screens: [], mouse: .zero, main: nil) == nil)
    }

    @Test func activeTurnKeepsItsDisplayPinAcrossPointerAndGeometryChanges() throws {
        let builtIn = ScreenMetrics(frame: notched.frame, topInset: 38, notchWidth: 220, menuBarHeight: 39,
                                    displayID: 11)
        let external = ScreenMetrics(frame: self.external.frame, menuBarHeight: 30, displayID: 22)
        let resizedBuiltIn = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                           topInset: 32, notchWidth: 200, menuBarHeight: 32, displayID: 11)

        let resolved = NotchGeometry.resolveDisplayPin(
            builtIn, screens: [resizedBuiltIn, external], mouse: CGPoint(x: 2500, y: 500), main: external)

        #expect(resolved.metrics == resizedBuiltIn, "the same display id wins over pointer and main-screen changes")
        #expect(!resolved.pinnedDisplayLost)
    }

    @Test func removedPinnedDisplayMovesRecoveryToRemainingDisplay() throws {
        let builtIn = ScreenMetrics(frame: notched.frame, topInset: 38, notchWidth: 220, menuBarHeight: 39,
                                    displayID: 11)
        let external = ScreenMetrics(frame: self.external.frame, menuBarHeight: 30, displayID: 22)

        let resolved = NotchGeometry.resolveDisplayPin(
            builtIn, screens: [external], mouse: CGPoint(x: 900, y: 600), main: external)

        #expect(resolved.metrics == external)
        #expect(resolved.pinnedDisplayLost, "only disappearance invalidates the destination")
        let noDisplays = NotchGeometry.resolveDisplayPin(builtIn, screens: [], mouse: .zero, main: nil)
        #expect(noDisplays.metrics == nil)
        #expect(noDisplays.pinnedDisplayLost)
    }

    // MARK: - Lanes inside the pill

    /// Never text under the face: the status row, the words lane and the chip row stay left of the
    /// character bay at every width; the helper and action rows sit below it.
    @Test func noTextIsLaidOutUnderTheCharacter() {
        for width: CGFloat in [560, 500, 400, 399, 368, 300] {
            for hasChip in [false, true] {
                for hasActions in [false, true] {
                    let lanes = PillLaneLayout(size: CGSize(width: width, height: 160),
                                               hasChip: hasChip, hasActions: hasActions)
                    for rect in lanes.textRects {
                        #expect(!rect.intersects(lanes.bay), "width \(width): \(rect) under the bay \(lanes.bay)")
                        #expect(rect.minX >= PillLaneLayout.inset)
                    }
                    #expect(lanes.helperRow.minY >= lanes.bay.maxY)
                    if let actions = lanes.actionRow {
                        #expect(actions.minY == PillLaneLayout.helperY)      // below the character bay
                        #expect(actions.width == width - 40)                    // full width
                        #expect(actions.maxY <= 160)
                    }
                    #expect(lanes.helperRow.maxY <= PillLaneLayout.sceneHeight)
                }
            }
        }
        let wide = PillLaneLayout(size: NotchGeometry.activeSize, hasChip: false, hasActions: false)
        #expect(wide.bay.width == CGFloat(126 + 20))
        #expect(wide.statusRow.width == CGFloat(560 - 40 - 126))                         // ≈ 384 pt (DESIGN.md §8.3)
        #expect(wide.wordsLane.height == 48)                                    // two 20 pt lines
    }

    /// Context annotations share the header; every active state keeps both complete text lines.
    @Test func contextAnnotationsPreserveTwoLinesWithoutMovingTapeOrFooter() throws {
        for width: CGFloat in [560, 500, 400, 399, 368, 300] {
            for hasActions in [false, true] {
                let size = CGSize(width: width, height: 160)
                let plain = PillLaneLayout(size: size, hasChip: false, hasActions: hasActions)
                let annotated = PillLaneLayout(size: size, hasChip: true, hasActions: hasActions)
                let chip = try #require(annotated.chipRow)
                #expect(annotated.lineCount == 2)
                #expect(annotated.wordsLane.height == 48)
                #expect(annotated.wordsLane == plain.wordsLane)
                #expect(annotated.helperRow == plain.helperRow)
                #expect(annotated.actionRow == plain.actionRow)
                #expect(annotated.tapeY == plain.tapeY)
                #expect(chip.minY == annotated.statusRow.minY)
                #expect(chip.maxY < annotated.wordsLane.minY)
                #expect(!chip.intersects(annotated.statusRow))
                #expect(!chip.intersects(annotated.bay))
                #expect(chip.maxX == annotated.wordsLane.maxX)
                #expect(annotated.confidenceLane.maxY == annotated.wordsLane.maxY)
                #expect(annotated.confidenceLane.maxY <= annotated.tapeTop)
                #expect(plain.chipRow == nil)
            }
        }
    }
}
