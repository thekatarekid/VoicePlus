import Combine
import Foundation
import Shared

/// V5 O1 — the meeting is a **recorder** on `SessionCoordinator`, so the events that close the
/// microphone for every subscriber (screen lock, sleep, hard mute) also stand a running meeting down.
///
/// Before this, nothing called `start(.meeting)` / `stop(.meeting)`: the coordinator never knew a
/// meeting was recording, its lock / sleep path stood down nobody, and the meeting's mic leg kept its
/// subscription on the shared graph behind a locked screen (V3 §8: capture never continues, and never
/// resumes, on its own).
///
/// Both meeting paths report here:
/// * the detector-driven meeting (`MeetingCoordinator.onRecordingChanged`);
/// * the manual meeting (Meetings › Start recording, the panel, the pill), while its capture is open
///   (`MeetingCaptureController.state.phase` `.starting` / `.recording`; a paused meeting has closed
///   its legs, so it holds no recorder claim).
///
/// The recorder claim is held while either one captures. When the coordinator stands `.meeting`
/// down (`onStandDown`), both are stopped: the detector meeting through `.recordingStopped` (its last
/// drain and notes land as on a user Stop), the manual one through `MeetingCaptureController.stop()`.
/// A claim refused at start (hard mute) stands the meeting down at once — nothing opens the
/// microphone while muted.
@MainActor
public final class MeetingSessionWiring {
    /// Weak: the coordinator's `onStandDown` holds this wiring, so it lives exactly as long as the
    /// session coordinator it serves.
    private weak var session: SessionCoordinator?
    /// Stops the detector-driven meeting (`MeetingCoordinator.apply(.recordingStopped)`).
    private let stopAutomatic: () -> Void
    /// Stops the manual meeting (`MeetingCaptureController.stop()`).
    private let stopManual: () -> Void
    private var automatic = false
    private var manual = false
    private var cancellable: AnyCancellable?

    /// The detector and manual meetings, as the coordinator should see them.
    public var isClaiming: Bool { automatic || manual }

    public init(session: SessionCoordinator, stopAutomatic: @escaping () -> Void, stopManual: @escaping () -> Void) {
        self.session = session
        self.stopAutomatic = stopAutomatic
        self.stopManual = stopManual
        let previous = session.onStandDown
        session.onStandDown = { requester in
            previous?(requester)
            guard requester == .meeting else { return }
            Self.onMain { self.standDown() }
        }
    }

    /// The composition root's call: hooks the detector meeting and the manual capture.
    @discardableResult
    public static func install(session: SessionCoordinator, meeting: MeetingCoordinator,
                               capture: MeetingCaptureController? = nil) -> MeetingSessionWiring {
        let capture = capture ?? .shared
        let wiring = MeetingSessionWiring(
            session: session,
            stopAutomatic: { [weak meeting] in meeting?.apply(.recordingStopped) },
            stopManual: { [weak capture] in Task { @MainActor in _ = await capture?.stop() } })
        let previous = meeting.onRecordingChanged
        meeting.onRecordingChanged = { [weak wiring] recording in
            previous?(recording)
            onMain { wiring?.automaticChanged(recording) }
        }
        wiring.cancellable = capture.$state
            .map { $0.phase == .starting || $0.phase == .recording }
            .removeDuplicates()
            .sink { [weak wiring] capturing in onMain { wiring?.manualChanged(capturing) } }
        return wiring
    }

    /// The detector meeting opened or closed its recording.
    public func automaticChanged(_ recording: Bool) {
        automatic = recording
        sync()
    }

    /// The manual meeting's capture opened or closed (pause counts as closed).
    public func manualChanged(_ capturing: Bool) {
        manual = capturing
        sync()
    }

    private func sync() {
        guard let session else { return }
        let claimed = session.activeRecorders.contains(.meeting)
        if isClaiming, !claimed {
            let verdict = session.start(.meeting)
            if !verdict.isGranted {
                Log.app.notice("meeting: recorder claim refused (\(String(describing: verdict))); standing the meeting down")
                standDown()
            }
        } else if !isClaiming, claimed {
            session.stop(.meeting)
        }
    }

    /// Lock, sleep or hard mute closed the microphone for every subscriber: end both meetings.
    private func standDown() {
        let (wasAutomatic, wasManual) = (automatic, manual)
        automatic = false
        manual = false
        if wasAutomatic { stopAutomatic() }
        if wasManual { stopManual() }
        if wasAutomatic || wasManual { Log.app.notice("meeting: stood down with the microphone (lock / sleep / mute)") }
    }

    private nonisolated static func onMain(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread { MainActor.assumeIsolated(work) } else { DispatchQueue.main.async { work() } }
    }
}
