import CoreGraphics
import Engine
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// Tap to talk (owner request, 2026-10-06): a short tap of the dictation key starts a dictation, the
/// next tap finishes and lands it. Hold-to-talk and double-tap hands-free keep working; a tap over a
/// notice still only dismisses it. Synthetic edges, a manual clock and a mock microphone — no live
/// key, no real model.
@Suite("Tap to talk", .serialized)
struct TapToTalkTests {
    static func machine(latch: Bool = true) -> HotkeyStateMachine {
        var m = HotkeyStateMachine()
        m.tapToTalk = true
        m.doubleTapLatch = latch
        return m
    }

    // MARK: The gesture

    @Test("tap → listening with no key held; tap again (after the window) → finish and land")
    func tapThenTap() {
        var m = Self.machine()
        #expect(m.keyDown(at: 0) == [.startCapture])
        #expect(m.keyUp(at: 0.1) == [.tapToTalk])
        #expect(m.phase == .tapTalking(tapUp: 0.1, armed: true))
        #expect(m.isCapturing && m.isTapTalking)
        #expect(m.lastGesture == .tapToTalk)
        #expect(m.keyDown(at: 3.0) == [], "capture is already running")
        #expect(m.keyUp(at: 3.08) == [.finalize])
        #expect(m.phase == .idle)
        #expect(m.lastGesture == .tapTalkStop)
    }

    @Test("tap, tap inside the double-tap window → hands-free on the same capture; a tap ends it")
    func tapTapIsHandsFree() {
        var m = Self.machine()
        #expect(m.keyDown(at: 0) == [.startCapture])
        #expect(m.keyUp(at: 0.08) == [.tapToTalk])
        #expect(m.keyDown(at: 0.25) == [], "no second capture: the first tap's audio is kept")
        #expect(m.keyUp(at: 0.32) == [.enterLatch])
        #expect(m.phase == .latched)
        #expect(m.lastGesture == .doubleTap)
        #expect(m.keyDown(at: 5) == [])
        #expect(m.keyUp(at: 5.1) == [.finalize])
        #expect(m.lastGesture == .latchStop)
    }

    @Test("hold still holds to talk with tap to talk on")
    func holdStillWorks() {
        var m = Self.machine()
        #expect(m.keyDown(at: 0) == [.startCapture])
        #expect(m.keyUp(at: 1.2) == [.finalize])
        #expect(m.phase == .idle)
        #expect(m.lastGesture == .hold)
    }

    @Test("tap to talk off: a tap cancels as before, a double tap latches as before")
    func offKeepsOldRules() {
        var m = HotkeyStateMachine()
        #expect(m.keyDown(at: 0) == [.startCapture])
        #expect(m.keyUp(at: 0.1) == [.cancelCapture])
        #expect(m.keyDown(at: 0.25) == [.startCapture])
        #expect(m.keyUp(at: 0.3) == [.enterLatch])
    }

    @Test("a 180–250 ms tap starts tap to talk but never arms hands-free (as Claude's tap drop does)")
    func ambiguousTapNotArmed() {
        var m = Self.machine()
        _ = m.keyDown(at: 0)
        #expect(m.keyUp(at: 0.2) == [.tapToTalk])
        #expect(m.phase == .tapTalking(tapUp: 0.2, armed: false))
        _ = m.keyDown(at: 0.3)
        #expect(m.keyUp(at: 0.35) == [.finalize], "a second tap right after just finishes")
    }

    @Test("Double-tap to latch off: the second quick tap finishes the dictation")
    func latchOffSecondTapFinishes() {
        var m = Self.machine(latch: false)
        _ = m.keyDown(at: 0)
        #expect(m.keyUp(at: 0.08) == [.tapToTalk])
        _ = m.keyDown(at: 0.2)
        #expect(m.keyUp(at: 0.26) == [.finalize])
    }

    @Test("a tap while a notice shows only dismisses it; a double tap there still goes hands-free")
    func tapOverNoticeDismisses() {
        var m = Self.machine()
        #expect(m.keyDown(at: 0, surfaceShowing: true) == [.startCapture])
        #expect(m.keyUp(at: 0.1) == [.cancelCapture])
        #expect(m.lastCancel == .tap)
        #expect(m.phase == .idle)
        #expect(m.keyDown(at: 0.3) == [.startCapture])
        #expect(m.keyUp(at: 0.35) == [.enterLatch])
        // A press up to 0.8 s over a notice is a dismissing tap too (X3), never tap to talk.
        var n = Self.machine()
        _ = n.keyDown(at: 0, surfaceShowing: true)
        #expect(n.keyUp(at: 0.6) == [.cancelCapture])
    }

