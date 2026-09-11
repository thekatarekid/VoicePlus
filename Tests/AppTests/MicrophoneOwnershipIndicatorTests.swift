import Engine
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// R8.4 — the presence indicator reflects **actual microphone ownership** (V3 §8, §14.11).
///
/// The failure this suite exists to prevent, in both directions:
/// * the indicator says the microphone is closed while it is open — a meeting or ambient capture
///   opens it without `EngineState` ever reporting `listening`, and `muted` promises in so many words
///   that the microphone is shut;
/// * the indicator stays on after a start that failed or was displaced, which teaches the user to
///   stop believing it — the same damage from the other side.
///
/// There is no microphone, window server or display in this environment, so nothing here is hardware
/// evidence: the ownership half is driven through the **real** `PipelineAudioSource` capture-graph
/// owner (fixture audio, no HAL) and the rendering half through the pure reducer. The panel itself is
/// never created.
@Suite("R8.4 the indicator tracks actual microphone ownership")
struct MicrophoneOwnershipIndicatorTests {

    private func inputs(engine: EngineState = .idle, muted: Bool = false, paused: Bool = false,
                        pillVisible: Bool = false, menuBarPresent: Bool = true,
                        capabilities: PermissionPlanner.Capabilities = PresenceInputs.allCapabilities)
    -> PresenceInputs {
        PresenceInputs(menuBarPresent: menuBarPresent, pillVisible: pillVisible, muted: muted,
                       paused: paused, engine: engine, capabilities: capabilities)
    }

    private func bridge() -> (PipelineAudioSource, FixtureCaptureSource) {
        let source = FixtureCaptureSource(wav: WAVFile(sampleRate: 16_000, samples: []))
        var options = AudioPipeline.Options()
        options.noAudioTimeout = 0
        let audio = PipelineAudioSource(pipeline: AudioPipeline(source: source, vad: EnergyVAD(), options: options))
        audio.requireMicrophonePermission = false
        return (audio, source)
    }

    // MARK: - Who counts as holding the microphone

    @Test("every capture path that opens a microphone is an owner, and nothing else is")
    func holders() {
        #expect(!MicrophoneOwnership.closed.isOpen)
        #expect(MicrophoneOwnership(graphOwner: .engine).holders == [.dictation])
        #expect(MicrophoneOwnership(graphOwner: .meter).holders == [.meter])
        #expect(MicrophoneOwnership(graphOwner: .diagnostics).holders == [.diagnostics])
        #expect(MicrophoneOwnership(meetingCapturing: true).holders == [.meeting])
        #expect(MicrophoneOwnership(ambientCapturing: true).holders == [.ambient])
        // The graph cannot tell dictation from a meeting that took it; R3's claim can.
        #expect(MicrophoneOwnership(graphOwner: .engine, claim: .meeting).holders == [.meeting])
        #expect(MicrophoneOwnership(graphOwner: .engine, claim: .hotkey).holders == [.dictation])
        // Two paths at once (a meeting recording while onboarding's meter runs) names both.
        #expect(MicrophoneOwnership(graphOwner: .meter, meetingCapturing: true).holders == [.meeting, .meter])
        for holder in MicrophoneOwnership(graphOwner: .engine).holders { #expect(!holder.rawValue.isEmpty) }
    }

    @Test("an arbitration claim with no capture behind it is never an open microphone")
    func aClaimIsNotEvidence() {
        for requester in SessionCoordinator.Requester.allCases {
            let claimed = MicrophoneOwnership(claim: requester)
            #expect(!claimed.isOpen, "\(requester.rawValue)'s claim alone must not open the indicator")
            #expect(claimed.claimedWithoutCapture)
            #expect(!PresenceStateReducer.substance(inputs(), microphone: claimed).reportsOpenMicrophone)
        }
        #expect(!MicrophoneOwnership(graphOwner: .engine, claim: .hotkey).claimedWithoutCapture)
    }

    // MARK: - On exactly when the microphone is owned

    @Test("the indicator reports an open microphone exactly when one is owned")
    func onExactlyWhenOwned() {
        let ownerships: [MicrophoneOwnership] = [
            .closed,
            MicrophoneOwnership(graphOwner: .engine),
            MicrophoneOwnership(graphOwner: .meter),
            MicrophoneOwnership(graphOwner: .diagnostics),
            MicrophoneOwnership(meetingCapturing: true),
            MicrophoneOwnership(ambientCapturing: true),
            MicrophoneOwnership(graphOwner: .engine, claim: .meeting),
            MicrophoneOwnership(claim: .hotkey),
            MicrophoneOwnership(claim: .onboarding),
        ]
        let situations: [(String, PresenceInputs)] = [
            ("idle", inputs()),
            ("dictating", inputs(engine: .listening(level: 0.4))),
            ("finalizing", inputs(engine: .finalizing)),
            ("muted", inputs(muted: true)),
            ("paused", inputs(paused: true)),
            ("mic permission denied", inputs(capabilities: PermissionPlanner.Capabilities(canCapture: false, canUseGlobalHotkey: true, canInjectText: true))),
            ("no recognizer", inputs(engine: .unavailable("no model"))),
            ("full screen", inputs(menuBarPresent: false)),
        ]
        for owned in ownerships {
            for (name, input) in situations {
                let state = PresenceStateReducer.reduce(input, microphone: owned)
                #expect(state.reportsOpenMicrophone == owned.isOpen,
                        "\(name) with \(owned.description): said \(state.caseName) for isOpen=\(owned.isOpen)")
                if owned.isOpen {
                    #expect(state.isVisible, "an open microphone is never invisible")
                    #expect(!state.isQuiet, "an open microphone is never a quiet state (§8.3)")
                    #expect(!state.detail.isEmpty)
                }
            }
        }
    }

