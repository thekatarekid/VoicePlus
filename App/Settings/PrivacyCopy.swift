import Engine
import Foundation

// S7f — Privacy (design §8.5, §9): every sentence the page says that is not already the copy
// fixture's (`DesignScreen.privacy`: title, subtitle, empty state, S04) or the shell's `SectionCopy`.
// Kept out of the `body`s so the tests can hold the page to its words: *Problem — Action* voice, no
// raw enum tokens or file names, and never a claim the data does not support ("Nothing left this
// Mac" only over a log that was actually read).

public enum PrivacyCopy {
    // MARK: Groups (prototype `h3` + `.group`)

    public static let processingGroup = "On this Mac or a service"
    public static let historyGroup = "History"
    public static let audioGroup = "Audio"
    public static let meetingsSyncGroup = "Meetings and sync"
    /// Prototype `<h3>Network activity · last 30 days</h3>`.
    public static let activityGroup = "Network activity · last 30 days"
    public static let deleteGroup = "Delete data"

    // MARK: Access rows

    /// Prototype row: "Dictation processing · On-device recognizer selected. · [On this Mac]".
    public static let processingTitle = "Dictation processing"
    public static let processingDetail = "On-device recognizer selected."
    public static let onThisMac = "On this Mac"

    public static let microphoneTitle = "Microphone"
    public static let typingTitle = "Typing access"
    /// Prototype row: "Context from other apps · Optional. Explain the scope before enabling."
    public static let contextTitle = "Context from other apps"
    public static let hardMuteTitle = "Hard mute"

    public static let allowed = "Allowed"
    public static let off = "Off"
    public static let notAsked = "Not asked"
    public static let waiting = "Waiting"
    public static let optionalOff = "Off · optional"
    public static let notAllowed = "Not allowed"

    public static let openSystemSettings = "Open System Settings"
    public static let allow = "Allow…"
    public static let enable = "Enable…"
    public static let mute = "Mute"
    public static let unmute = "Unmute"

    public static let microphoneGranted = "Opens only while you dictate or record a meeting, and closes when you stop."
    public static let microphoneDenied = "Off. VoicePlus can’t hear you until you allow it in System Settings."
    public static let microphoneNotAsked = "Not asked yet. macOS asks the first time you dictate."
    public static let microphoneWaiting = "Waiting for the switch in System Settings."

    public static let typingGranted = "Lets VoicePlus type into the field you’re using. It never takes screenshots."
    public static let typingOff = "Off. Your text is held for you to copy instead of typed."

    /// Shown when Screen Recording has been allowed.
    public static let contextGranted = "Screen Recording is on. A box you draw is read once, kept in memory for that dictation and never saved."
    /// Shown after the one request, while the switch is still off.
    public static let contextDenied = "Screen Recording is off. Boxes you draw carry the app’s own text only."
    /// The confirmation that states the scope before anything is asked of macOS.
    public static let contextConfirmTitle = "Let VoicePlus read the text inside a box you draw?"
    public static let contextConfirmAction = "Continue to macOS"

    /// The hard-mute row while listening is possible.
    public static let hardMuteOff = "Closes every capture and ends latch. Stays on through sleep and relaunch until you unmute."
    /// The status menu's Mute is the one control when this window is not wired to the live mute.
    public static let hardMuteUnwired = "Use Mute in the menu bar. This window can’t reach the microphone switch right now."

    // MARK: On this Mac or a service

    public static let speechTitle = "Speech recognition"
    public static let speechDetail = "Audio is transcribed on this Mac. It is never sent to a service."
    public static let localStagesTitle = "Formatting, style and actions"
    public static let localStagesDetail = "No service is selected, so every stage runs on this Mac."
    public static let otherStagesDetail = "Every other step runs on this Mac."
    public static func serviceDetail(provider: String) -> String {
        "Sends the text of each dictation to \(provider) for this step. Audio is never sent."
    }
    public static let service = "Service"

    public static let syncTitle = "Sync"
    /// Design §9 Providers / Sync empty: "Sync is off".
    public static let syncOff = "Sync is off"
    public static let syncUnavailableDetail = "Nothing leaves this Mac for sync."
    public static let syncNotPaired = "Not paired"
    public static let syncNotPairedDetail = "No device is paired, so nothing leaves this Mac for sync."
    public static let syncPaired = "Paired"
    public static let syncPairedDetail = "Dictionary, personas, snippets and settings travel end-to-end encrypted through your sync folder. Never audio, history or held text."
    public static let openSync = "Open Sync"

    // MARK: History

