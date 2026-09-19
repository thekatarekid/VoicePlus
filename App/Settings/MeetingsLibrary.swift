import AVFoundation
import Engine
import Foundation
import Shared

// S7c — the Meetings library as data (design §8.2, §9; prototype `renderScreen` › `meetings` and
// `meeting-detail`). Everything a Meetings page says is decided here, not in a `body`, so the rows,
// the detail header, the transcript lines, the unfinished-recording banner and the Ask route are
// testable on a toolchain with no UI testing.

// MARK: - Capture facts kept beside a meeting

/// What `meeting.json` cannot say about how a meeting was captured, kept beside it as `capture.json`:
/// whether system audio was recorded, how long capture was paused, whether notes failed, and which
/// action items were ticked. A meeting without the file is an older recording: both tracks assumed,
/// never paused, notes as stored.
public struct MeetingCaptureFacts: Codable, Equatable, Sendable {
    /// False when system audio was denied or failed and capture fell back to the microphone alone
    /// (design §8.2: a visible missing-track notice; the library labels it a partial capture).
    public var systemAudioCaptured: Bool
    public var pauseCount: Int
    /// Capture time spent paused, excluded from the meeting's duration.
    public var pausedSeconds: TimeInterval
    /// Set when notes could not be prepared. The transcript stays usable (design §9).
    public var notesFailure: String?
    /// Rebuilt from a saved transcript after an interrupted recording.
    public var recovered: Bool
    /// Rebuilt from the text copy (`meeting.md`) because `meeting.json` no longer decoded. The text
    /// copy keeps speakers, timestamps and words, not confidence, so no line carries a mark.
    public var rebuiltFromText: Bool
    /// Action items the user ticked, by their text.
    public var completedActionItems: [String]

    public init(systemAudioCaptured: Bool = true, pauseCount: Int = 0, pausedSeconds: TimeInterval = 0,
                notesFailure: String? = nil, recovered: Bool = false, rebuiltFromText: Bool = false,
                completedActionItems: [String] = []) {
        self.systemAudioCaptured = systemAudioCaptured
        self.pauseCount = pauseCount
        self.pausedSeconds = max(0, pausedSeconds)
        self.notesFailure = notesFailure
        self.recovered = recovered
        self.rebuiltFromText = rebuiltFromText
        self.completedActionItems = completedActionItems
    }

    private enum CodingKeys: String, CodingKey {
        case systemAudioCaptured, pauseCount, pausedSeconds, notesFailure, recovered, rebuiltFromText, completedActionItems
    }

    /// Every field is optional on disk, so a file written before a field existed still reads (a
    /// missing key is its default, never "the facts are gone").
    public init(from decoder: any Swift.Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(systemAudioCaptured: try c.decodeIfPresent(Bool.self, forKey: .systemAudioCaptured) ?? true,
                  pauseCount: try c.decodeIfPresent(Int.self, forKey: .pauseCount) ?? 0,
                  pausedSeconds: try c.decodeIfPresent(TimeInterval.self, forKey: .pausedSeconds) ?? 0,
                  notesFailure: try c.decodeIfPresent(String.self, forKey: .notesFailure),
                  recovered: try c.decodeIfPresent(Bool.self, forKey: .recovered) ?? false,
                  rebuiltFromText: try c.decodeIfPresent(Bool.self, forKey: .rebuiltFromText) ?? false,
                  completedActionItems: try c.decodeIfPresent([String].self, forKey: .completedActionItems) ?? [])
    }

    /// True when part of the meeting is missing: a track was not captured or it was rebuilt after an
    /// interruption. Labelled in the library (design §8.2 "partially captured meetings are labelled").
    public var isPartial: Bool { !systemAudioCaptured || recovered }
}

/// Reads and writes `capture.json` and finds retained audio in a meeting's directory.
public struct MeetingFilesStore: Sendable {
    public let store: MeetingStore

    public init(store: MeetingStore) { self.store = store }

