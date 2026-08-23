import Engine
import Foundation
import Testing
@testable import VoicePlusApp

@Suite("Ambient state + hard mute (P5.4)")
struct AmbientStateTests {
    @Test func threeStatesAndSymbols() {
        #expect(AmbientState.allCases.count == 3)
        let syms = Set(AmbientState.allCases.map(\.menuBarSymbol) + AmbientState.allCases.map(\.notchSymbol))
        #expect(syms.count == 6)   // every state is visually distinct on both surfaces
        var m = AmbientStateModel()
        #expect(m.state == .listening && m.badge == nil && m.micOpen)
        m.setProcessing(true)
        #expect(m.state == .processing && m.menuBarSymbol == "waveform.circle.fill")
        m.mute()
        #expect(m.state == .muted && m.badge == "MUTED" && !m.micOpen && m.notchSymbol == "mic.slash.fill")
    }

    @Test func muteIsAHardLatch() {
        var m = AmbientStateModel()
        #expect(m.toggleMute() == .muted)
        // Nothing the engine does releases mute.
        m.setProcessing(true); #expect(m.state == .muted)
        m.setProcessing(false); #expect(m.state == .muted)
        m.acknowledgeDirected(); #expect(!m.isWarm() && m.state == .muted)
        // Only the explicit gesture does.
        #expect(m.toggleMute() == .listening)
        #expect(m.badge == nil)
    }

    @Test func warmBeatExpires() {
        var m = AmbientStateModel()
        let t0 = Date()
        m.acknowledgeDirected(at: t0)
        #expect(m.isWarm(at: t0.addingTimeInterval(0.3)))
        #expect(!m.isWarm(at: t0.addingTimeInterval(AmbientStateModel.warmDuration + 0.01)))
    }

    @Test func controllerPersistsAndNeverAutoUnmutes() {
        let store = InMemoryMuteStore()
        let c = MuteController(store: store)
        var seen: [AmbientState] = []
        c.observe { seen.append($0.state) }
        c.toggleMute()
        #expect(store.muted && c.isMuted)
        c.setProcessing(true)
        #expect(c.state == .muted)
        // Relaunch: a new controller over the same store comes up muted.
        let relaunched = MuteController(store: store)
        #expect(relaunched.state == .muted && relaunched.model.badge == "MUTED")
        relaunched.unmute()
        #expect(!store.muted && relaunched.state == .listening)
        #expect(seen == [.listening, .muted, .muted])
    }
}