    @Test("a quick re-press right after the finishing tap is folded into it (H29)")
    func rePressFolds() {
        var m = Self.machine()
        _ = m.keyDown(at: 0); _ = m.keyUp(at: 0.1)
        _ = m.keyDown(at: 3); #expect(m.keyUp(at: 3.05) == [.finalize])
        #expect(m.keyDown(at: 3.2) == [], "folded: no new dictation")
        #expect(m.keyUp(at: 3.25) == [])
        #expect(m.lastGesture == .folded)
    }

    // MARK: Chord-cancel only before speech

    @Test("before speech: a chord on the next press, or typing, cancels silently")
    func chordBeforeSpeechCancels() {
        var m = Self.machine()
        _ = m.keyDown(at: 0); _ = m.keyUp(at: 0.1)
        _ = m.keyDown(at: 1)
        #expect(m.otherInput(at: 1.05, speechHeard: false) == [.cancelCapture])
        #expect(m.lastCancel == .chord)
        #expect(m.keyUp(at: 1.1) == [], "the chorded press ends with no action")
        #expect(m.phase == .idle)

        var t = Self.machine()
        _ = t.keyDown(at: 0); _ = t.keyUp(at: 0.1)
        #expect(t.otherInput(at: 0.5, typing: false, speechHeard: false) == [], "a click into the field is fine")
        #expect(t.otherInput(at: 0.6, typing: true, speechHeard: false) == [.cancelCapture], "typing is not dictating")
        #expect(t.lastCancel == .chord)
    }

    @Test("after speech: a chord passes through and the dictation keeps listening")
    func chordAfterSpeechContinues() {
        var m = Self.machine()
        _ = m.keyDown(at: 0); _ = m.keyUp(at: 0.1)
        #expect(m.otherInput(at: 1, typing: true, speechHeard: true) == [])
        _ = m.keyDown(at: 2)
        #expect(m.otherInput(at: 2.05, speechHeard: true) == [])
        #expect(m.isTapTalking)
        #expect(m.keyUp(at: 2.1) == [], "the chord's key-up does not finish")
        _ = m.keyDown(at: 4)
        #expect(m.keyUp(at: 4.05) == [.finalize])
    }

    @Test("silence timeout and ends elsewhere")
    func finishAndAbandon() {
        var m = Self.machine()
        _ = m.keyDown(at: 0); _ = m.keyUp(at: 0.1)
        #expect(m.finishTapTalk(at: 10) == [.finalize])
        #expect(m.phase == .idle)
        #expect(m.finishTapTalk(at: 11) == [], "nothing outside a tap-to-talk dictation")

        var k = Self.machine()
        _ = k.keyDown(at: 0); _ = k.keyUp(at: 0.1); _ = k.keyDown(at: 9)
        #expect(k.finishTapTalk(at: 10) == [.finalize])
        #expect(k.keyUp(at: 10.1) == [], "a key down at the timeout is folded")

        var a = Self.machine()
        _ = a.keyDown(at: 0); _ = a.keyUp(at: 0.1)
        let abandoned = a.abandonTapTalk()
        #expect(abandoned)
        #expect(a.phase == .idle)
        #expect(a.keyDown(at: 1) == [.startCapture], "the next tap starts a new dictation")
        let again = a.abandonTapTalk()
        #expect(!again, "nothing to abandon while a fresh press is down")
    }

    @Test("K02: a lost key-up on the finishing press finishes the dictation")
    func lostKeyUpFinishes() {
        var m = Self.machine()
        _ = m.keyDown(at: 0); _ = m.keyUp(at: 0.1); _ = m.keyDown(at: 2)
        #expect(m.lostKeyUp(at: 2.5) == [.finalize])
        #expect(m.phase == .idle)
    }

    // MARK: The live key (HotkeyService)

    private static let alt = CGEventFlags.maskAlternate.rawValue
    private static let left = alt | HotkeyBinding.Kind.deviceLeftAltMask

    final class Box { var actions: [HotkeyStateMachine.Action] = [] }
    final class Flag: @unchecked Sendable { var value: Bool; init(_ v: Bool) { value = v } }