    public static let factsFileName = "capture.json"
    /// The text copy `MeetingStore.save` writes beside `meeting.json`.
    public static let textFileName = "meeting.md"
    /// Where an undecodable `meeting.json`, and the text copy it was rebuilt from, are set aside when
    /// the meeting is rebuilt, so nothing saved is overwritten.
    public static let setAsideFileName = "meeting.unreadable.json"
    public static let setAsideTextFileName = "meeting.unreadable.md"

    /// The text copy of a meeting, if one was saved and can be read.
    public func text(for id: String) -> String? {
        try? String(contentsOf: store.directory(for: id).appendingPathComponent(Self.textFileName), encoding: .utf8)
    }

    /// Moves an undecodable `meeting.json` aside, and keeps a copy of the text it is rebuilt from,
    /// before the rebuilt meeting is written in their place.
    public func setAsideUnreadable(for id: String) throws {
        let dir = store.directory(for: id)
        let manager = FileManager.default
        let text = dir.appendingPathComponent(Self.textFileName)
        let textAside = dir.appendingPathComponent(Self.setAsideTextFileName)
        if manager.fileExists(atPath: text.path) {
            if manager.fileExists(atPath: textAside.path) { try manager.removeItem(at: textAside) }
            try manager.copyItem(at: text, to: textAside)
        }
        let json = dir.appendingPathComponent("meeting.json")
        let aside = dir.appendingPathComponent(Self.setAsideFileName)
        guard manager.fileExists(atPath: json.path) else { return }
        if manager.fileExists(atPath: aside.path) { try manager.removeItem(at: aside) }
        try manager.moveItem(at: json, to: aside)
    }

    /// Audio a recording may have kept, in the order they are looked for. Nothing writes these yet;
    /// audio seeking appears only when one exists (design §8.2).
    public static let audioFileNames = ["audio.m4a", "audio.caf", "audio.wav"]

    public func facts(for id: String) -> MeetingCaptureFacts {
        let url = store.directory(for: id).appendingPathComponent(Self.factsFileName)
        guard let data = try? Data(contentsOf: url),
              let facts = try? JSONDecoder().decode(MeetingCaptureFacts.self, from: data) else {
            return MeetingCaptureFacts()
        }
        return facts
    }

