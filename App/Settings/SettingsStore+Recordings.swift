import Foundation
import Engine

/// J1 (V4.52) — the recordings retention and the corpus label, as settings.
///
/// The keys belong to `UtteranceRecorder`, which reads them from `UserDefaults.standard` at every
/// save (Engine cannot see `SettingsStore`); they are aliased here so the Settings › Privacy rows
/// (S7f: *Keep the last 100* · *Keep all*, the folder size, the corpus label) read and write them
/// through `SettingsStore` like every other setting. Parsing is `UtteranceRecorder`'s, so the two
/// paths can never disagree about what a stored value means.
///
/// Wave 1 keeps its keys out of `SettingsStore.swift` (owned by B this wave), in this extension.
public extension SettingsKeys {
    /// Decimal string: `100` by default, `0` = keep all.
    static let recordingsRetain = UtteranceRecorder.retainKey
    /// Free text; absent or blank = untagged.
    static let recordingsCorpus = UtteranceRecorder.corpusKey
    /// V5 F3 — decimal string: days kept, `30` by default, `0` = forever.
    static let recordingsRetentionDays = UtteranceRecorder.retentionDaysKey
    /// V5 F3 — decimal string: the Recordings folder's disk cap in bytes, 2 GB by default.
    static let recordingsDiskCap = UtteranceRecorder.diskCapKey
}

public enum RecordingSettings {
    public static let defaultRetention = UtteranceRecorder.defaultRetainedUtterances
    public static let keepAll = UtteranceRecorder.keepAll

    /// The retention in force: `defaultRetention` when unset or unreadable, `keepAll` for "Keep all".
    public static func retention(_ store: SettingsStore?) -> Int {
        UtteranceRecorder.parseRetention(store?.string(SettingsKeys.recordingsRetain))
    }

    /// Takes effect at the next saved recording. A negative count stores the default.
    public static func setRetention(_ count: Int, store: SettingsStore?) {
        store?.set(String(count < 0 ? defaultRetention : count), for: SettingsKeys.recordingsRetain)
    }

    public static func corpusLabel(_ store: SettingsStore?) -> String? {
        UtteranceRecorder.normalizedCorpusLabel(store?.string(SettingsKeys.recordingsCorpus))
    }

    /// nil or blank clears the label, so later recordings go untagged.
    public static func setCorpusLabel(_ label: String?, store: SettingsStore?) {
        store?.set(UtteranceRecorder.normalizedCorpusLabel(label), for: SettingsKeys.recordingsCorpus)
    }

    /// Count and size of what the Recordings folder holds, for the line beside the switch.
    public static func usage(of directory: URL = UtteranceRecorder.directory()) -> UtteranceRecorder.FolderUsage {
        UtteranceRecorder.usage(of: directory)
    }

    // MARK: V5 F3 — age retention + disk cap (the recorder sweeps at every save and at launch)

    public static let defaultRetentionDays = UtteranceRecorder.defaultRetentionDays
    public static let forever = UtteranceRecorder.forever
    public static let defaultDiskCap = UtteranceRecorder.defaultDiskCapBytes

    public static func retentionDays(_ store: SettingsStore?) -> Int {
        UtteranceRecorder.parseRetentionDays(store?.string(SettingsKeys.recordingsRetentionDays))
    }

    public static func setRetentionDays(_ days: Int, store: SettingsStore?) {
        store?.set(String(days < 0 ? defaultRetentionDays : days), for: SettingsKeys.recordingsRetentionDays)
    }

    public static func diskCap(_ store: SettingsStore?) -> Int64 {
        UtteranceRecorder.parseDiskCap(store?.string(SettingsKeys.recordingsDiskCap))
    }

    public static func setDiskCap(_ bytes: Int64, store: SettingsStore?) {
        store?.set(String(bytes <= 0 ? defaultDiskCap : bytes), for: SettingsKeys.recordingsDiskCap)
    }

    public static var allKeys: [String] {
        [SettingsKeys.recordingsRetain, SettingsKeys.recordingsCorpus,
         SettingsKeys.recordingsRetentionDays, SettingsKeys.recordingsDiskCap]
    }
}