    @Test("muted with the microphone actually open shows the microphone, not the promise")
    func anOpenMicrophoneOutranksMuted() {
        let open = MicrophoneOwnership(graphOwner: .engine)
        let muted = PresenceStateReducer.reduce(inputs(muted: true), microphone: open)
        #expect(muted.reportsOpenMicrophone)
        #expect(!muted.detail.contains("stays closed"), "the indicator may not promise a closed mic while it is open")
        // With nothing capturing, mute keeps its precedence exactly as before.
        #expect(PresenceStateReducer.reduce(inputs(muted: true), microphone: .closed) == .muted)
        #expect(PresenceStateReducer.reduce(inputs(paused: true), microphone: .closed) == .paused)
    }

    @Test("a meeting or ambient capture lights the indicator even though the engine says nothing")
    func meetingsAndAmbientAreVisible() {
        // This is the pre-R8.4 bug: `EngineState.idle` used to read as "Ready" with a hot microphone.
        #expect(PresenceStateReducer.reduce(inputs(), microphone: .closed) == .ready)
        for owned in [MicrophoneOwnership(meetingCapturing: true), MicrophoneOwnership(ambientCapturing: true)] {
            let state = PresenceStateReducer.reduce(inputs(), microphone: owned)
            #expect(state.reportsOpenMicrophone)
            #expect(state.detail == "VoicePlus · Listening")
            // And it survives a full-screen Space, which is exactly when a call is happening.
            var fullScreen = inputs(menuBarPresent: false)
            fullScreen.hideInFullScreen = true
            #expect(PresenceStateReducer.reduce(fullScreen, microphone: owned).reportsOpenMicrophone)
        }
    }

    @Test("dictation's level survives; a capture path with no level still says the microphone is open")
    func levelIsPreserved() {
        let dictating = PresenceStateReducer.reduce(inputs(engine: .listening(level: 0.7)),
                                                    microphone: MicrophoneOwnership(graphOwner: .engine))
        #expect(abs(dictating.level - 0.7) < 0.001)
        let meeting = PresenceStateReducer.reduce(inputs(), microphone: MicrophoneOwnership(meetingCapturing: true))
        #expect(meeting.reportsOpenMicrophone)
        #expect(meeting.level == 0)
    }