    public func save(_ facts: MeetingCaptureFacts, for id: String) throws {
        let dir = store.directory(for: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(facts).write(to: dir.appendingPathComponent(Self.factsFileName), options: .atomic)
    }

    /// The meeting's retained audio file, if one was kept.
    public func retainedAudio(for id: String) -> URL? {
        let dir = store.directory(for: id)
        return Self.audioFileNames.map { dir.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Length of the retained audio in seconds, if it can be read.
    public func retainedAudioDuration(for id: String) -> TimeInterval? {
        guard let url = retainedAudio(for: id), let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.processingFormat.sampleRate
        return rate > 0 ? Double(file.length) / rate : nil
    }
}

// MARK: - Copy

/// Every sentence the Meetings section says beyond `DesignScreen.meetings` / `.meetingDetail` and the
/// recovery catalogue. Prototype strings are verbatim; the rest follow *Problem — Action*.
public enum MeetingsCopy {
    // Library (prototype `meetings`)
    public static let startRecording = "Start recording"
    public static let open = "Open"
    public static let calendarNotConnected = "Calendar is not connected. You can still record meetings manually."
    public static let notesReady = "Notes ready"
    public static let transcriptSaved = "Transcript saved"
    public static let recordingNow = "Recording"
    public static let pausedNow = "Paused"
    public static let preparingNotes = "Preparing notes"
    public static let needsRecovery = "Needs recovery"
    public static let partialCapture = "Partial capture"
    public static let microphoneOnly = "Microphone only"
    public static let today = "Today"
    public static let yesterday = "Yesterday"
    public static let underAMinute = "Under 1 min"
    public static func minutes(_ n: Int) -> String { "\(n) min" }

    // Detection opt-in (the old "Capture meetings" switch, kept reachable)
    public static let detectionTitle = "Offer to record when a meeting starts"
    public static let detectionDetail = "Watches for your camera and, if you allow it, Calendar. Off by default; nothing is asked of macOS until you turn it on."

    // Unfinished recording (prototype banner)
    public static let unfinishedHeadline = "An unfinished recording was found"
    public static func unfinishedAudio(_ clock: String) -> String { "\(clock) of audio is available on this Mac." }
    /// No audio is kept, only the transcript written as the meeting went: say what is really there.
    public static func unfinishedTranscript(_ clock: String) -> String { "\(clock) of transcript is available on this Mac." }
    public static let recover = "Recover"
    public static let discard = "Discard…"
    public static let discardTitle = "Discard unfinished recording?"
    public static func discardMessage(_ clock: String) -> String {
        "This deletes the only saved copy of \(clock) of this meeting. It can't be undone."
    }
    public static let discardConfirm = "Discard recording"
    public static let cancel = "Cancel"
    /// S11 — X02 "This meeting needs recovery": the affected row only; other meetings stay.
    public static let recoverFailed = RecoveryCatalog.entry(for: .meetingUnreadable).headline
    public static let recoverFailedDetail = "The saved transcript is unchanged. Try again, or copy diagnostics."
    /// An unreadable meeting whose text copy is missing or unreadable too.
    public static let unreadableNotRecovered = "No readable copy of this transcript was found. Its files are unchanged on this Mac."
    public static let showInFinder = "Show in Finder"

    // Delete (every delete is confirmed: it removes the only saved copy)
    public static let delete = "Delete…"
    public static func deleteTitle(_ title: String) -> String { "Delete “\(title)”?" }
    public static let deleteMessage = "This deletes its transcript and notes from this Mac. It can't be undone."
    public static let deleteUnreadableTitle = "Delete this meeting?"
    public static let deleteUnreadableMessage = "This deletes its saved files from this Mac, including any text that could still be recovered. It can't be undone."
    public static let deleteConfirm = "Delete meeting"
    /// S11 — S04 "Some items couldn’t be deleted"; the row keeps its place.
    public static let deleteFailed = RecoveryCatalog.entry(for: .deletionPartial).headline

    // Detail (prototype `meeting-detail`)
    public static let savedOnThisMac = "Saved on this Mac"
    public static let export = "Export…"
    public static let back = "Meetings"
    public static let summary = "Summary"
    public static let decisions = "Decisions"
    public static let actionItems = "Action items"
    public static let nothingNoted = "Nothing noted."
    /// The Notes tab of a meeting still being recorded.
    public static let notesAfterStop = "Notes are prepared when you stop recording."
    public static let preparingTranscript = "Preparing transcript…"
    public static let audioOnlyWhenRetained = "Audio playback appears only when audio is retained."
    public static let playFromHere = "Play from here"
    public static let uncertain = "uncertain"
    public static let searchTranscript = "Search transcript"
    public static func noMatches(_ query: String) -> String { "No matches for “\(query)”" }
    public static let clearSearch = "Clear search"
    public static func matchCount(_ n: Int) -> String { n == 1 ? "1 match" : "\(n) matches" }
    public static let tracksBoth = "Microphone and system audio were recorded."
    public static let tracksMicrophoneOnly = "System audio was not recorded — only your microphone was."
    public static let recoveredNote = "Rebuilt from the transcript saved before the recording stopped."
    public static let rebuiltFromTextNote = "Rebuilt from the text copy saved beside it. Uncertainty marks were not kept."
    public static let pausedNote = "Capture was paused during this meeting."

    // Ask (prototype Ask tab; build doc: disabled until a service exists, route disclosed)
    public static let askHeadline = "Choose how to ask."
    public static let askBody = "Select a local model or connected provider. We will show what is sent before you use it."
    public static let openProviders = "Open Providers"
    public static let askNeedsService = "Needs a configured service"
    public static let askPlaceholder = "Ask about this meeting"
    public static let ask = "Ask"
    public static let askRouteNone = "Route: none configured. Nothing leaves this Mac."
    public static func askRoute(_ name: String, local: Bool) -> String {
        local ? "Route: \(name), on this Mac. The transcript stays here."
              : "Route: \(name). This meeting’s transcript is sent there when you ask."
    }
    /// S11 — N04 "This service couldn’t complete the request": Ask is a service request; the transcript stays.
    public static let askFailed = RecoveryCatalog.entry(.N04).headline
}

// MARK: - Library rows

/// One row of the library: prototype `row('Product standup', 'Today · 24 min · Notes ready', [Open])`.
public struct MeetingRow: Equatable, Identifiable, Sendable {
    public enum Status: Equatable, Sendable {
        case notesReady, transcriptSaved, recording, paused, preparingNotes, needsRecovery

        public var word: String {
            switch self {
            case .notesReady: return MeetingsCopy.notesReady
            case .transcriptSaved: return MeetingsCopy.transcriptSaved
            case .recording: return MeetingsCopy.recordingNow
            case .paused: return MeetingsCopy.pausedNow
            case .preparingNotes: return MeetingsCopy.preparingNotes
            case .needsRecovery: return MeetingsCopy.needsRecovery
            }
        }
    }

    public var id: String
    public var title: String
    public var status: Status
    /// "Today · 24 min · Notes ready".
    public var detail: String
    /// "Partial capture" / "Microphone only" — a label beside the row, never colour alone.
    public var label: String?

    /// Recovery belongs to the affected row only (design §8.9, §9 "Affected row shows Recover").
    public var offersRecovery: Bool { status == .needsRecovery }

    /// The meeting being captured now: Expand, never Export or Delete.
    public var isLive: Bool { status == .recording || status == .paused || status == .preparingNotes }
}

/// The unfinished-recording banner (prototype `banner('An unfinished recording was found', '3:24 of
/// audio is available on this Mac.', [Recover] [Discard…])`), one per affected recording.
public struct UnfinishedRecording: Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var retained: TimeInterval
    public var hasAudio: Bool

    public var clock: String { PillTimer.text(elapsed: retained) }
    public var headline: String { MeetingsCopy.unfinishedHeadline }
    public var body: String { hasAudio ? MeetingsCopy.unfinishedAudio(clock) : MeetingsCopy.unfinishedTranscript(clock) }
    public var discardMessage: String { MeetingsCopy.discardMessage(clock) }
}

/// What the capture panel is doing right now, as the library needs to know it.
public struct MeetingLiveCapture: Equatable, Sendable {
    public var meetingID: String
    public var phase: MeetingCaptureState.Phase
    /// False once the capture fell back to the microphone alone: the live row says so already.
    public var systemAudio: Bool

    public init(meetingID: String, phase: MeetingCaptureState.Phase, systemAudio: Bool = true) {
        self.meetingID = meetingID
        self.phase = phase
        self.systemAudio = systemAudio
    }
}

public enum MeetingsLibrary {
    /// Capture time: wall-clock span minus paused time. `nil` while unfinished.
    public static func duration(_ record: MeetingRecord, facts: MeetingCaptureFacts) -> TimeInterval? {
        guard let ended = record.endedAt else { return nil }
        return max(0, ended.timeIntervalSince(record.startedAt) - facts.pausedSeconds)
    }

    /// "24 min"; "Under 1 min" below half a minute.
    public static func durationText(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        return minutes < 1 ? MeetingsCopy.underAMinute : MeetingsCopy.minutes(minutes)
    }

    /// "Today", "Yesterday", else "18 September" (with the year when it is not this year).
    public static func dayText(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return MeetingsCopy.today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return MeetingsCopy.yesterday
        }
        return dateText(date, now: now, calendar: calendar, locale: locale)
    }

    /// "18 September", or "18 September 2025" outside the current year.
    public static func dateText(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "dMMMM" : "dMMMMyyyy")
        return formatter.string(from: date)
    }

