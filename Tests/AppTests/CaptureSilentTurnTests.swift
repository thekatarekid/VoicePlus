import AVFoundation
import Engine
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// The app half of the "Listening · quiet" for ever failure: the turn gets an exit, and the TCC
/// answer is mapped to the decision it deserves.
///
/// Untestable here (no microphone, no TCC, no Xcode): whether `AVCaptureDevice.requestAccess`
/// actually prompts for this ad-hoc signature, and what the HAL does for a silenced input. Both are
/// hardware checks.
@Suite("A capture that is open and silent must not stay quiet")
struct CaptureSilentTurnTests {

    // MARK: - The turn exit

    @Test("a silent capture ends the capturing turn and shows A05 instead of latching on quiet")
    func silentCaptureEndsTheTurnWithA05() throws {
        let h = TurnControllerTests.Harness()
        guard case .began(let id) = h.controller.keyDown() else { Issue.record("no turn"); return }
        h.controller.captureOpened(id)
        #expect(h.controller.stage(of: id) == .listening)

        // The room goes quiet: this is the honest row, and nothing in it is time-bounded.
        h.controller.noteVoiceActivity(speech: false)
        h.clock.advance(PillState.quietAfter + 0.01)
        #expect(h.controller.stage(of: id) == .listeningQuiet)
        #expect(h.events.stateNames.contains("listeningQuiet"))

        // The watchdog says the stream is silenced, not the room.
        h.controller.captureSilent()
        #expect(h.controller.stage(of: id) == nil, "the turn is over")
        #expect(h.events.ended.contains { $0.0 == id && $0.1 == .failed })
        #expect(h.events.notices.contains(.A05))
    }

    @Test("A05 is the catalogue's own entry, not invented copy")
    func a05IsCatalogueCopy() {
        let entry = RecoveryCatalog.entry(.A05)
        #expect(entry.headline == "No audio is reaching VoicePlus")
        #expect(entry.family == .audio)
    }

    @Test("a silent report after the turn is over changes nothing")
    func silentAfterKeyUpIsIgnored() async throws {
        let h = TurnControllerTests.Harness()
        let id = try #require(await h.holdToPreview(TurnControllerTests.words("hello")))
        let noticesBefore = h.events.notices.count
        h.controller.captureSilent()
        #expect(h.events.notices.count == noticesBefore)
        #expect(h.controller.stage(of: id) == .finalPreview, "a previewing turn is not capture")
    }

    @Test("a silent report with no turn at all is harmless")
    func silentWithNoTurn() {
        let h = TurnControllerTests.Harness()
        h.controller.captureSilent()
        #expect(h.events.notices.isEmpty)
    }

    // MARK: - Authorization mapping (see also `CaptureSilentLatchTests` below)

    @Test("only an authorized microphone proceeds; an unasked one is asked for first")
    func authorizationDecisions() {
        #expect(PipelineAudioSource.decide(.authorized) == .proceed)
        #expect(PipelineAudioSource.decide(.notDetermined) == .requestThenRefuse)
        #expect(PipelineAudioSource.decide(.denied) == .refuse)
        #expect(PipelineAudioSource.decide(.restricted) == .refuse)
    }

    @Test("every authorization state has a label that names the state, not an enum case")
    func authorizationLabels() {
        for status in [AVAuthorizationStatus.authorized, .notDetermined, .denied, .restricted] {
            let label = PipelineAudioSource.label(for: status)
            #expect(!label.isEmpty)
            // The 1.6.6 lesson: never show a case name.
            #expect(!label.contains("notDetermined"))
            #expect(!label.contains("restricted"))
        }
        #expect(PipelineAudioSource.label(for: .denied) == "turned off")
    }

    @Test("a refused grant is P01 'Microphone access is off', not A01 'No microphone found'")
    func refusedGrantIsP01() {
        let error = AudioCaptureError.notPermitted(status: PipelineAudioSource.label(for: .denied))
        #expect(RecoveryCatalog.entry(for: error).id == .P01)
        #expect(RecoveryCatalog.entry(for: error).headline == "Microphone access is off")
        #expect(RecoveryCatalog.entry(for: AudioCaptureError.noInputDevice).id == .A01)
    }

    // MARK: - Ownership conflict

    @Test("a lower-ranked owner cannot take capture from dictation, and is told why")
    func ownershipConflictIsReported() throws {
        // Ranks only: no pipeline is started, so nothing here touches the HAL.
        #expect(PipelineAudioSource.Owner.engine.rank > PipelineAudioSource.Owner.meter.rank)
        #expect(PipelineAudioSource.Owner.engine.rank > PipelineAudioSource.Owner.diagnostics.rank)
        let busy = AudioCaptureError.busy(owner: PipelineAudioSource.Owner.engine.rawValue)
        #expect(RecoveryCatalog.entry(for: busy).id == .A09)
        #expect(RecoveryCatalog.entry(for: busy).headline == "Microphone is in use")
    }
}

/// The latched half: a silenced capture is the one failure latch cannot ride out, because the mode's
/// whole promise ("listening continues") is a promise about the capture that is being released.
@Suite("A silenced capture must not leave a session claiming latch")
@MainActor
struct CaptureSilentLatchTests {

    @Test("a silent capture leaves latch, undresses the pill and disconnects the runtime")
    func silentCaptureLeavesLatch() async {
        var rig = LatchLoopRig()
        let feed = FakeLatchFeed()
        await rig.doubleTap()
        rig.latch.replaceFeed(feed)
        #expect(rig.dictation.latched)
        #expect(rig.dictation.pill.model.latched)
        #expect(rig.latch.isConnected)

        // The watchdog's verdict arrives from the audio side. `cancel()` alone would end the turn
        // and the engine session but keep the mode, leaving the pill latched over a pipeline that
        // is about to be released — "Listening" for ever by another route.
        rig.dictation.noteCaptureSilent("every sample has been silent for 3.0s", source: nil)
        await rig.settle()

        #expect(!rig.dictation.latched, "the session kept a mode it can no longer honour")
        #expect(!rig.dictation.pill.model.latched, "the pill kept its latch dress")
        #expect(!rig.latch.isConnected, "the runtime stayed connected to a dead pipeline")
        #expect(feed.latchedCalls == [true, false])
    }

    @Test("a deliberate pause in a latched session is not a silenced capture")
    func longPauseInLatchSurvives() async throws {
        var rig = LatchLoopRig()
        let capture = ScriptedLatchCapture()
        try await rig.latch(on: capture)
        // Twelve seconds of a live microphone with nobody talking: four times the watchdog's
        // timeout, and the session must be exactly where it was. This is the real-hardware case —
        // an analogue input dithers its bottom bit, so `allZero` is false in every block.
        await capture.play(ScriptedLatchCapture.roomTone(12.0), into: rig.latch)
        await rig.flush()
        #expect(rig.dictation.latched, "a long pause ended the hands-free session")
        #expect(rig.latch.isConnected)
        #expect(rig.latch.outcomes.isEmpty)
        #expect(rig.engine.listening)
        capture.stop()
    }
}
