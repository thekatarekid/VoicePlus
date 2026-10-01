import Engine
import Foundation

// R8.1 — the ambient opt-in, and why it is three switches and not one.
//
// V3 §8 and §14.11: ambient is off by default, behind its **own** switch; it keeps the enrolled
// voice only unless broader capture is explicitly asked for; and it is transcript only, because
// audio retention is a **separate** decision again. "Another person's words read as surveillance
// whether or not audio was kept" — so none of these three may be implied by any of the others, and
// none of them may ride on a setting that exists for a different purpose.
//
// Before R8 the Privacy switch labelled "Ambient capture" wrote the `directedSpeech` feature flag,
// which is the hands-free experiment (V3 §8: "`directedSpeech` stays off"). Turning on a transcript
// Timeline would have armed a hands-free path, and turning off hands-free would have silently
// emptied the Timeline. They are now separate keys.

/// The ambient switches: read and written in one place, defaults included.
public enum AmbientCaptureSettings {
    /// R8.1's opt-in. Since V5 L1 the source of truth is `AmbientModeSettings.key` (`ambient.mode`,
    /// three settings); this key is only migrated from and mirrored (on = any mode but Off).
    public static let enabledKey = AmbientModeSettings.legacyEnabledKey

    /// "Keep what other people said too." Off by default: without it, a voice that is not the
    /// enrolled user is discarded rather than stored (V3 §8).
    public static let everySpeakerKey = "ambient.capture.everySpeaker"

    /// Audio retention is its own switch and its own key — the *existing* recorder key, so ambient
    /// does not get a second, quieter way to start writing audio to disk.
    public static var audioRetentionKey: String { UtteranceRecorder.defaultsKey }

    /// Retention length lives in `AmbientRetentionSettings` (R7.1's picker, R8.2's enforcement).
    public static var retentionDaysKey: String { AmbientRetentionSettings.daysKey }

    /// Ambient capture runs: the L1 mode is Listen & note or Listen & act.
    public static func isEnabled(_ store: (any SettingsStore)?) -> Bool {
        AmbientModeSettings.mode(store).listens
    }

    /// The old on/off: on keeps a listening mode (Listen & note when it was Off — never escalates to
    /// act); off is Off.
    public static func setEnabled(_ enabled: Bool, store: (any SettingsStore)?) {
        let current = AmbientModeSettings.mode(store)
        if enabled { if !current.listens { AmbientModeSettings.set(.listenAndNote, store: store) } }
        else { AmbientModeSettings.set(.off, store: store) }
    }

    /// True only when the user explicitly widened capture beyond their own enrolled voice.
    public static func capturesEverySpeaker(_ store: (any SettingsStore)?) -> Bool {
        store?.bool(everySpeakerKey) ?? false
    }

    public static func setCapturesEverySpeaker(_ on: Bool, store: (any SettingsStore)?) {
        store?.set(on, for: everySpeakerKey)
    }

    /// Whether ambient audio would be kept — read from the recorder's own switch, never set here.
    /// Ambient capture itself writes no audio: `AmbientTranscriptStore` stores text only.
    public static func retainsAudio(_ defaults: UserDefaults = .standard) -> Bool {
        UtteranceRecorder.isEnabled(defaults)
    }

    /// The three keys, for the test that asserts they are three and not one.
    public static var allKeys: [String] { [AmbientModeSettings.key, everySpeakerKey, audioRetentionKey, retentionDaysKey] }
}