    /// How far a saved transcript reaches: its last utterance's end.
    public static func transcriptReach(_ record: MeetingRecord) -> TimeInterval {
        record.transcript.utterances.map(\.range.upperBound).max() ?? 0
    }

    /// The library with the meeting being captured listed once: in place of its saved copy, or first
    /// (it is the newest meeting) while nothing of it has been saved yet.
    public static func merge(_ records: [MeetingRecord], live: MeetingRecord?) -> [MeetingRecord] {
        guard let live else { return records }
        guard let index = records.firstIndex(where: { $0.id == live.id }) else { return [live] + records }
        var merged = records
        merged[index] = live
        return merged
    }

    /// True when a record on disk was never finished and is not the capture running now.
    public static func isUnfinished(_ record: MeetingRecord, live: MeetingLiveCapture?) -> Bool {
        record.endedAt == nil && record.id != live?.meetingID
    }

    public static func row(_ record: MeetingRecord, facts: MeetingCaptureFacts, live: MeetingLiveCapture?,
                           now: Date, calendar: Calendar = .current, locale: Locale = .current) -> MeetingRow {
        let day = dayText(record.startedAt, now: now, calendar: calendar, locale: locale)
        let status: MeetingRow.Status
        if let live, live.meetingID == record.id {
            switch live.phase {
            case .paused: status = .paused
            case .preparingNotes: status = .preparingNotes
            default: status = .recording
            }
        } else if record.endedAt == nil {
            status = .needsRecovery
        } else if record.notes != nil, facts.notesFailure == nil {
            status = .notesReady
        } else {
            status = .transcriptSaved
        }
        var parts = [day]
        if let seconds = duration(record, facts: facts) { parts.append(durationText(seconds)) }
        parts.append(status.word)
        let label: String?
        let microphoneOnlyNow = live.map { $0.meetingID == record.id && !$0.systemAudio } ?? false
        if !facts.systemAudioCaptured || microphoneOnlyNow {
            label = MeetingsCopy.microphoneOnly
        } else if facts.recovered {
            label = MeetingsCopy.partialCapture
        } else {
            label = nil
        }
        return MeetingRow(id: record.id, title: record.title, status: status,
                          detail: parts.joined(separator: PillCopy.statusSeparator), label: label)
    }