    @Test("a stale 'listening' engine state with nothing owning the microphone is not shown")
    func staleListeningIsCorrected() {
        // The engine believes it is listening; the capture graph is shut. The microphone wins.
        let stale = inputs(engine: .listening(level: 0.9))
        #expect(PresenceStateReducer.reduce(stale, microphone: .closed) == .ready)
        #expect(PresenceStateReducer.reduce(inputs(engine: .listening(level: 0.9), muted: true), microphone: .closed) == .muted)
        let denied = PermissionPlanner.Capabilities(canCapture: false, canUseGlobalHotkey: true, canInjectText: true)
        #expect(PresenceStateReducer.reduce(inputs(engine: .listening(level: 0.9), capabilities: denied),
                                            microphone: .closed) == .blocked(.microphoneDenied))
    }

    @Test("the pill is the only thing allowed to stand in for an open microphone")
    func onlyThePillSuppressesIt() {
        let open = MicrophoneOwnership(graphOwner: .engine)
        #expect(PresenceStateReducer.reduce(inputs(pillVisible: true), microphone: open) == .off)
        // The pill shows the same state, louder, at the same anchor — and the substance is unchanged,
        // so the state that is *hidden* is still the truthful one.
        #expect(PresenceStateReducer.substance(inputs(pillVisible: true), microphone: open).reportsOpenMicrophone)
        var disabled = inputs()
        disabled.enabled = false
        #expect(PresenceStateReducer.reduce(disabled, microphone: open) == .off, "the user may switch the chin off")
    }

    // MARK: - Against the real capture graph

    @Test("the real graph owner drives it: start, handover, stop")
    func realGraphOwnershipDrivesTheIndicator() async throws {
        let (audio, _) = bridge()
        var claim: SessionCoordinator.Requester?
        func ownership() -> MicrophoneOwnership {
            MicrophoneOwnership(graphOwner: audio.currentOwner, claim: claim)
        }
        func state() -> PresenceState { PresenceStateReducer.reduce(inputs(), microphone: ownership()) }

        #expect(!state().reportsOpenMicrophone)

        // Onboarding's meter opens the microphone. The engine is idle — and the indicator is on.
        claim = .onboarding
        try audio.start(for: .meter)
        #expect(ownership().holders == [.meter])
        #expect(state().reportsOpenMicrophone)

        // Dictation takes the graph. Still open, and now named as dictation.
        claim = .hotkey
        try audio.start(for: .engine)
        #expect(ownership().holders == [.dictation])
        #expect(state().reportsOpenMicrophone)

        // The displaced meter calls stop a moment later. It no longer owns the graph, so the
        // microphone stays open and so does the indicator.
        audio.stop(for: .meter)
        #expect(audio.currentOwner == .engine)
        #expect(state().reportsOpenMicrophone)

        audio.stop(for: .engine)
        #expect(audio.currentOwner == nil)
        #expect(!state().reportsOpenMicrophone, "the indicator must go off with the microphone")
        // R3's claim can outlive the capture it asked for; it must not keep the indicator on.
        #expect(ownership().claimedWithoutCapture)
    }

    @Test("a start that fails never leaves the indicator on")
    func failedStartIsNotStuckOn() throws {
        let audio = PipelineAudioSource(pipeline: AudioPipeline(source: ThrowingCaptureSource(), vad: EnergyVAD()))
        audio.requireMicrophonePermission = false
        #expect(throws: AudioCaptureError.noInputDevice) { try audio.start(for: .engine) }
        // The session layer still holds its claim (nothing releases it on a failed start) and the
        // engine may still be reporting `listening` from the attempt. Neither may light the chin.
        let after = MicrophoneOwnership(graphOwner: audio.currentOwner, claim: .hotkey)
        #expect(!after.isOpen)
        #expect(after.claimedWithoutCapture)
        #expect(!PresenceStateReducer.reduce(inputs(engine: .listening(level: 0.5)), microphone: after)
            .reportsOpenMicrophone)
    }

    @Test("a refused start does not disturb the indicator of the owner that holds the microphone")
    func refusedStartDoesNotFlicker() throws {
        let (audio, _) = bridge()
        try audio.start(for: .engine)
        #expect(throws: AudioCaptureError.busy(owner: "engine")) { try audio.start(for: .meter) }
        let owned = MicrophoneOwnership(graphOwner: audio.currentOwner, claim: .hotkey)
        #expect(owned.holders == [.dictation])
        #expect(PresenceStateReducer.reduce(inputs(), microphone: owned).reportsOpenMicrophone)
        audio.stop(for: .engine)
        #expect(!PresenceStateReducer.reduce(inputs(), microphone: MicrophoneOwnership(graphOwner: audio.currentOwner))
            .reportsOpenMicrophone)
    }

    @Test("hard mute closes the capture path, and only then does the indicator say Muted")
    func hardMuteClosesItFirst() throws {
        let (audio, _) = bridge()
        try audio.start(for: .engine)
        // Muted while the graph is still open: the truth is the open microphone.
        #expect(PresenceStateReducer.reduce(inputs(muted: true),
                                            microphone: MicrophoneOwnership(graphOwner: audio.currentOwner))
            .reportsOpenMicrophone)
        // R3's hard mute stops every capture path; once it has, "Muted" is true.
        audio.stop(for: .engine)
        #expect(PresenceStateReducer.reduce(inputs(muted: true),
                                            microphone: MicrophoneOwnership(graphOwner: audio.currentOwner)) == .muted)
    }

    // MARK: - The controller's seam

    @Test("the controller reads ownership through an injectable provider, defaulting to closed")
    @MainActor
    func controllerSeam() {
        let controller = PresenceIndicatorController()
        #expect(controller.microphoneOwnership == nil, "nothing wired reads as nothing capturing")
        let owned = MicrophoneOwnership(meetingCapturing: true)
        controller.microphoneOwnership = { owned }
        #expect(controller.microphoneOwnership?().isOpen == true)
        // Rendering is not exercised here: `start()` would create a panel, and there is no window
        // server in this environment. The reducer above is what the controller calls.
    }
}
