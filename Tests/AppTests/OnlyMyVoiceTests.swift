import Engine
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// V5 K3 — Settings › Voice "Only react to my voice": default on, effective once the voice is known
/// (enrolled / M6 voiceprint), read live by the latch speaker filter; honest status line.
@Suite("V5 K3 OnlyMyVoice")
struct OnlyMyVoiceTests {
    typealias Rig = PassiveEnrollmentLatchTests

    @Test("default on with nothing stored; the switch persists under voice.onlyMyVoice")
    func defaults() {
        let store = InMemorySettingsStore()
        #expect(OnlyMyVoiceSettings.isOn(store))
        #expect(OnlyMyVoiceSettings.isOn(nil))
        OnlyMyVoiceSettings.set(false, store: store)
        #expect(store.bool(OnlyMyVoiceSettings.key) == false)
        #expect(!OnlyMyVoiceSettings.isOn(store))
    }

    @Test("status: on only once the voice is known and can be told apart; otherwise it says why")
    func status() {
        let notYou = NotYouHistory(corrections: 0, thresholdFloor: nil)
        #expect(OnlyMyVoiceStatus(preference: false, enrollment: .enrolled(since: Date(), filtering: true, notYou: notYou)) == .off)
        #expect(OnlyMyVoiceStatus(preference: true, enrollment: .enrolled(since: Date(), filtering: true, notYou: notYou)) == .active)
        #expect(OnlyMyVoiceStatus(preference: true, enrollment: .enrolled(since: Date(), filtering: false, notYou: notYou)) == .unavailable)
        #expect(OnlyMyVoiceStatus(preference: true, enrollment: .learning(learned: 3, of: 10)) == .waiting(learned: 3, of: 10))
        #expect(OnlyMyVoiceStatus(preference: true, enrollment: .off) == .waiting(learned: 0, of: PassiveVoiceprint.minimumTurns))
        #expect(OnlyMyVoiceStatus.waiting(learned: 3, of: 10).line.contains("3 of 10"))
        #expect(OnlyMyVoiceCopy.detail.contains("anchored"), "explains K4's turn anchor")
        #expect(OnlyMyVoiceCopy.detail.contains("hold the key"), "explains M6's passive voiceprint")
    }

    @Test("switching it off lets another voice through the latch filter at once; on again filters")
    func liveSwitch() throws {
        let controller = Rig.controller()
        let runtime = LatchRuntime(delivery: Rig.NullDelivery())
        var segment: [Float]? = nil
        controller.attach(runtime: runtime, segmentAudio: { segment })
        let store = InMemorySettingsStore()
        controller.onlyMyVoice = { OnlyMyVoiceSettings.isOn(store) }
        let centroid = SpeakerEmbedding(vector: [1, 0], embedder: "test-wespeaker", metric: .cosine)
        #expect(controller.install(profile: SpeakerProfile(centroid: centroid, utteranceCount: 3, enrolledAt: Date())) == .filtering)
        let guardFn = try #require(runtime.speakerGuard)
        #expect(controller.speakerFilter.status == .active)

        segment = Rig.clip(1.2)                       // another voice
        #expect(guardFn() == .suppress(.mismatch))
        OnlyMyVoiceSettings.set(false, store: store)
        #expect(guardFn().allowsInsertion, "off: not filtered, without re-arming anything")
        #expect(controller.speakerFilter.status == .off)
        OnlyMyVoiceSettings.set(true, store: store)
        #expect(guardFn() == .suppress(.mismatch))
    }

    @Test("ambient is not loosened by switching it off: its gate still requires identification")
    func ambientUnaffected() {
        let store = InMemorySettingsStore()
        OnlyMyVoiceSettings.set(false, store: store)
        AmbientCaptureSettings.setEnabled(true, store: store)
        let filter = SpeakerFilter(isOn: false, gate: SpeakerGate(profile: nil), canIdentify: true)
        let gate = AmbientWiring.gate(settings: store, filter: filter)
        #expect(gate.decide(text: "hello", verdict: .other(similarity: 0.1), at: Date()).kept == nil)
    }
}