    /// Records whose title or words contain `query` (case- and diacritic-insensitive).
    public static func filter(_ records: [MeetingRecord], query: String) -> [MeetingRecord] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return records }
        return records.filter { record in
            matches(record.title, needle) || record.transcript.utterances.contains { matches($0.text, needle) }
        }
    }

    static func matches(_ text: String, _ needle: String) -> Bool {
        text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

// MARK: - Detail

/// The detail page's header: prototype `title('Product standup', '18 September · 24 min · Saved on
/// this Mac', [Export…])` — title · date · duration · local.
public struct MeetingDetailHeader: Equatable, Sendable {
    public var title: String
    public var subtitle: String

    public init(record: MeetingRecord, facts: MeetingCaptureFacts, now: Date,
                calendar: Calendar = .current, locale: Locale = .current) {
        title = record.title
        var parts = [MeetingsLibrary.dateText(record.startedAt, now: now, calendar: calendar, locale: locale)]
        if let seconds = MeetingsLibrary.duration(record, facts: facts) {
            parts.append(MeetingsLibrary.durationText(seconds))
        }
        parts.append(MeetingsCopy.savedOnThisMac)
        subtitle = parts.joined(separator: PillCopy.statusSeparator)
    }
}

/// The detail page's tabs (prototype `['Notes', 'Transcript', 'Ask']`).
public enum MeetingDetailTab: String, CaseIterable, Identifiable, Sendable {
    case notes = "Notes"
    case transcript = "Transcript"
    case ask = "Ask"

    public var id: String { rawValue }
    public var title: String { rawValue }
}

/// The capture panel's tabs. Design §8.2: "Transcript / Notes / Ask".
public enum MeetingPanelTab: String, CaseIterable, Identifiable, Sendable {
    case transcript = "Transcript"
    case notes = "Notes"
    case ask = "Ask"

    public var id: String { rawValue }
    public var title: String { rawValue }
}

/// One transcript line: prototype eyebrow "00:14 · You" over the words, with uncertain words marked.
public struct MeetingTranscriptLine: Equatable, Identifiable, Sendable {
    public var id: Int
    public var start: TimeInterval
    public var speaker: String
    public var text: String
    /// Below `TranscriptSpan`'s review threshold: drawn with the dotted uncertainty mark and read as
    /// "uncertain" by VoiceOver. Meeting utterances carry one confidence, so the mark is per line.
    public var isUncertain: Bool

    /// "00:14 · You".
    public var eyebrow: String { "\(MeetingTranscriptLine.clock(start)) · \(speaker)" }

    public static func clock(_ t: TimeInterval) -> String {
        let total = t.isFinite ? max(0, Int(t)) : 0
        let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds) : String(format: "%02d:%02d", minutes, seconds)
    }

    /// The review threshold every other surface uses (`TranscriptSpan.isLowConfidence`).
    public static let uncertainBelow: Float = TranscriptSpan.lowConfidenceThreshold

    public static func lines(_ transcript: MeetingTranscript) -> [MeetingTranscriptLine] {
        transcript.utterances.enumerated().map { index, utterance in
            MeetingTranscriptLine(id: index, start: utterance.range.lowerBound, speaker: utterance.speaker.label,
                                  text: utterance.text, isUncertain: utterance.confidence < uncertainBelow)
        }
    }

    /// Lines matching `query` (every line when it is blank).
    public static func search(_ lines: [MeetingTranscriptLine], query: String) -> [MeetingTranscriptLine] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return lines }
        return lines.filter { MeetingsLibrary.matches($0.text, needle) || MeetingsLibrary.matches($0.speaker, needle) }
    }
}