    private func service(tap: Flag = Flag(true)) -> (HotkeyService, Box) {
        let d = UserDefaults(suiteName: "AppTests.tapToTalk.\(UUID())")!
        let s = HotkeyService(defaults: d)
        s.setBinding(.option)
        s.otherInputWithin = { _ in false }
        s.surfaceShowing = { false }
        s.tapToTalkEnabled = { tap.value }
        let box = Box()
        s.onAction = { box.actions.append($0) }
        return (s, box)
    }

    @Test("the switch applies live, read at every key-down")
    func switchAppliesLive() {
        let on = Flag(false)
        let (s, box) = service(tap: on)
        s.handle(keyCode: 58, flags: Self.left, timestamp: 0)
        s.handle(keyCode: 58, flags: 0, timestamp: 0.1)
        #expect(box.actions == [.startCapture, .cancelCapture])
        on.value = true
        box.actions = []
        s.handle(keyCode: 58, flags: Self.left, timestamp: 2)
        s.handle(keyCode: 58, flags: 0, timestamp: 2.1)
        #expect(box.actions == [.startCapture, .tapToTalk])
        #expect(s.lastPressRecord?.result == "tap-to-talk")
    }

    @Test("a binding change applies live: the new key taps to talk, the old one does nothing")
    func bindingChangeAppliesLive() {
        let (s, box) = service()
        s.handle(keyCode: 58, flags: Self.left, timestamp: 0)
        s.handle(keyCode: 58, flags: 0, timestamp: 0.1)
        #expect(box.actions == [.startCapture, .tapToTalk])
        s.setBinding(.rightCommand)
        #expect(s.machine.phase == .idle, "a binding change resets the gesture")
        box.actions = []
        s.handle(keyCode: 58, flags: Self.left, timestamp: 1)
        s.handle(keyCode: 58, flags: 0, timestamp: 1.1)
        #expect(box.actions.isEmpty, "Option is no longer the key")
        let cmd = CGEventFlags.maskCommand.rawValue
        s.handle(keyCode: 54, flags: cmd, timestamp: 2)
        s.handle(keyCode: 54, flags: 0, timestamp: 2.1)
        s.handle(keyCode: 54, flags: cmd, timestamp: 4)
        s.handle(keyCode: 54, flags: 0, timestamp: 4.1)
        #expect(box.actions == [.startCapture, .tapToTalk, .finalize])
    }

    @Test("the act key never taps to talk")
    func actKeyNever() {
        let d = UserDefaults(suiteName: "AppTests.tapToTalk.act.\(UUID())")!
        let act = HotkeyService(defaults: d, bindingKey: HotkeyService.actBindingDefaultsKey, defaultBinding: HotkeyBinding(kind: .rightCommand))
        act.otherInputWithin = { _ in false }
        var actions: [HotkeyStateMachine.Action] = []
        act.onAction = { actions.append($0) }
        let cmd = CGEventFlags.maskCommand.rawValue
        act.handle(keyCode: 54, flags: cmd, timestamp: 0)
        act.handle(keyCode: 54, flags: 0, timestamp: 0.1)
        #expect(actions == [.startCapture, .cancelCapture])
    }

    @Test("service: silence finish, Escape-style abandon, and chord-cancel reading speech")
    func serviceEdges() {
        let heard = Flag(false)
        let (s, box) = service()
        s.speechHeard = { heard.value }
        s.handle(keyCode: 58, flags: Self.left, timestamp: 0)
        s.handle(keyCode: 58, flags: 0, timestamp: 0.1)
        s.finishTapToTalk(reason: "test")
        #expect(box.actions == [.startCapture, .tapToTalk, .finalize])

        box.actions = []
        s.handle(keyCode: 58, flags: Self.left, timestamp: 5)
        s.handle(keyCode: 58, flags: 0, timestamp: 5.1)
        s.abandonTapToTalk()
        #expect(s.machine.phase == .idle)
        box.actions = []
        s.handle(keyCode: 58, flags: Self.left, timestamp: 8)
        #expect(box.actions == [.startCapture], "after Escape the next tap starts a new dictation")
        s.handle(keyCode: 58, flags: 0, timestamp: 8.1)

        box.actions = []
        heard.value = true
        s.noteOtherInput(at: 9, kind: "key")
        #expect(box.actions.isEmpty, "typing after speech never cancels")
        heard.value = false
        s.noteOtherInput(at: 9.5, kind: "click")
        #expect(box.actions.isEmpty, "a click never cancels")
    }

    // MARK: The running dictation's silence timeout

