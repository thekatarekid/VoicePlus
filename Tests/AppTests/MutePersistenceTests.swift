import Foundation
import Testing
@testable import VoicePlusApp

/// R3.3 — hard mute persists across a relaunch, and nothing ever unmutes on its own (V3 §4.4).
///
/// A relaunch is simulated the only way it can be on a build machine: a **temporary**
/// `UserDefaults` suite, a `UserDefaultsMuteStore` over it, and a second `MuteController` built
/// from a *fresh* store — which is exactly what the next launch does. The real
/// `UserDefaults.standard` is never touched, so running the suite cannot mute the owner's app.
@Suite("Hard mute survives a relaunch", .serialized)
struct MutePersistenceTests {

    /// One throwaway defaults domain per test.
    private static func suite(_ name: String = #function) -> (UserDefaults, () -> Void) {
        let id = "voiceplus.tests.mute.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: id)!
        defaults.removePersistentDomain(forName: id)
        return (defaults, {
            defaults.removePersistentDomain(forName: id)
            UserDefaults().removeSuite(named: id)
        })
    }

    @Test("a muted app relaunches muted")
    func muteSurvivesARelaunch() {
        let (defaults, cleanup) = Self.suite()
        defer { cleanup() }

        let first = MuteController(store: UserDefaultsMuteStore(defaults: defaults))
        #expect(!first.isMuted)
        first.mute()
        #expect(first.isMuted)
        #expect(defaults.bool(forKey: UserDefaultsMuteStore.key), "the mute never reached the defaults")

        // Relaunch: a new store over the same domain, a new controller, no in-memory state carried.
        let relaunched = MuteController(store: UserDefaultsMuteStore(defaults: defaults))
        #expect(relaunched.isMuted, "a muted VoicePlus came back unmuted")
        #expect(relaunched.model.muted)
    }

    @Test("an unmuted app relaunches unmuted — the flag is state, not a one-way door")
    func unmuteAlsoSurvivesARelaunch() {
        let (defaults, cleanup) = Self.suite()
        defer { cleanup() }

        let first = MuteController(store: UserDefaultsMuteStore(defaults: defaults))
        first.mute()
        first.unmute()
        #expect(!first.isMuted)

        let relaunched = MuteController(store: UserDefaultsMuteStore(defaults: defaults))
        #expect(!relaunched.isMuted)
    }

    @Test("the toggle is what changes it — no other call unmutes")
    func nothingElseUnmutes() {
        let (defaults, cleanup) = Self.suite()
        defer { cleanup() }

        let controller = MuteController(store: UserDefaultsMuteStore(defaults: defaults))
        controller.mute()
        // Everything else the app does to the ambient model while muted.
        controller.setProcessing(true)
        controller.acknowledgeDirected()
        controller.setProcessing(false)
        #expect(controller.isMuted, "something other than an unmute gesture cleared the hard mute")

        let relaunched = MuteController(store: UserDefaultsMuteStore(defaults: defaults))
        #expect(relaunched.isMuted)

        controller.toggleMute()
        #expect(!controller.isMuted)
        #expect(!MuteController(store: UserDefaultsMuteStore(defaults: defaults)).isMuted)
    }

    @Test("a muted relaunch refuses every microphone request")
    @MainActor func aMutedRelaunchRefusesEveryRequester() async {
        let (defaults, cleanup) = Self.suite()
        defer { cleanup() }
        MuteController(store: UserDefaultsMuteStore(defaults: defaults)).mute()

        // The next launch: a fresh store, a fresh controller, a fresh session coordinator.
        let engine = LatchBehaviourTests.SegmentedEngine()
        let dictation = DictationCoordinator(engine: engine, database: nil, pill: PillPanelController())
        let mute = MuteController(store: UserDefaultsMuteStore(defaults: defaults))
        let session = SessionCoordinator(dictation: dictation, mute: mute, latch: nil)
        #expect(session.isMuted, "the relaunched session did not come up muted")
        for requester in SessionCoordinator.Requester.allCases {
            #expect(session.start(requester) == .refused(.muted))
        }
        await dictation.settle()
        #expect(engine.starts == 0, "a muted relaunch opened the microphone")
    }
}
