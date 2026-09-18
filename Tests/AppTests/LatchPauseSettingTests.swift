import Engine
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// B2 (V4.33) — "Insert after a pause of" 1.0–5.0 s, default 2.0 s, read through `SettingsStore`
/// into the latch endpointer (`trailingSilence = pause`, `noSpeechTimeout = 8`, `maxUtterance = 30`),
/// live while latched. The row itself is S7g's (Shortcuts subpage).
@Suite("Latch pause setting (B2)")
@MainActor
struct LatchPauseSettingTests {

    // MARK: the setting

    @Test("round trip through the store, with the default, the bounds and a tenth of a second")
    func roundTrip() {
        let store = InMemorySettingsStore()
        #expect(LatchSettings.pauseSeconds(store) == 2.0, "the default is 2 s")
        #expect(LatchSettings.pauseSeconds(nil) == 2.0)

        LatchSettings.setPauseSeconds(3.5, store: store, center: NotificationCenter())
        #expect(store.string(SettingsKeys.latchPauseSeconds) == "3.5")
        #expect(LatchSettings.pauseSeconds(store) == 3.5)

        LatchSettings.setPauseSeconds(0.2, store: store, center: NotificationCenter())
        #expect(LatchSettings.pauseSeconds(store) == 1.0, "below the range")
        LatchSettings.setPauseSeconds(9, store: store, center: NotificationCenter())
        #expect(LatchSettings.pauseSeconds(store) == 5.0, "above the range")
        LatchSettings.setPauseSeconds(2.04, store: store, center: NotificationCenter())
        #expect(LatchSettings.pauseSeconds(store) == 2.0)

        store.set("not a number", for: SettingsKeys.latchPauseSeconds)
        #expect(LatchSettings.pauseSeconds(store) == 2.0, "an unreadable value falls back to the default")
        store.set("12", for: SettingsKeys.latchPauseSeconds)
        #expect(LatchSettings.pauseSeconds(store) == 5.0, "a hand-edited value is still bounded")
        #expect(SettingsKeys.latchPauseSeconds == "latch.pauseSeconds")
    }

    @Test("round trip through UserDefaults, the production store")
    func userDefaultsRoundTrip() throws {
        let suite = "voiceplus.b2.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsSettingsStore(defaults: defaults)
        #expect(LatchSettings.pauseSeconds(store) == 2.0)
        LatchSettings.setPauseSeconds(4.2, store: store, center: NotificationCenter())
        #expect(LatchSettings.pauseSeconds(UserDefaultsSettingsStore(defaults: defaults)) == 4.2)
    }

    @Test("writing the setting announces it")
    func writingPostsTheChange() {
        let center = NotificationCenter()
        var posted = 0
        let token = center.addObserver(forName: LatchSettings.didChangeNotification, object: nil, queue: nil) { _ in posted += 1 }
        defer { center.removeObserver(token) }
        LatchSettings.setPauseSeconds(3, store: InMemorySettingsStore(), center: center)
        #expect(posted == 1)
        LatchSettings.setPauseSeconds(3, store: nil, center: center)
        #expect(posted == 1, "nothing was written, so nothing changed")
    }

    @Test("the endpointer for a pause")
    func endpointerForAPause() {
        let e = LatchSettings.endpointer(pauseSeconds: 2.5)
        #expect(e.trailingSilence == 2.5)
        #expect(e.noSpeechTimeout == 8)
        #expect(e.maxUtterance == 30)
        #expect(LatchSettings.endpointer(pauseSeconds: 0).trailingSilence == 1.0)
    }

    // MARK: the latch reads it

    @Test("binding the store builds the latch endpointer from the setting")
    func bindingBuildsTheEndpointer() {
        let store = InMemorySettingsStore()
        LatchSettings.setPauseSeconds(3.0, store: store, center: NotificationCenter())
        let rig = LatchLoopRig(settings: store)
        #expect(rig.latch.endpointer.trailingSilence == 3.0)
        #expect(rig.latch.endpointer.noSpeechTimeout == 8)
        #expect(rig.latch.endpointer.maxUtterance == 30)
        #expect(rig.session.latchPauseSeconds == 3.0)
    }