    @Test("silence timeout: armed at the tap, held off by speech, counted from the last speech end")
    func watchTimeout() {
        let clock = TurnControllerTests.ManualClock()
        let watch = TapToTalkWatch()
        watch.clock = clock
        watch.silenceTimeout = { 10 }
        var fired = 0, ended = 0
        watch.onSilence = { fired += 1 }
        watch.onEnded = { ended += 1 }
        watch.captureStarting()
        watch.begin()
        clock.advance(4)
        watch.noteSpeech(true)
        clock.advance(20)
        #expect(fired == 0, "never while speaking")
        #expect(watch.heardSpeech)
        watch.noteSpeech(false)
        clock.advance(9.9)
        #expect(fired == 0)
        clock.advance(0.2)
        #expect(fired == 1)
        watch.end()
        #expect(ended == 1)
        watch.end()
        #expect(ended == 1, "only a running dictation ends")
        clock.advance(30)
        #expect(fired == 1)
    }

    @Test("silence timeout with no speech at all; new live words count as speech")
    func watchNoSpeechAndWords() {
        let clock = TurnControllerTests.ManualClock()
        let watch = TapToTalkWatch()
        watch.clock = clock
        watch.silenceTimeout = { 10 }
        var fired = 0
        watch.onSilence = { fired += 1 }
        watch.captureStarting()
        watch.begin()
        clock.advance(6)
        watch.noteWords("hello")
        clock.advance(6)
        #expect(fired == 0, "new words re-arm")
        watch.noteWords("hello")
        clock.advance(4.1)
        #expect(fired == 1, "the same words again are not new speech")
        #expect(watch.heardSpeech)
        watch.captureStarting()
        #expect(!watch.heardSpeech, "a new capture has heard nothing")
    }

    @Test("a refused press abandons the gesture once")
    func abandonNotifiesOnce() {
        let watch = TapToTalkWatch()
        var ended = 0
        watch.onEnded = { ended += 1 }
        watch.abandon()
        #expect(ended == 1)
        watch.begin()
        watch.abandon()
        #expect(ended == 2)
    }

    @Test("settings: on by default, 10 s default, clamped to 3–30 s")
    func settings() {
        let store = InMemorySettingsStore()
        #expect(TapToTalkSettings.isEnabled(store))
        #expect(TapToTalkSettings.isEnabled(nil))
        #expect(TapToTalkSettings.silenceSeconds(store) == 10)
        TapToTalkSettings.setSilenceSeconds(60, store: store)
        #expect(TapToTalkSettings.silenceSeconds(store) == 30)
        TapToTalkSettings.setSilenceSeconds(1, store: store)
        #expect(TapToTalkSettings.silenceSeconds(store) == 3)
        TapToTalkSettings.setEnabled(false, store: store)
        #expect(!TapToTalkSettings.isEnabled(store))
    }

    // MARK: End to end — key → coordinator → turn → landing

    final class Words: FinalRecognizer, @unchecked Sendable {
        let name = "words"
        private let lock = NSLock()
        private var _received: [Int] = []
        var received: [Int] { lock.withLock { _received } }
        func recognize(_ samples: [Float]) async throws -> [TranscriptSpan] {
            lock.withLock { _received.append(samples.count) }
            return samples.isEmpty ? [] : TurnControllerTests.words("hello there")
        }
    }

    final class Provider: RecognizerProvider, @unchecked Sendable {
        let final: FinalRecognizer
        init(final: FinalRecognizer) { self.final = final }
        func resolve() async throws -> (final: FinalRecognizer, preview: PreviewRecognizer?) { (final, nil) }
    }

    struct Rig {
        let h = TurnControllerTests.Harness(dwell: .immediate)
        let words = Words()
        let mic = LaunchColdPressTests.Mic()
        let engine: RealEngine
        let coordinator: DictationCoordinator
        let hotkey: HotkeyService
        let settings = InMemorySettingsStore()

        @MainActor
        init() {
            engine = RealEngine(audio: mic, provider: Provider(final: words))
            coordinator = DictationCoordinator(engine: engine, database: nil, pill: PillPanelController())
            coordinator.turns = h.controller
            coordinator.tapToTalk.clock = h.clock
            let d = UserDefaults(suiteName: "AppTests.tapToTalk.rig.\(UUID())")!
            hotkey = HotkeyService(defaults: d)
            hotkey.setBinding(.option)
            hotkey.otherInputWithin = { _ in false }
            hotkey.surfaceShowing = { false }
            let coordinator = self.coordinator
            hotkey.onAction = { coordinator.handle($0) }
            TapToTalkWiring.attach(hotkey: hotkey, coordinator: coordinator, settings: settings, showNote: { _ in })
        }

