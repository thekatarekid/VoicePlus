import Foundation
import Shared

// R8.4 — the indicator reflects **actual microphone ownership** (V3 §8, §14.11).
//
// The bug this file exists to prevent: the presence indicator used to be a function of the dictation
// engine's state alone. `EngineState.listening` is true only while *dictation* is running, so every
// other way the microphone opens — a meeting being recorded, ambient capture, the onboarding meter,
// `--mic-selftest` — left the chin reading "VoicePlus · Ready" with a hot microphone. An indicator
// that says the microphone is closed while it is open is the worst failure available here, and it is
// exactly the "hidden hot mic" the product spec forbids.
//
// So the indicator is driven by *evidence of an open capture path*, not by intent:
//
// * `PipelineAudioSource.currentOwner` — the ranked owner of the one shared capture graph (dictation
//   as `.engine`, the onboarding meter as `.meter`, diagnostics as `.diagnostics`). This is the
//   authoritative answer for everything that goes through the graph, and it is already cleared on a
//   failed start, a timeout and a stop, which is what makes a failed start unable to stick the
//   indicator on.
// * the capture paths that open their own device instead of the shared graph: meeting capture
//   (`MeetingCoordinator`'s `DualCapture`) and ambient capture.
// * `SessionCoordinator.activeRequester` is deliberately **not** evidence. It is the R3 arbitration
//   layer's *claim*, and a claim can outlive a capture that never opened (a dictation start that
//   threw leaves the claim in place until the next stop). It is carried here only to name the holder
//   and to notice the disagreement — never to turn the indicator on.
//
// Nothing in this file changes the pill or the chin's geometry, palette, marks, sounds or animation
// (V3 §12.12). It changes *when* the indicator shows a microphone-open state and nothing else.

/// Who actually holds the microphone right now, as far as the app can prove.
public struct MicrophoneOwnership: Equatable, Sendable {
    /// Who to name, in the order the log names them.
    public enum Holder: String, Equatable, Sendable, CaseIterable {
        case dictation, meeting, ambient, meter, diagnostics
    }

    /// The shared capture graph's own answer (`PipelineAudioSource.currentOwner`), nil when shut.
    public var graphOwner: PipelineAudioSource.Owner?
    /// A meeting is being recorded. Meeting capture opens mic + system audio itself, so the shared
    /// graph does not know about it.
    public var meetingCapturing: Bool
    /// Ambient capture is running.
    public var ambientCapturing: Bool
    /// R3's arbitration claim. Intent, not evidence — see the file comment.
    public var claim: SessionCoordinator.Requester?

    public init(graphOwner: PipelineAudioSource.Owner? = nil,
                meetingCapturing: Bool = false,
                ambientCapturing: Bool = false,
                claim: SessionCoordinator.Requester? = nil) {
        self.graphOwner = graphOwner
        self.meetingCapturing = meetingCapturing
        self.ambientCapturing = ambientCapturing
        self.claim = claim
    }

    /// Nothing holds the microphone.
    public static let closed = MicrophoneOwnership()

    /// Everyone the app can prove is holding a microphone, in `Holder` order.
    public var holders: [Holder] {
        var found: [Holder] = []
        switch graphOwner {
        case .engine:
            // The graph cannot tell dictation from a meeting that took it; the claim can.
            found.append(claim == .meeting ? .meeting : .dictation)
        case .meter: found.append(.meter)
        case .diagnostics: found.append(.diagnostics)
        case nil: break
        }
        if meetingCapturing, !found.contains(.meeting) { found.append(.meeting) }
        if ambientCapturing, !found.contains(.ambient) { found.append(.ambient) }
        return Holder.allCases.filter(found.contains)
    }

    /// Is a microphone open? The one question the indicator must never get wrong.
    public var isOpen: Bool { !holders.isEmpty }

    /// The arbitration layer believes it holds the microphone and no capture path is open. Not a
    /// reason to light the indicator — the microphone really is shut — but worth a log line, because
    /// it is what a failed or abandoned start looks like from the outside.
    public var claimedWithoutCapture: Bool { claim != nil && !isOpen }

    /// For the log: who holds it, or "none".
    public var description: String {
        let who = holders.map(\.rawValue).joined(separator: "+")
        let claimed = claim.map { " claim=\($0.rawValue)" } ?? ""
        return (who.isEmpty ? "none" : who) + claimed
    }
}

public extension PresenceState {
    /// Does this state tell the user the microphone is open?
    ///
    /// `listening` is the only one that does. `processing` is about work that happens after capture,
    /// and `ready`, `paused`, `muted` and every `blocked` reason all promise the opposite — `muted`
    /// promises it in so many words ("the mic stays closed").
    var reportsOpenMicrophone: Bool {
        if case .listening = self { return true }
        return false
    }
}

public extension PresenceStateReducer {
    /// `substance`, corrected by what actually owns the microphone.
    ///
    /// Two corrections, one in each direction:
    ///
    /// * a microphone that **is** open shows `listening`, whatever else the inputs say. This outranks
    ///   `muted` and `paused` on purpose: those two states promise a closed microphone, so showing
    ///   them over an open one would be the least alarming reading of the most alarming situation —
    ///   the opposite of the rule the existing reducer's precedence was written for.
    /// * a microphone that is **not** open never shows `listening`, even if a stale `EngineState`
    ///   still says so — that is the "stuck on after a failed or displaced start" half of R8.4.
    static func substance(_ inputs: PresenceInputs, microphone: MicrophoneOwnership) -> PresenceState {
        let base = substance(inputs)
        guard microphone.isOpen else {
            guard base.reportsOpenMicrophone else { return base }
            // Re-derive with the engine's stale claim removed, so the honest state (muted, blocked,
            // ready…) is chosen by the same precedence as everywhere else rather than guessed here.
            var quiet = inputs
            quiet.engine = .idle
            return substance(quiet)
        }
        // Keep the level when the engine is the thing listening; a capture path that reports no level
        // (a meeting, ambient) still has to say the microphone is open.
        if case .listening = base { return base }
        return .listening(level: 0)
    }

    /// `reduce`, corrected the same way. The suppression rules are unchanged and deliberately
    /// re-stated rather than re-plumbed: `listening` is not `isQuiet`, so an open microphone can never
    /// be hidden by a full-screen Space, and the pill — which shows the same state, louder, at the
    /// same anchor — stays the one surface allowed to stand in for it.
    static func reduce(_ inputs: PresenceInputs, microphone: MicrophoneOwnership) -> PresenceState {
        guard inputs.enabled else { return .off }
        let state = substance(inputs, microphone: microphone)
        if inputs.pillVisible { return .off }
        if inputs.hideInFullScreen, !inputs.menuBarPresent, state.isQuiet { return .off }
        return state
    }
}
