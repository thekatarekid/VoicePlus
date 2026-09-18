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

    public static var allKeys: [String] { [SettingsKeys.recordingsRetain, SettingsKeys.recordingsCorpus] }
}
