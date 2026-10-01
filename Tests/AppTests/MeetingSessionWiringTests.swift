import Engine
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// V5 O1 — a meeting holds the `.meeting` recorder claim on `SessionCoordinator` while it captures,
/// so lock, sleep and hard mute stand it down with every other subscriber (V3 §8).
@MainActor
@Suite("V5 O1 meeting recorder claim")
struct MeetingSessionWiringTests {
    final class Stops {
        var automatic = 0
        var manual = 0
    }

    private func session(muted: Bool = false) -> SessionCoordinator {
        let dictation = DictationCoordinator(engine: StatusMenuControllerTests.CountingEngine(), database: nil,
                                             pill: PillPanelController())
        return SessionCoordinator(dictation: dictation, mute: MuteController(store: InMemoryMuteStore(muted: muted)))
    }

    private func rig(muted: Bool = false) -> (SessionCoordinator, MeetingSessionWiring, Stops) {
        let s = session(muted: muted)
        let stops = Stops()
        let w = MeetingSessionWiring(session: s, stopAutomatic: { stops.automatic += 1 },
                                     stopManual: { stops.manual += 1 })
        return (s, w, stops)
    }

    @Test("a detector meeting claims .meeting; its end releases it")
    func automaticClaimsAndReleases() {
        let (s, w, stops) = rig()
        w.automaticChanged(true)
        #expect(s.activeRecorders == [.meeting])
        w.automaticChanged(false)
        #expect(s.activeRecorders.isEmpty)
        #expect(stops.automatic == 0)
    }

    @Test("screen lock stands a running detector meeting down")
    func lockStopsAutomaticMeeting() {
        let (s, w, stops) = rig()
        w.automaticChanged(true)
        s.screenDidLock()
        #expect(stops.automatic == 1)
        #expect(s.activeRecorders.isEmpty)
        #expect(!w.isClaiming)
        // Waking up never resumes it.
        s.screenDidUnlock()
        #expect(s.activeRecorders.isEmpty)
    }

    @Test("sleep stands a manual meeting down")
    func sleepStopsManualMeeting() {
        let (s, w, stops) = rig()
        w.manualChanged(true)
        s.systemWillSleep()
        #expect(stops.manual == 1)
        #expect(stops.automatic == 0)
        #expect(s.activeRecorders.isEmpty)
    }

    @Test("hard mute stands both meetings down")
    func muteStopsBoth() {
        let (s, w, stops) = rig()
        w.automaticChanged(true)
        w.manualChanged(true)
        s.muteEngaged()
        #expect(stops.automatic == 1)
        #expect(stops.manual == 1)
        #expect(s.activeRecorders.isEmpty)
    }

    @Test("a meeting starting while muted is refused and stood down at once")
    func mutedStartIsStoodDown() {
        let (s, w, stops) = rig(muted: true)
        w.automaticChanged(true)
        #expect(stops.automatic == 1)
        #expect(s.activeRecorders.isEmpty)
    }

    @Test("the claim stays while either meeting captures")
    func claimHeldWhileEitherRuns() {
        let (s, w, _) = rig()
        w.automaticChanged(true)
        w.manualChanged(true)
        w.automaticChanged(false)
        #expect(s.activeRecorders == [.meeting])
        w.manualChanged(false)
        #expect(s.activeRecorders.isEmpty)
    }

    @Test("a dictation during a meeting does not end the meeting's claim")
    func dictationLeavesClaim() {
        let (s, w, stops) = rig()
        w.automaticChanged(true)
        s.start(.menu)
        s.stop(.menu)
        #expect(s.activeRecorders == [.meeting])
        #expect(stops.automatic == 0)
    }

    @Test("install: the manual capture's recording phase claims, lock stops it through the controller")
    func installWiresManualCapture() async throws {
        let s = session()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("o1-meeting-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = MeetingCoordinator(store: MeetingStore(root: root))
        let driver = ScriptedMeetingDriver()
        let capture = MeetingCaptureController(driver: driver)
        capture.tickInterval = 0
        MeetingSessionWiring.install(session: s, meeting: meeting, capture: capture)
        #expect(await capture.start(title: "Standup"))
        #expect(s.activeRecorders == [.meeting])
        s.screenDidLock()
        for _ in 0..<200 where capture.state.phase != .idle { try await Task.sleep(nanoseconds: 5_000_000) }
        #expect(capture.state.phase == .idle)
        #expect(driver.calls.contains("stop"))
        #expect(s.activeRecorders.isEmpty)
    }

    @Test("install: the detector meeting's recording edge claims and releases")
    func installWiresDetectorMeeting() {
        let s = session()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("o1-meeting-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = MeetingCoordinator(store: MeetingStore(root: root))
        MeetingSessionWiring.install(session: s, meeting: meeting, capture: MeetingCaptureController())
        meeting.onRecordingChanged?(true)
        #expect(s.activeRecorders == [.meeting])
        meeting.onRecordingChanged?(false)
        #expect(s.activeRecorders.isEmpty)
    }
}