        func tap(at t: TimeInterval) {
            hotkey.handle(keyCode: 58, flags: TapToTalkTests.left, timestamp: t)
            hotkey.handle(keyCode: 58, flags: 0, timestamp: t + 0.08)
        }

        func settles(within seconds: TimeInterval) async -> Bool {
            let done = LaunchColdPressTests.Flag()
            let coordinator = self.coordinator
            Task { await coordinator.settle(); done.raise() }
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if done.value { return true }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            return done.value
        }
    }

    @Test("tap → speak → tap lands the words, through the same turn path as a hold")
    @MainActor func tapSpeakTapLands() async throws {
        let rig = Rig()
        rig.tap(at: 0)
        #expect(rig.coordinator.tapToTalk.isActive)
        #expect(await rig.settles(within: 5))
        let id = try #require(rig.coordinator.currentTurn)
        #expect(rig.mic.isOpen, "capture keeps running after the tap's key-up")
        rig.mic.speak(seconds: 1.0)
        rig.tap(at: 3)
        #expect(!rig.coordinator.tapToTalk.isActive)
        #expect(await rig.settles(within: 10))
        #expect(rig.mic.stops == 1)
        #expect(rig.words.received == [16_000])
        #expect(await rig.h.wait { rig.h.field.contains("hello there") }, "the words land in the field")
        #expect(rig.h.store.entry(id) != nil, "a real turn record, like a hold")
        #expect(rig.hotkey.machine.phase == .idle)
    }

    @Test("the silence timeout finishes and lands what was said")
    @MainActor func silenceTimeoutLands() async throws {
        let rig = Rig()
        rig.tap(at: 0)
        #expect(await rig.settles(within: 5))
        rig.mic.speak(seconds: 0.5)
        rig.coordinator.tapToTalk.noteSpeech(true)
        rig.coordinator.tapToTalk.noteSpeech(false)
        rig.h.clock.advance(TapToTalkSettings.defaultSilenceSeconds + 0.1)
        #expect(rig.hotkey.machine.phase == .idle, "the gesture ended with the dictation")
        #expect(await rig.settles(within: 10))
        #expect(rig.words.received == [8_000])
        #expect(await rig.h.wait { rig.h.field.contains("hello there") })
    }

    @Test("Escape (a cancel from elsewhere) resets the gesture; the next tap starts a new dictation")
    @MainActor func escapeResetsGesture() async throws {
        let rig = Rig()
        rig.tap(at: 0)
        #expect(await rig.settles(within: 5))
        rig.coordinator.cancel()
        #expect(rig.hotkey.machine.phase == .idle)
        #expect(await rig.settles(within: 5))
        rig.tap(at: 2)
        #expect(rig.coordinator.tapToTalk.isActive)
        #expect(await rig.settles(within: 5))
        #expect(rig.mic.starts == 2)
        rig.coordinator.cancel()
        #expect(await rig.settles(within: 5))
    }

    @Test("tap, tap → hands-free on the first tap's capture")
    @MainActor func tapTapHandsFree() async throws {
        let rig = Rig()
        rig.hotkey.handle(keyCode: 58, flags: Self.left, timestamp: 0)
        rig.hotkey.handle(keyCode: 58, flags: 0, timestamp: 0.08)
        rig.hotkey.handle(keyCode: 58, flags: Self.left, timestamp: 0.25)
        rig.hotkey.handle(keyCode: 58, flags: 0, timestamp: 0.31)
        #expect(rig.coordinator.latched)
        #expect(!rig.coordinator.tapToTalk.isActive)
        #expect(await rig.settles(within: 5))
        #expect(rig.mic.starts == 1, "one capture, from the first tap")
        rig.coordinator.handle(.finalize)
        #expect(await rig.settles(within: 10))
    }

    @Test("tap with no speech, finished quickly → vanishes (no row); after 0.6 s → Didn’t hear anything")
    func noSpeechThresholds() async throws {
        // The turn side is the hold's (H1): the capture length decides.
        let quick = TurnControllerTests.Harness()
        let fast = try #require(await TurnGestureTapSilenceTests.silentHold(quick, held: 0.45))
        #expect(quick.events.notices.isEmpty)
        #expect(quick.store.entry(fast)?.stage == .empty)
        let slow = TurnControllerTests.Harness()
        _ = try #require(await TurnGestureTapSilenceTests.silentHold(slow, held: 10))
        #expect(slow.events.notices == [.A06])
    }