/// The Notes tab: Summary, Decisions, Action items.
public struct MeetingNotesContent: Equatable, Sendable {
    public var summary: String
    public var decisions: [String]
    public var actionItems: [String]

    public init(_ notes: MeetingNotes) {
        summary = notes.summary.joined(separator: " ")
        decisions = notes.decisions
        actionItems = notes.actionItems
    }

    public var isEmpty: Bool { summary.isEmpty && decisions.isEmpty && actionItems.isEmpty }
}

/// Where "Ask" would send a question. `nil` everywhere today: Ask in Meetings is carried to a later
/// wave (build doc §8), so the tab stays disabled with "Needs a configured service" and says so.
public struct MeetingAskRoute: Equatable, Sendable {
    public var name: String
    /// True for a local model: nothing leaves the Mac.
    public var isLocal: Bool

    public init(name: String, isLocal: Bool) {
        self.name = name
        self.isLocal = isLocal
    }

    /// The disclosure shown before any question is sent.
    public var disclosure: String { MeetingsCopy.askRoute(name, local: isLocal) }

    /// The disclosure for an optional route.
    public static func disclosure(_ route: MeetingAskRoute?) -> String {
        route?.disclosure ?? MeetingsCopy.askRouteNone
    }
}

// MARK: - Rebuilding an unreadable meeting from its text copy

