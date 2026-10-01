import Engine
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// V5 C3 — the call-mode headset chip in the pill: drawn in the turn's chip row, tapping it opens
/// Settings › Voice (the microphone picker), and it goes with the turn.
@Suite("V5 C3 — call-mode headset chip in the pill")
struct NarrowbandChipTests {
    static let t0 = Date(timeIntervalSince1970: 70_000)
    static let headset = AudioDeviceInfo(id: 22, uid: "airpods-msbc", name: "AirPods Pro", transport: .bluetooth,
                                         sampleRate: 16_000, inputChannels: 1)

    @Test func chipIsALinkToSettingsVoice() throws {
        let model = PillViewModel()
        model.now = { Self.t0 }
        var routed: [(PillActionKind, PillState)] = []
        model.onAction = { routed.append(($0, $1)) }
        model.apply(.listening(level: 0.2))
        let notice = try #require(NarrowbandInputNotice.evaluate(device: Self.headset, avoided: nil))
        model.showLaneNote(notice.chip, action: .voice)
        #expect(model.laneNote == "Headset is in call mode — quality reduced")
        #expect(model.laneNoteAction == .voice)
        model.perform(try #require(model.laneNoteAction))
        #expect(routed.map(\.0) == [.voice])
        #expect(PillActionRoute.effect(for: .voice, shown: model.state, text: "") == .open(.voice))
    }

    @Test func chipGoesWithTheTurnAndAPlainNoteIsNotALink() {
        let model = PillViewModel()
        model.now = { Self.t0 }
        model.apply(.listening(level: 0.2))
        model.showLaneNote(NarrowbandInputNotice.capturingChip, action: .voice)
        model.apply(.idle)
        #expect(model.laneNote == nil)
        #expect(model.laneNoteAction == nil)

        model.apply(.listening(level: 0.2))
        model.showLaneNote("Learned spelling is kept for this session only")
        #expect(model.laneNoteAction == nil, "existing notes stay plain text")
        model.showLaneNote(NarrowbandInputNotice.capturingChip, action: .voice)
        model.present(.preview(text: "Screen text isn't available"))
        #expect(model.laneNoteAction == nil, "a later notice replaces the link with plain text")
    }
}