    // MARK: Surfaces

    @Test("shortcut test panel: tap → tap to talk; tap → finished; tap tap → Latch")
    func shortcutTestPanel() {
        var p = ShortcutTestProbe()
        p.edge(.down, at: 0, latchEnabled: true, tapToTalk: true)
        p.edge(.up, at: 0.1, latchEnabled: true, tapToTalk: true)
        #expect(p.result == .tapTalking)
        #expect(p.message(key: "Option") == "Tap — tap to talk. Speak, then tap Option again to finish.")
        p.edge(.down, at: 2, latchEnabled: true, tapToTalk: true)
        p.edge(.up, at: 2.1, latchEnabled: true, tapToTalk: true)
        #expect(p.result == .tapTalkFinished)
        var q = ShortcutTestProbe()
        q.edge(.down, at: 0, latchEnabled: true, tapToTalk: true)
        q.edge(.up, at: 0.08, latchEnabled: true, tapToTalk: true)
        q.edge(.down, at: 0.2, latchEnabled: true, tapToTalk: true)
        q.edge(.up, at: 0.26, latchEnabled: true, tapToTalk: true)
        #expect(q.result == .latched)
        var r = ShortcutTestProbe()
        r.edge(.down, at: 0, latchEnabled: true, tapToTalk: true)
        r.edge(.up, at: 0.9, latchEnabled: true, tapToTalk: true)
        #expect(r.result == .hold(seconds: 0.9))
    }

    @Test("launch gate replays a tap-to-talk press made before the container landed")
    func launchGateReplays() {
        var shown: [PillState] = []
        let gate = LaunchPressGate(present: { shown.append($0) }, dismiss: {})
        gate.handle(.startCapture)
        gate.handle(.tapToTalk)
        var replayed: [HotkeyStateMachine.Action] = []
        gate.containerReady { replayed.append($0) }
        #expect(replayed == [.startCapture, .tapToTalk])
    }

    @Test("deixis: the tap's key-up releases drawing; the finish arrives from idle and is forwarded")
    func deixisArbiter() {
        var a = DeixisKeyArbiter()
        _ = a.handle(.startCapture, sessionLatched: false, drawWithoutKey: false)
        let up = a.handle(.tapToTalk, sessionLatched: false, drawWithoutKey: false)
        #expect(up.forward == [.tapToTalk])
        #expect(up.overlay == .hide(fading: false))
        #expect(up.capture == .release)
        #expect(!a.isKeyDown)
        let finish = a.handle(.finalize, sessionLatched: false, drawWithoutKey: false)
        #expect(finish.forward == [.finalize])
    }

    @Test("copy names the bound key: ready hint, lane note, onboarding, Settings")
    func copyNamesKey() {
        #expect(PillState.readyHint(key: "Option", latchEnabled: true, tapToTalk: true) == "Tap, Hold or Double Tap Option to dictate")
        #expect(PillState.readyHint(key: "Right Command", latchEnabled: false, tapToTalk: true) == "Tap or Hold Right Command to dictate")
        #expect(PillState.readyHint(key: "Option") == "Hold or Double Tap Option to dictate", "tap to talk off: unchanged")
        let store = InMemorySettingsStore()
        #expect(LatchGestureHook.readyHint(binding: HotkeyBinding(kind: .fn), settings: store)
                == "Tap, Hold or Double Tap fn / 🌐 to dictate")
        TapToTalkSettings.setEnabled(false, store: store)
        #expect(LatchGestureHook.readyHint(binding: HotkeyBinding(kind: .fn), settings: store)
                == "Hold or Double Tap fn / 🌐 to dictate")
        #expect(TapToTalkCopy.finishNote("Option") == "Tap Option to finish · Esc cancels")
        #expect(OnboardingCopy.copy(for: .firstDictation, key: "Right Command").body
                .contains("Or tap Right Command once, speak, and tap again to finish."))
        #expect(ShortcutCopy.explanation(key: "Option", tapToTalk: true).contains("Tap Option once"))
        #expect(!ShortcutCopy.explanation(key: "Option", tapToTalk: false).contains("Tap Option"))
        #expect(HotkeyPressRecord.result(of: [.tapToTalk]) == "tap-to-talk")
    }
}
