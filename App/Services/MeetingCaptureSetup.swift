import AppKit
import Engine
import Foundation
import Shared

// V5 M1–M5, M14 — what a meeting's capture is set up with when it starts, shared by the detector
// path (`MeetingCoordinator`) and the manual panel path (`MeetingSessionCaptureDriver`):
//   * the mode (M4 auto-pick from live signals; the panel overrides it),
//   * the saved recording (M5 "Save meeting recording", read from Settings › Meetings), with the
//     retention sweep over meeting audio under the disk cap F3 already set for recordings,
//   * whether the user's dictations stay in the meeting transcript (M14 switch).

public extension SettingsKeys {
    /// Bool, default ON — "Show my dictations in meeting transcripts" (V5 M14).
    static let meetingShowDictations = "meeting.transcript.showDictations"
}

public enum MeetingCaptureSetup {
    // MARK: M4 auto-pick

    /// Live signals: the default output device is playing, and a call app (or, for a meeting
    /// detected from a browser tab, the browser) is frontmost. Hardware/AppKit reads — untested in CI.
    public static func liveSignals(for prompt: MeetingPrompt?) -> MeetingModeSignals {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let fromBrowser = prompt?.source?.kind == .browser || prompt?.reason == .browser
        return MeetingModeSignals(systemAudioActive: SystemOutputActivity.isPlaying(),
                                  callAppFrontmost: MeetingModePicker.isCallAppFrontmost(bundleID: front, detectedFromBrowser: fromBrowser))
    }

    // MARK: M14

    public static func showsDictations(_ settings: SettingsStore?) -> Bool {
        settings?.bool(SettingsKeys.meetingShowDictations) ?? true
    }

    public static func setShowsDictations(_ on: Bool, settings: SettingsStore?, center: NotificationCenter = .default) {
        settings?.set(on, for: SettingsKeys.meetingShowDictations)
        center.post(name: MeetingSettings.didChangeNotification, object: nil)
    }

    // MARK: M5 saved recording

    /// The recorder for a new meeting, or nil when "Save meeting recording" is Never.
    public static func recorder(meetingID: String, store: MeetingStore, settings: SettingsStore?) -> MeetingAudioRecorder? {
        let mode = MeetingSettings.saveRecording(settings)
        guard mode.retentionDays != 0 else { return nil }
        return MeetingAudioRecorder(directory: store.directory(for: meetingID))
    }

    /// Expired meeting audio (7-day setting) and, over the recordings disk cap F3 set (dictation
    /// recordings + meeting audio counted together), the oldest meeting audio. `keeping` is the
    /// meeting recording now. Transcripts and notes are never removed.
    @discardableResult
    public static func sweep(store: MeetingStore, settings: SettingsStore?, keeping meetingID: String? = nil,
                             now: Date = Date(), diskCap: Int64 = UtteranceRecorder.diskCapBytes(),
                             otherBytes: Int64? = nil) -> MeetingRecordingSweeper.Result {
        let mode = MeetingSettings.saveRecording(settings)
        let other = otherBytes ?? UtteranceRecorder.usage(of: UtteranceRecorder.directory()).bytes
        return MeetingRecordingSweeper.sweep(meetingsRoot: store.root, now: now,
                                             retentionDays: mode.retentionDays.flatMap { $0 > 0 ? $0 : nil },
                                             diskCap: diskCap, otherBytes: other,
                                             keeping: meetingID.map(store.directory(for:)))
    }

    /// Everything a new session + capture need, applied in one place.
    /// Returns the recorder (nil = not saving) so the caller can close it at the end.
    @discardableResult
    public static func prepare(session: MeetingSession, capture: DualCapture?, mode: MeetingMode,
                               store: MeetingStore, settings: SettingsStore?) async -> MeetingAudioRecorder? {
        await session.setMode(mode)
        await session.setKeepsDictations(showsDictations(settings))
        try? capture?.setMode(mode)
        let id = await session.record.id
        let recorder = recorder(meetingID: id, store: store, settings: settings)
        capture?.recording = recorder
        let swept = sweep(store: store, settings: settings, keeping: id)
        if swept.expired + swept.overCap > 0 {
            Log.app.info("meeting recordings: \(swept.expired) expired, \(swept.overCap) over the disk cap removed")
        }
        return recorder
    }
}