/// X02 for a meeting whose `meeting.json` no longer decodes: "Preserve saved audio/text; never
/// fabricate speaker turns". `MeetingStore.save` writes a text copy beside the JSON (`meeting.md`:
/// `# Title`, `_start – end_`, notes, then `- **Speaker** [mm:ss] words` per turn); the meeting is
/// rebuilt from exactly that. Speakers, timestamps and words are read as written — a line whose
/// speaker cannot be named, or a copy with no title or start, rebuilds nothing. The copy keeps no
/// confidence, so every line is read at the review threshold (no uncertainty mark is claimed or
/// invented), and the meeting says it was rebuilt. Notes are prepared again from the transcript.
public enum MeetingTextRecovery {
    public static func parse(_ markdown: String, id: String) -> MeetingRecord? {
        let lines = markdown.components(separatedBy: .newlines)
        guard let titleLine = lines.first(where: { $0.hasPrefix("# ") }) else { return nil }
        let title = String(titleLine.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty,
              let dateLine = lines.first(where: { $0.hasPrefix("_") && $0.hasSuffix("_") && $0.count > 2 }),
              let (startedAt, endedAt) = dates(dateLine) else { return nil }
        guard let header = lines.firstIndex(of: "## Transcript") else { return nil }
        var turns: [(speaker: MeetingSpeaker, start: TimeInterval, text: String)] = []
        for line in lines[(header + 1)...] where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let turn = turn(line) else { return nil }
            turns.append(turn)
        }
        let utterances = turns.enumerated().map { index, turn -> MeetingUtterance in
            let next = index + 1 < turns.count ? turns[index + 1].start : turn.start
            return MeetingUtterance(speaker: turn.speaker, text: turn.text, range: turn.start...max(turn.start, next),
                                    confidence: MeetingTranscriptLine.uncertainBelow)
        }
        let transcript = MeetingTranscript(utterances: utterances)
        let reach = utterances.last?.range.upperBound ?? 0
        return MeetingRecord(id: id, title: title, startedAt: startedAt,
                             endedAt: endedAt ?? startedAt.addingTimeInterval(reach), transcript: transcript)
    }

    /// `_2026-09-18T12:00:00Z – 2026-09-18T12:24:00Z_`, the end optional.
    static func dates(_ line: String) -> (Date, Date?)? {
        let inner = line.dropFirst().dropLast()
        let parts = inner.components(separatedBy: " – ")
        let formatter = ISO8601DateFormatter()
        guard let first = parts.first, let start = formatter.date(from: first.trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        let end = parts.count > 1 ? formatter.date(from: parts[1].trimmingCharacters(in: .whitespaces)) : nil
        return (start, end)
    }

    /// `- **Others 2** [12:04] words` → (.others(2), 724, "words").
    static func turn(_ line: String) -> (speaker: MeetingSpeaker, start: TimeInterval, text: String)? {
        guard line.hasPrefix("- **"), let close = line.range(of: "** [") else { return nil }
        let label = String(line[line.index(line.startIndex, offsetBy: 4)..<close.lowerBound])
        let afterLabel = line[close.upperBound...]
        guard let bracket = afterLabel.firstIndex(of: "]"), let speaker = speaker(label) else { return nil }
        let clock = afterLabel[..<bracket].split(separator: ":")
        guard clock.count == 2, let minutes = Int(clock[0]), let seconds = Int(clock[1]), seconds < 60 else { return nil }
        var text = afterLabel[afterLabel.index(after: bracket)...]
        if text.hasPrefix(" ") { text = text.dropFirst() }
        return (speaker, TimeInterval(minutes * 60 + seconds), String(text))
    }

    /// The inverse of `MeetingSpeaker.label`; `nil` for a name that is not one of its labels.
    static func speaker(_ label: String) -> MeetingSpeaker? {
        if label == MeetingSpeaker.you.label { return .you }
        if label == MeetingSpeaker.others(1).label { return .others(1) }
        let prefix = "Others "
        guard label.hasPrefix(prefix), let n = Int(label.dropFirst(prefix.count)), n > 1 else { return nil }
        return .others(n)
    }

    /// What an unreadable row says about the meeting when its text copy names it: "Product standup ·
    /// 18 September"; otherwise that its files are still on this Mac.
    public static func rowDetail(_ markdown: String?, now: Date, calendar: Calendar = .current,
                                 locale: Locale = .current) -> String {
        guard let markdown, let record = parse(markdown, id: "") else { return MeetingsCopy.savedOnThisMac }
        let day = MeetingsLibrary.dayText(record.startedAt, now: now, calendar: calendar, locale: locale)
        return [record.title, day].joined(separator: PillCopy.statusSeparator)
    }
}