    /// Prototype row: "Save dictation history · Recovery drafts are kept separately until resolved."
    public static let saveHistoryTitle = "Save dictation history"
    public static let saveHistoryOn = "On. Past dictations are kept as text on this Mac for Today and search. Recovery drafts are kept separately until resolved."
    /// Says all the switch does, never "nothing is kept": new dictations are not written to history
    /// (W3H `DictationHistoryGate` stops the lander, the coordinator's shell path and the turn store)
    /// and Today lists and searches nothing (S7b); held text stays under its own switch.
    public static let saveHistoryOff = "Off. New dictations aren’t saved, and Today doesn’t list or search past ones. Recovery drafts are kept separately until resolved."
    public static let ambientTitle = "Ambient capture"
    public static let everySpeakerTitle = "Keep what other people said too"
    public static let everySpeakerOn = "On. Speech from other people in the room is kept as transcript too, labelled as another voice. Still nothing is typed anywhere."
    public static let everySpeakerOff = "Off. Only your enrolled voice is kept; anyone else in the room is discarded."
    public static let retentionTitle = "Keep transcripts for"
    public static let recoveryTitle = "Keep held text until resolved"
    /// Design §8.1: the default; held text survives a quit.
    public static let recoveryOn = "Held text is saved on this Mac until you insert, copy or discard it. It is kept apart from history."
    /// Design §8.1: "Kept for this session only".
    public static let recoveryOff = "Kept for this session only. Held text is lost when VoicePlus quits."
    public static let dictationHistoryTitle = "Dictation history"
    public static func dictationHistoryDetail(_ count: Int) -> String {
        count == 0
            ? "No dictations kept yet. Only text is ever kept here, never audio."
            : "\(count) dictation\(count == 1 ? "" : "s") kept as text on this Mac. Audio is never part of it."
    }
    /// Before the first count: never "Nothing is saved" over data nobody has looked at.
    public static let readingKept = "Reading what’s kept…"
    public static let dictationHistoryUnreadable = "Can’t be counted right now. Nothing has been deleted."

    // MARK: Audio (J1)

    public static let retainAudioTitle = "Retain audio"
    public static let retainAudioOn = "On. Every dictation is saved as audio on this Mac, so a bad transcription can be replayed and diagnosed. Nothing is uploaded. Turn it off when you’re done."
    public static let retainAudioOff = "Off. Turn this on only to chase down bad accuracy: it saves each dictation’s audio on this Mac. Nothing is ever uploaded."
    public static let keepTitle = "Keep"
    public static let keepDetail = "Takes effect with the next recording. Each is about 1 MB."
    public static func keepLast(_ count: Int) -> String { "Keep the last \(count)" }
    public static let keepAll = "Keep all"
    public static let corpusTitle = "Corpus label"
    public static let corpusDetail = "Tags each new recording’s manifest, such as “real-room v2”. Leave blank for none."
    public static let corpusPlaceholder = "No label"
    public static let corpusSave = "Save label"
    public static let noRecordingsDetail = "Retain audio is off, and no recordings are on this Mac."
    public static let recordingsTitle = "Recordings on this Mac"
    public static let revealInFinder = "Reveal in Finder"
    public static let deleteAll = "Delete all…"
    public static func recordingsDetail(_ usage: RecordingsUsage?) -> String {
        guard let usage else { return "Can’t be counted right now. Nothing has been deleted." }
        guard usage.utterances > 0 else { return "No recordings saved." }
        return "\(usage.utterances) recording\(usage.utterances == 1 ? "" : "s") · \(usage.formattedSize)"
    }

    // MARK: Meetings and sync

    public static let meetingTitle = "Meeting capture"
    public static let meetingOn = "On. Meeting transcripts are kept on this Mac."
    public static let meetingOff = "Off. No meeting is recorded."

    // MARK: Network activity

    /// Design §9 Privacy loading.
    public static let readingActivity = "Reading activity…"
    /// Design §9: "Unreadable log is not proof of no activity".
    public static let unreadableIsNotProof = "An unreadable log is not proof that nothing left this Mac."
    public static let killSwitchTitle = "Block all network egress"
    public static let refresh = "Refresh"
    public static let allowedStatus = "Allowed"
    public static let blockedStatus = "Blocked"
    public static let blockedPurpose = "Refused while Block all network egress is on"
    public static func bytesOutToday(_ bytes: Int?) -> String {
        guard let bytes else { return "Today: can’t be read" }
        return "Today: \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)) out"
    }
    public static func checked(_ date: Date, since: Date) -> String {
        "Checked \(Self.dateTime(date)), covering \(Self.day(since)) to \(Self.day(date))."
    }

    // MARK: Delete data

    public static let deleteEverything = "Delete everything saved…"
    public static let delete = "Delete…"
    public static let keepIt = "Keep it"
    public static let cannotBeUndone = "It cannot be undone."
    public static let stillHere = "Still on this Mac"
    public static let nothingToDelete = "Nothing to delete."
    public static let uncounted = "Can’t be counted right now. Nothing has been deleted."

    // MARK: Spool

    public static let mutedNote = "VoicePlus is muted. The microphone stays closed until you unmute."

    // MARK: Diagnostics

    public static let flagsIntro = "Risky bets ship behind flags the Lab measures. Flip one to compare on your own audio."
    public static let resetFlags = "Reset to defaults"
    public static let dataPanelTitle = "Data panel"
    public static let dataPanelEmpty = "No requests recorded in the last 30 days."
    public static let exportTitle = "Diagnostics export"
    public static let exportIntro = "Redacted by default: settings, permission states and counts only. Nothing you said is included unless you turn it on here."
    public static let includeTranscripts = "Include the text of my last 20 dictations"
    public static let includeAudio = "Include my saved recordings"
    public static let copyReport = "Copy report"
    public static let saveExport = "Save…"
    public static let previewTitle = "Preview: exactly what the export contains"
    public static func exportSaved(_ path: String) -> String { "Saved to \(path)." }
    public static let exportFailed = "The export wasn’t saved. Nothing was written."

    // MARK: Dates

    static func dateTime(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated))
    }
}

/// The recordings folder's count and size (J1), under the name the Privacy page uses.
public typealias RecordingsUsage = UtteranceRecorder.FolderUsage
