import Engine
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// R3 / S9 — `SessionCoordinator.onRefusal` reaches the pill: a dictation start refused while muted
/// or while another dictation holds the microphone shows its catalogue row, never nothing and never
/// `Refusal.message`'s requester tokens.
@Suite("R3 — session refusals reach the pill")
@MainActor
struct SessionRefusalWiringTests {
    final class Scheduled {
        var delays: [TimeInterval] = []
        var work: [() -> Void] = []
        var schedule: SessionRefusalWiring.Schedule {
            { delay, work in self.delays.append(delay); self.work.append(work) }
        }
        func fire() { let w = work; work.removeAll(); w.forEach { $0() } }
    }

    struct Rig {
        let session: SessionCoordinator
        let mute: MuteController
        let pill = PillViewModel()
        let scheduled = Scheduled()

        init(muted: Bool) {
            let dictation = DictationCoordinator(engine: StatusMenuControllerTests.CountingEngine(), database: nil,
                                                 pill: PillPanelController())
            mute = MuteController(store: InMemoryMuteStore(muted: muted))
            session = SessionCoordinator(dictation: dictation, mute: mute)
            SessionRefusalWiring.attach(session, pill: pill, schedule: scheduled.schedule)
        }
    }

    @Test("a dictation key press while hard-muted shows K05 with Unmute")
    func mutedHotkeyStartShowsK05() {
        let rig = Rig(muted: true)
        #expect(rig.session.onRefusal != nil, "the handler is assigned")
        let verdict = rig.session.start(.hotkey)
        #expect(verdict == .refused(.muted))
        let k05 = RecoveryCatalog.entry(.K05)
        #expect(rig.pill.state == .recovery(k05))
        let content = rig.pill.content()
        #expect(content.status.contains(k05.headline), "headline \(content.status)")
        #expect(k05.headline == "VoicePlus is muted")
        #expect(content.buttons.contains { $0.action == .unmute }, "the entry's own action")
        #expect(rig.scheduled.work.isEmpty, "K05 stays until the user acts")
    }

    @Test("the menu's latch start while muted is refused the same way")
    func mutedMenuStartShowsK05() {
        let rig = Rig(muted: true)
        rig.session.start(.menu, mode: .latched)
        #expect(rig.pill.state == .recovery(RecoveryCatalog.entry(.K05)))
    }

    @Test("a mute row already on screen stays: the notice never replaces it")
    func mutedRowStays() {
        let rig = Rig(muted: true)
        rig.pill.present(.muted)
        rig.session.start(.hotkey)
        #expect(rig.pill.state == .muted)
    }

    @Test("a menu start while the key's dictation holds the microphone: K04, then the running row again")
    func busyMenuStartShowsK04ThenTheTurn() {
        let rig = Rig(muted: false)
        #expect(rig.session.requestMicrophone(.hotkey) == .granted)
        rig.pill.present(.listening(level: 0.3))
        let verdict = rig.session.start(.menu, mode: .latched)
        #expect(verdict == .refused(.busy(.hotkey)))
        let k04 = RecoveryCatalog.entry(.K04)
        #expect(rig.pill.state == .recovery(k04))
        #expect(!rig.pill.content().status.contains("hotkey"), "no requester token on the surface")
        #expect(rig.scheduled.delays == [RecoveryCatalog.fadeWindow.upperBound])
        rig.scheduled.fire()
        #expect(rig.pill.state == .listening(level: 0.3), "K04 keeps the current turn's pose")
    }

    @Test("K04 never takes down a row that replaced it")
    func busyNoticeReplacedIsLeftAlone() {
        let rig = Rig(muted: false)
        rig.session.requestMicrophone(.hotkey)
        rig.session.start(.menu)
        rig.pill.present(.finishing(elapsedWarning: false))
        rig.scheduled.fire()
        #expect(rig.pill.state == .finishing(elapsedWarning: false))
    }

    @Test("requesters that don't dictate answer on their own surface: no pill row")
    func nonDictatingRequestersGetNoRow() {
        let rig = Rig(muted: true)
        for requester: SessionCoordinator.Requester in [.onboarding, .meeting, .diagnostics] {
            rig.session.start(requester)
            #expect(SessionRefusalWiring.entry(for: requester, .muted) == nil)
        }
        #expect(rig.pill.state == .hidden)
    }

    @Test("every refusal maps to a catalogue entry; its message is that headline, never a raw token")
    func refusalsSpeakCatalogue() {
        let cases: [(SessionCoordinator.Refusal, RecoveryID)] = [
            (.muted, .K05), (.busy(.hotkey), .K04), (.busy(.menu), .K04), (.awaitingRestart, .K02),
        ]
        for (refusal, id) in cases {
            #expect(RecoveryCatalog.entry(for: refusal).id == id)
            #expect(SessionRefusalWiring.entry(for: .hotkey, refusal)?.id == id)
            #expect(refusal.message == RecoveryCatalog.entry(id).headline)
            for token in SessionCoordinator.Requester.allCases.map(\.rawValue) {
                #expect(!refusal.message.contains(token), "\(refusal.message) names \(token)")
            }
        }
    }
}
