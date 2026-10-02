import AppKit
import Combine
import Foundation
import Shared
import SwiftUI
import Testing
@testable import VoicePlusApp

/// S10 — Reduce Motion (design §11, §11.1): the motion flag gives a static pose, no flight, no twist,
/// no animated transitions, a numeric level readout in place of tape motion, and state labels and
/// dwell exactly as without it. Plus Larger Text: the window root scales and reflows; the pill stays
/// bounded and keeps overflow in a directly scrollable transcript.
@Suite("S10 — Reduce Motion and Larger Text")
struct MotionAccessibilityS10Tests {

    // MARK: - The policy

    @Test("the motion flag is the system switch or the app's, never less than the system asks for")
    func policyTable() {
        for system in [false, true] {
            for app in [false, true] {
                let policy = MotionPolicy(system: system, app: app)
                let store = InMemorySettingsStore()
                AppearanceSettings.setReducesMotion(app, store: store)
                #expect(policy.reduced == (system || app))
                #expect(policy.reduced == AppearanceSettings.effectiveReduceMotion(store, system: system),
                        "one rule for every surface, S4's flight included")
                #expect(policy.drawsStillSpool == policy.reduced)
                #expect(policy.allowsTapeFlight == !policy.reduced, "no flight under Reduce Motion")
                #expect(policy.transitionDuration == (policy.reduced ? 0 : 0.18))
                #expect((policy.transition == nil) == policy.reduced)
            }
        }
        // design §11: 160–220 ms ease-out when motion is allowed.
        #expect((0.16...0.22).contains(MotionPolicy(system: false, app: false).transitionDuration))
    }

    @Test("the live preference follows the app switch and macOS, and publishes only on change")
    @MainActor   // notifications on the main thread are applied at once; others hop to it
    func livePreference() {
        let store = InMemorySettingsStore()
        var system = false
        let center = NotificationCenter(), workspace = NotificationCenter()
        let motion = MotionPreference(store: store, system: { system }, center: center, workspaceCenter: workspace)
        var published: [Bool] = []
        let sub = motion.$policy.dropFirst().sink { published.append($0.reduced) }
        defer { sub.cancel() }
        #expect(motion.reduced == false)

        AppearanceSettings.setReducesMotion(true, store: store)
        center.post(name: UserDefaults.didChangeNotification, object: nil)
        #expect(motion.reduced == true)
        #expect(motion.policy == MotionPolicy(system: false, app: true))

        center.post(name: UserDefaults.didChangeNotification, object: nil)   // nothing changed
        AppearanceSettings.setReducesMotion(false, store: store)
        system = true
        workspace.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        #expect(motion.reduced == true, "macOS Reduce Motion always applies")
        system = false
        workspace.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        #expect(motion.reduced == false)
        #expect(published == [true, true, false], "one publication per real change")
    }

    // MARK: - Motion flag → static pose

    @Test("Spool follows the preference unless a host overrides it")
    func spoolFollowsThePreference() {
        let appOn = MotionPolicy(system: false, app: true), off = MotionPolicy(system: false, app: false)
        #expect(SpoolView.reducesMotion(explicit: nil, system: false, policy: appOn))
        #expect(SpoolView.reducesMotion(explicit: nil, system: true, policy: off))
        #expect(!SpoolView.reducesMotion(explicit: nil, system: false, policy: off))
        #expect(SpoolView.reducesMotion(explicit: true, system: false, policy: off), "a still surface stays still")
        #expect(!SpoolView.reducesMotion(explicit: false, system: true, policy: appOn), "an explicit override wins")
    }

    @Test("under the motion flag every pose is its still frame: parked reels, flat tape, no twist, one frame")
    func staticPose() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        for key in SpoolStateKey.allCases {
            let animator = SpoolAnimator()
            var frames: [SpoolScene.Frame] = []
            for (offset, level) in [(0.0, 0.0), (0.4, 0.9), (1.7, 0.35), (6.2, 1.0)] {
                frames.append(animator.frame(key, stateStartedAt: start, level: level,
                                             at: start.addingTimeInterval(offset), reduceMotion: true, width: 560))
            }
            #expect(frames.allSatisfy { $0.drawing == frames[0].drawing }, "\(key): one drawing whatever the time or level")
            #expect(frames.allSatisfy { $0.activity == 0 }, "\(key): the tape does not move with the microphone")
            #expect(animator.reel.angle == 0, "\(key): no reel rotation")
            #expect(frames[0] == SpoolScene.frame(key, t: 0, width: 560, still: true, angle: 0, drive: .capture(level: 0)))
            // Flat tape: every lane sample sits on the rest curve (no wave, no twist).
            let lane = frames[0].lane, inlet = frames[0].inlet
            for (i, point) in lane.enumerated() {
                let u = Double(i) / Double(lane.count - 1)
                let rest = SpoolMath.mix(SpoolScene.tapeStart.y, inlet.y, SpoolMath.pow(u, 9))
                #expect(abs(point.y - rest) < 1e-9, "\(key): tape sample \(i) is displaced")
            }
            // One frame, no loop (S1.5): nothing keeps drawing.
            #expect(SpoolPoseTable.loopEnd(key, start: start, reduceMotion: true) == nil)
            #expect(!SpoolPoseTable.animates(key, t: 0.5, reduceMotion: true))
        }
    }

    @Test("without the flag the same live pose moves, so the static pose is the flag's doing")
    func liveContrast() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        let animator = SpoolAnimator()
        _ = animator.frame(.listening, stateStartedAt: start, level: 0.8, at: start, reduceMotion: false, width: 560)
        let later = animator.frame(.listening, stateStartedAt: start, level: 0.8, at: start.addingTimeInterval(0.5),
                                   reduceMotion: false, width: 560)
        #expect(later.activity > 0)
        #expect(animator.reel.angle < 0, "listening turns counterclockwise when motion is allowed")
    }

    // MARK: - The numeric readout

    @Test("the level readout is a number in 5 % steps, clamped")
    func readoutText() {
        #expect(LevelReadout.percent(level: 0) == 0)
        #expect(LevelReadout.percent(level: 0.42) == 40)
        #expect(LevelReadout.percent(level: 0.43) == 45)
        #expect(LevelReadout.percent(level: 1.7) == 100)
        #expect(LevelReadout.percent(level: -0.2) == 0)
        #expect(LevelReadout.percent(level: .nan) == 0)
        #expect(LevelReadout.text(level: 0.42) == "Level 40%")
    }

    @Test("the readout replaces capture motion only while capture is live, and only under the flag")
    func readoutStates() {
        let reduced = MotionPolicy(system: false, app: true), normal = MotionPolicy(system: false, app: false)
        for key in SpoolStateKey.allCases {
            #expect(reduced.showsLevelReadout(for: key) == SpoolPoseTable.isLive(key), "\(key)")
            #expect(!normal.showsLevelReadout(for: key), "\(key): never with motion allowed")
        }
        #expect(reduced.showsLevelReadout(for: .listening))
        #expect(!reduced.showsLevelReadout(for: .preview), "no microphone, no level")
    }

    @Test("the readout sits in the tape lane: never in the character bay, the transcript, its marks or the helper row")
    func readoutPlacement() {
        for width in [NotchGeometry.activeSize.width, 420, 360] {
            for hasChip in [false, true] {
                for hasActions in [false, true] {
                    let lanes = PillLaneLayout(size: CGSize(width: width, height: 164), hasChip: hasChip, hasActions: hasActions)
                    let rect = LevelReadout.rect(in: lanes)
                    #expect(!rect.intersects(lanes.bay), "width \(width): under the character")
                    for text in lanes.textRects {
                        #expect(!rect.intersects(text), "width \(width): over text or marks")
                    }
                    #expect(!rect.intersects(lanes.helperRow))
                    #expect(rect.minY >= lanes.tapeY + SpoolScene.tapeWidth / 2, "below the flat 8 pt tape")
                    #expect(rect.maxY <= lanes.helperRow.minY, "above the helper row")
                    #expect(rect.minX >= lanes.statusRow.minX && rect.maxX <= lanes.statusRow.maxX, "in the text column")
                }
            }
        }
    }

    // MARK: - Labels and dwell unchanged

    @Test("Reduce Motion changes no state label, no dwell and no order")
    func labelsAndDwellUnchanged() {
        let store = InMemorySettingsStore()
        let dwell = TurnSettings.previewDwell(store)
        let context = PillTurnContext(destination: "Mail", startedAt: Date(timeIntervalSinceReferenceDate: 0),
                                      now: Date(timeIntervalSinceReferenceDate: 6), liveText: "Can we meet")
        let states: [PillState] = [.starting, .listening(level: 0.4), .listeningQuiet, .latched(elapsed: 6),
                                   .finishing(elapsedWarning: false),
                                   .finalPreview(FinalPreviewInfo(text: "Can we meet?", uncertainCount: 1, dwellRemaining: 1.8)),
                                   .landed(LandedPillInfo(text: "Can we meet?", verified: true))]
        let before = states.map { PillContent.make($0, context: context) }
        AppearanceSettings.setReducesMotion(true, store: store)
        #expect(TurnSettings.previewDwell(store) == dwell)
        #expect(states.map { PillContent.make($0, context: context) } == before)
    }

    // MARK: - Larger Text

    @Test("Larger Text reflows the window only above the default size")
    func reflowThreshold() {
        #expect(!WindowReflow.reflows(scale: WindowTextSize.standard.scale))
        #expect(WindowReflow.reflows(scale: WindowTextSize.large.scale))
        #expect(WindowReflow.reflows(scale: WindowTextSize.larger.scale))
        for size in WindowTextSize.allCases { #expect(WindowReflow.scale(for: size) == size.scale) }
    }

    @Test("the window root hands Larger Text to everything under it, and follows the setting live")
    @MainActor
    func windowRootScale() {
        let store = InMemorySettingsStore()
        let general = GeneralSettingsViewModel(store: store, applyTheme: { _ in })
        let probe = ScaleProbe()
        func render() -> CGFloat? {
            probe.seen = nil
            let view = ScaleProbeView(probe: probe).windowTextScaleRoot(general).frame(width: 200, height: 40)
            _ = ImageRenderer(content: view).nsImage
            return probe.seen
        }
        #expect(render() == 1)
        general.textSize = .larger
        #expect(render() == WindowTextSize.larger.scale)
        #expect(AppearanceSettings.textSize(store) == .larger)
    }

    @Test("the pill stays bounded under Larger Text and long text remains directly scrollable")
    @MainActor
    func pillBoundedWithScrollableTranscript() {
        let store = InMemorySettingsStore()
        AppearanceSettings.setTextSize(.larger, store: store)
        let text = Array(repeating: "Can we meet with Mira on Friday", count: 6).joined(separator: " ")
        let lanes = PillLaneLayout(size: NotchGeometry.activeSize, hasChip: false, hasActions: false)
        #expect(PillLaneLayout(size: NotchGeometry.activeSize, hasChip: false, hasActions: false) == lanes,
                "the pill's geometry has no text-size input")
        let model = PillViewModel()
        let viewport = PillTranscriptViewport(frame: CGRect(x: 0, y: 0,
            width: lanes.wordsLane.width + 20, height: lanes.wordsLane.height))
        viewport.configure(model: model, words: .final(text), marks: .empty)
        viewport.layout()
        #expect(viewport.frame.height == lanes.wordsLane.height)
        #expect(viewport.text.frame.height > viewport.scroll.contentSize.height)
        #expect(!viewport.track.isHidden)
        let content = PillContent.make(.finalPreview(FinalPreviewInfo(text: text, dwellRemaining: 0.9, manual: true)),
                                       context: PillTurnContext(destination: "Mail"))
        #expect(PillReadingOrder.focusChain(content).map(\.action) == [.commit, .editDraft, .cancel])
    }
}

/// Records the `windowTextScale` a view sees when it is drawn.
private final class ScaleProbe {
    var seen: CGFloat?
}

private struct ScaleProbeView: View {
    let probe: ScaleProbe
    @Environment(\.windowTextScale) private var scale

    var body: some View {
        probe.seen = scale
        return Text("Aa")
    }
}