    @Test("an unbound latch keeps the endpointer it was given")
    func unboundLatchIsUntouched() {
        let rig = LatchLoopRig(settings: nil)
        #expect(rig.latch.endpointer.trailingSilence == 1.2)
    }

    @Test("a change rebuilds the endpointer — live, mid-segment, and on the pipeline")
    func changeRebuildsTheEndpointerLive() async throws {
        typealias S = ScriptedLatchCapture
        let store = InMemorySettingsStore()
        let center = NotificationCenter()
        var rig = LatchLoopRig(script: ["after three seconds"], settings: store, center: center)
        let capture = ScriptedLatchCapture()
        try await rig.latch(on: capture)
        #expect(capture.audio.pipeline.options.endpointer.trailingSilence == 2.0)

        // A segment is under way: 0.5 s of speech, then 1.5 s of silence so far.
        await capture.play(S.speech(0.5) + S.silence(1.5), into: rig.latch)

        LatchSettings.setPauseSeconds(3.0, store: store, center: center)
        await latchWait("the new pause") { rig.latch.endpointer.trailingSilence == 3.0 }
        #expect(rig.latch.endpointer.noSpeechTimeout == 8)
        #expect(rig.latch.endpointer.maxUtterance == 30)
        #expect(capture.audio.pipeline.options.endpointer.trailingSilence == 3.0, "the pipeline kept the old pause")

        await capture.play(S.silence(0.9), into: rig.latch)          // 2.4 s: past 2, short of 3
        await rig.flush()
        #expect(rig.latch.endpointClosures == 0, "the old pause closed the segment")
        await capture.play(S.silence(0.7), into: rig.latch)          // 3.1 s ≥ 3
        await rig.wait(outcomes: 1)
        #expect(rig.latch.endpointClosures == 1)
        #expect(rig.spy.delivered.map(\.text) == ["after three seconds"], "the segment's speech was lost")
        capture.stop()
    }

    @Test("the next latch uses the pause set between sessions")
    func nextLatchUsesTheNewPause() async throws {
        typealias S = ScriptedLatchCapture
        let store = InMemorySettingsStore()
        let center = NotificationCenter()
        var rig = LatchLoopRig(settings: store, center: center)
        LatchSettings.setPauseSeconds(1.5, store: store, center: center)
        await latchWait("the new pause") { rig.latch.endpointer.trailingSilence == 1.5 }
        let capture = ScriptedLatchCapture()
        try await rig.latch(on: capture)
        #expect(capture.audio.pipeline.options.endpointer.trailingSilence == 1.5)
        await capture.play(S.speech(0.5) + S.silence(1.3), into: rig.latch)   // short of 1.5
        await rig.flush()
        #expect(rig.latch.endpointClosures == 0)
        await capture.play(S.silence(0.3), into: rig.latch)                   // 1.6 s ≥ 1.5
        await rig.wait(outcomes: 1)
        #expect(rig.latch.endpointClosures == 1)
        capture.stop()
    }

    @Test("a latch driven by hand closes on its own endpointer at the new pause")
    func handDrivenRuntimeUsesThePause() async {
        let spy = LatchFocusSpy()
        let runtime = LatchRuntime(delivery: spy)
        runtime.isLatched = { true }
        runtime.setPauseSeconds(3.0)
        #expect(runtime.endpointer.trailingSilence == 3.0)
        #expect(runtime.endpointer.maxUtterance == LatchSettings.maxSegmentSeconds)
        runtime.sessionStarted()
        runtime.noteVAD(.speechStart(at: 0.2))
        runtime.noteVAD(.speechEnd(at: 1.0))
        runtime.tick(at: 3.5)                                        // 2.5 s: the old 2 s would close
        #expect(runtime.endpointClosures == 0)
        runtime.setPauseSeconds(2.0)                                 // live, mid-pause
        runtime.tick(at: 3.6)
        #expect(runtime.endpointClosures == 1)
    }
}
