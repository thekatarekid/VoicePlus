import Engine
import Foundation
import Shared

// V5 N4 — one store for Notes and the ambient Timeline.
//
// `NotesStore` is `AmbientTranscriptStore` extended, not a second transcript format: the same
// `MeetingStore`, the same `MeetingRecord` / `MeetingUtterance` shape, the same JSON + Markdown on
// disk, the same `AmbientSearchIndex` tokens in SQLite. The root moves from `…/VoicePlus/Ambient` to
// `…/VoicePlus/Notes`; `AmbientTranscriptStore.defaultRoot()` now answers that root too, so the
// Timeline and Notes read and write one directory. The legacy `…/Ambient` directory is folded in
// on first launch (`migrateLegacyAmbient`).
//
// Layout under the root:
// - `ambient-YYYY-MM-DD` — ambient Timeline days, written by `AmbientTranscriptStore` (unchanged).
// - `notes-YYYY-MM-DD-<source>` — notes, one record per day per source. `labeler` is
//   `note:<source>`, so the source survives without a new field on `MeetingUtterance`.
//
// Entry ids are `<recordID>#<ms from midnight>` for both kinds, exactly as the ambient store mints
// them, so one search index and one delete path serve both.
//
// Deletion has two halves here too — the transcript on disk and the search index — and every path
// does both. Note search does not rely on the index alone: the ambient sweep's backstop
// (`deleteAmbientIndex(before:)`) and ambient delete-all clear index rows by date for the whole
// table, so a note older than the ambient window is also matched directly on its tokens.
//
// Nothing in this file can type. "Insert here" is the Notes section's job, through a closure the
// composition root hands it.

/// Where a note came from — V5 N2's routes, plus the ambient Timeline. Raw values are stable on disk.
public enum NoteSource: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Hands-free (latched) speech the arbiter did not deliver: K4 "another voice", latch in a meeting.
    case latch
    /// The ambient Timeline (Listen & note / ambient capture).
    case ambient
    /// Dictation with no focused text field to land in.
    case noField = "no-field"
    /// The user switched apps mid-segment; the words are kept rather than typed into the new app.
    case appSwitch = "app-switch"
    /// "note …" wake verb.
    case wakeVerb = "wake-verb"
    /// Spoken during a meeting, meant as an aside.
    case meetingAside = "meeting-aside"
    /// An ask-band prompt the user declined.
    case declinedAsk = "declined-ask"
    /// The ambient lower-middle band (worth noting, not acting on).
    case lowerMiddle = "lower-middle"
    /// Spoken while an agent action was running.
    case agentRunning = "agent-running"
    /// Ambient speech in Listen & note mode (L1).
    case listenAndNote = "listen-note"

    public var id: String { rawValue }

    /// The row's source tag.
    public var label: String {
        switch self {
        case .latch: return "Latch"
        case .ambient: return "Ambient"
        case .noField: return "No field"
        case .appSwitch: return "App switch"
        case .wakeVerb: return "“Note …”"
        case .meetingAside: return "Meeting aside"
        case .declinedAsk: return "Declined ask"
        case .lowerMiddle: return "Overheard"
        case .agentRunning: return "During action"
        case .listenAndNote: return "Listen & note"
        }
    }

    static let labelerPrefix = "note:"
    var labeler: String { Self.labelerPrefix + rawValue }

    static func from(labeler: String) -> NoteSource? {
        guard labeler.hasPrefix(labelerPrefix) else { return nil }
        return NoteSource(rawValue: String(labeler.dropFirst(labelerPrefix.count)))
    }
}

/// One row of Notes: a note, or an ambient Timeline entry.
public struct NoteEntry: Equatable, Sendable, Identifiable {
    public var id: String
    public var recordID: String
    public var capturedAt: Date
    public var source: NoteSource
    public var speaker: MeetingSpeaker
    public var text: String

    public init(id: String, recordID: String, capturedAt: Date, source: NoteSource,
                speaker: MeetingSpeaker = .you, text: String) {
        self.id = id
        self.recordID = recordID
        self.capturedAt = capturedAt
        self.source = source
        self.speaker = speaker
        self.text = text
    }

    /// Ambient rows follow the ambient retention and never count as unread.
    public var isAmbient: Bool { source == .ambient }
}

/// How long notes live. Separate from the ambient window (7 days by default): a note is something
/// the user, or a route on their behalf, chose to keep. `days == nil` keeps notes until deleted.
public struct NotesRetentionPolicy: Equatable, Sendable {
    public static let key = "notes.retention.days"
    public static let defaultDays = 30
    public static let choices: [Int?] = [7, 30, 90, nil]

    public var days: Int?

    public init(days: Int? = NotesRetentionPolicy.defaultDays) { self.days = days }

    /// Stored as a string: a number of days, or `"forever"`. Missing or unreadable → 30 days.
    public static func fromSettings(_ store: (any SettingsStore)?) -> NotesRetentionPolicy {
        guard let raw = store?.string(key) else { return NotesRetentionPolicy() }
        if raw == "forever" { return NotesRetentionPolicy(days: nil) }
        guard let n = Int(raw), n > 0 else { return NotesRetentionPolicy() }
        return NotesRetentionPolicy(days: n)
    }

    public static func save(_ policy: NotesRetentionPolicy, to store: (any SettingsStore)?) {
        store?.set(policy.days.map(String.init) ?? "forever", for: key)
    }

    public func cutoff(now: Date) -> Date? { days.map { now.addingTimeInterval(-Double($0) * 86_400) } }
}

/// What the first-launch fold of `…/Ambient` into `…/Notes` did.
public struct NotesMigrationResult: Equatable, Sendable {
    /// Day directories moved as they were.
    public var moved: Int = 0
    /// Day directories whose entries were merged into a day already present under Notes.
    public var merged: Int = 0
    /// The legacy root no longer exists afterwards.
    public var removedLegacyRoot: Bool = false
    public init(moved: Int = 0, merged: Int = 0, removedLegacyRoot: Bool = false) {
        self.moved = moved; self.merged = merged; self.removedLegacyRoot = removedLegacyRoot
    }
}

/// Notes + the ambient Timeline, one directory, one index.
public final class NotesStore: @unchecked Sendable {
    /// Posted (object: the store) after any add or delete, so the sidebar, pill and menu recount.
    public static let didChange = Notification.Name("VoicePlus.NotesStore.didChange")
    /// When Notes was last opened (ISO 8601). Notes newer than this are unread.
    public static let lastSeenKey = "notes.lastSeenAt"

    public let meetings: MeetingStore
    /// The ambient half, unchanged: the Timeline still writes and sweeps through it.
    public let ambient: AmbientTranscriptStore
    private let database: AppDatabase?
    private let retention: () -> NotesRetentionPolicy
    private let clock: @Sendable () -> Date
    private let lock = NSLock()

    static let recordPrefix = "notes-"

    /// `…/Application Support/VoicePlus/Notes`. Pure: no migration, no directory creation.
    public static func defaultRoot() -> URL {
        AppPaths.supportDirectory().appendingPathComponent("Notes", isDirectory: true)
    }

    /// The pre-N4 ambient root.
    public static func legacyAmbientRoot() -> URL {
        AppPaths.supportDirectory().appendingPathComponent("Ambient", isDirectory: true)
    }

    /// The default root with the legacy fold done — once per process, on first use. Called by the
    /// composition root's store (`init(database:settings:)`), never by merely asking for the path, so
    /// a test that checks `defaultRoot()` by name cannot move a user's files.
    @discardableResult
    public static func preparedDefaultRoot() -> URL { preparedRoot }

    private static let preparedRoot: URL = {
        let root = defaultRoot()
        let result = migrateLegacyAmbient(from: legacyAmbientRoot(), to: root)
        if result.moved + result.merged > 0 {
            Log.app.notice("notes: folded \(result.moved + result.merged) ambient day(s) into Notes (moved \(result.moved), merged \(result.merged))")
        }
        return root
    }()

    public init(root: URL = NotesStore.defaultRoot(),
                database: AppDatabase?,
                retention: @escaping () -> NotesRetentionPolicy = { NotesRetentionPolicy() },
                ambientRetention: @escaping () -> AmbientRetentionPolicy = { AmbientRetentionPolicy() },
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.meetings = MeetingStore(root: root)
        self.database = database
        self.retention = retention
        self.clock = clock
        self.ambient = AmbientTranscriptStore(meetings: meetings, database: database,
                                              retention: ambientRetention, clock: clock)
    }

    /// The composition root's store: both retentions follow their settings, and the legacy
    /// `…/Ambient` directory is folded in first (once per process).
    public convenience init(database: AppDatabase?, settings: (any SettingsStore)?) {
        self.init(root: NotesStore.preparedDefaultRoot(), database: database,
                  retention: { NotesRetentionPolicy.fromSettings(settings) },
                  ambientRetention: { AmbientRetentionPolicy.fromSettings(settings) })
    }

    // MARK: Migration

    /// Folds every `ambient-*` day under `legacy` into `root`. Idempotent: a day already present under
    /// `root` is merged (utterances at the same offset are kept once), the legacy directory is removed
    /// once empty, and a second call finds nothing to do. Entry ids do not change (they are
    /// `<recordID>#<offset>` and neither moves), so the search index needs no rewrite.
    @discardableResult
    public static func migrateLegacyAmbient(from legacy: URL, to root: URL) -> NotesMigrationResult {
        var result = NotesMigrationResult()
        let fm = FileManager.default
        guard legacy.standardizedFileURL != root.standardizedFileURL,
              fm.fileExists(atPath: legacy.path) else { return result }
        let source = MeetingStore(root: legacy)
        let target = MeetingStore(root: root)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let ids = (try? fm.contentsOfDirectory(atPath: legacy.path)) ?? []
        for id in ids where !id.hasPrefix(".") {
            let from = source.directory(for: id)
            let to = target.directory(for: id)
            if !fm.fileExists(atPath: to.path) {
                if (try? fm.moveItem(at: from, to: to)) != nil { result.moved += 1 }
                continue
            }
            guard let old = try? source.load(id: id), var new = try? target.load(id: id) else { continue }
            for u in old.transcript.utterances
            where !new.transcript.utterances.contains(where: { abs($0.range.lowerBound - u.range.lowerBound) < 0.0005 }) {
                new.transcript.utterances.append(u)
            }
            new.transcript.utterances.sort { $0.range.lowerBound < $1.range.lowerBound }
            if (try? target.save(new)) != nil {
                try? fm.removeItem(at: from)
                result.merged += 1
            }
        }
        let left = ((try? fm.contentsOfDirectory(atPath: legacy.path)) ?? []).filter { !$0.hasPrefix(".") }
        if left.isEmpty {
            try? fm.removeItem(at: legacy)
            result.removedLegacyRoot = !fm.fileExists(atPath: legacy.path)
        }
        return result
    }

    // MARK: Ids

    static func recordID(for date: Date, source: NoteSource, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%@%04d-%02d-%02d-%@", recordPrefix, c.year ?? 0, c.month ?? 0, c.day ?? 0, source.rawValue)
    }

    // MARK: Writing

    /// Adds one note, indexes its words, and returns its id. Empty text is not a note.
    @discardableResult
    public func add(_ text: String, source: NoteSource, at capturedAt: Date? = nil,
                    duration: TimeInterval = 0, confidence: Float = 1,
                    speaker: MeetingSpeaker = .you) throws -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if source == .ambient {
            // The Timeline's own writer, so ambient stays one format with one retention.
            let id = try ambient.store(AmbientEntry(speaker: speaker, text: trimmed, capturedAt: capturedAt ?? clock(),
                                                    duration: duration, confidence: confidence))
            notifyChanged()
            return id
        }
        let id: String
        do {
            lock.lock(); defer { lock.unlock() }
            let when = capturedAt ?? clock()
            let calendar = Calendar.current
            let day = calendar.startOfDay(for: when)
            let recordID = Self.recordID(for: when, source: source, calendar: calendar)
            var record = (try? meetings.load(id: recordID))
                ?? MeetingRecord(id: recordID, title: "Notes · \(source.label)", startedAt: day, labeler: source.labeler)
            var offset = when.timeIntervalSince(day)
            while record.transcript.utterances.contains(where: { abs($0.range.lowerBound - offset) < 0.0005 }) {
                offset += 0.001
            }
            record.transcript.utterances.append(MeetingUtterance(speaker: speaker, text: trimmed,
                                                                range: offset...(offset + max(0, duration)),
                                                                confidence: confidence))
            record.transcript.utterances.sort { $0.range.lowerBound < $1.range.lowerBound }
            try meetings.save(record)
            id = AmbientTranscriptStore.entryID(recordID: recordID, offset: offset)
            try? database?.indexAmbientEntry(entryID: id, recordID: recordID,
                                            capturedAt: day.addingTimeInterval(offset), text: trimmed)
        }
        notifyChanged()
        return id
    }

    // MARK: Reading

    /// Notes only (no ambient rows), newest first.
    public func notes() -> [NoteEntry] {
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: meetings.root.path)) ?? []
        var out: [NoteEntry] = []
        for id in ids where id.hasPrefix(Self.recordPrefix) {
            guard let record = try? meetings.load(id: id), let source = NoteSource.from(labeler: record.labeler) else { continue }
            for u in record.transcript.utterances {
                out.append(NoteEntry(id: AmbientTranscriptStore.entryID(recordID: id, offset: u.range.lowerBound),
                                     recordID: id, capturedAt: record.startedAt.addingTimeInterval(u.range.lowerBound),
                                     source: source, speaker: u.speaker, text: u.text))
            }
        }
        return out.sorted { $0.capturedAt > $1.capturedAt }
    }

    /// Notes and ambient entries together, newest first — the Notes section's list.
    public func entries(includingAmbient: Bool = true) -> [NoteEntry] {
        var all = notes()
        if includingAmbient {
            all += ambient.entries().map {
                NoteEntry(id: $0.id, recordID: $0.recordID, capturedAt: $0.capturedAt, source: .ambient,
                          speaker: $0.speaker, text: $0.text)
            }
        }
        return all.sorted { $0.capturedAt > $1.capturedAt }
    }

    /// Token search (AND), the Timeline's tokenizer and index. Sweeps expired rows first, so a row
    /// retention has promised to delete is never shown.
    public func entries(matching query: String, includingAmbient: Bool = true) -> [NoteEntry] {
        _ = try? sweepExpired()
        let all = entries(includingAmbient: includingAmbient)
        let tokens = AmbientSearchIndex.uniqueTokens(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !tokens.isEmpty else { return all }
        let indexed = Set((try? database?.ambientEntryIDs(matchingAll: tokens)) ?? [])
        return all.filter { entry in
            if indexed.contains(entry.id) { return true }
            let have = Set(AmbientSearchIndex.tokens(entry.text))
            return tokens.allSatisfy(have.contains)
        }
    }

    /// Notes newer than `since` (ambient rows never count).
    public func unreadCount(since: Date?) -> Int {
        let all = notes()
        guard let since else { return all.count }
        return all.filter { $0.capturedAt > since }.count
    }

    public static func lastSeen(_ settings: (any SettingsStore)?) -> Date? {
        settings?.string(lastSeenKey).flatMap { ISO8601DateFormatter().date(from: $0) }
    }

    /// Posted after Notes is opened (everything read), so the pill chip and menu row clear.
    public static let didMarkSeen = Notification.Name("VoicePlus.NotesStore.didMarkSeen")

    public static func markSeen(_ settings: (any SettingsStore)?, at date: Date = Date()) {
        settings?.set(ISO8601DateFormatter().string(from: date), for: lastSeenKey)
        NotificationCenter.default.post(name: didMarkSeen, object: nil)
    }

    // MARK: Deleting — transcript *and* index, every time

    public func delete(id: String) throws {
        let recordID = AmbientTranscriptStore.recordID(ofEntry: id)
        if recordID.hasPrefix(AmbientTranscriptStore.recordPrefix) {
            try ambient.delete(id: id)
            notifyChanged()
            return
        }
        do {
            lock.lock(); defer { lock.unlock() }
            if var record = try? meetings.load(id: recordID) {
                let before = record.transcript.utterances.count
                record.transcript.utterances.removeAll {
                    AmbientTranscriptStore.entryID(recordID: recordID, offset: $0.range.lowerBound) == id
                }
                if record.transcript.utterances.isEmpty {
                    try? meetings.delete(id: recordID)
                    _ = try? database?.deleteAmbientIndex(recordID: recordID)
                } else if record.transcript.utterances.count != before {
                    try meetings.save(record)
                }
            }
            _ = try? database?.deleteAmbientIndex(entryID: id)
        }
        notifyChanged()
    }

    /// Deletes every note (ambient rows are the Timeline's to delete) and their index rows.
    public func deleteAllNotes() throws {
        do {
            lock.lock(); defer { lock.unlock() }
            let ids = (try? FileManager.default.contentsOfDirectory(atPath: meetings.root.path)) ?? []
            for id in ids where id.hasPrefix(Self.recordPrefix) {
                try? meetings.delete(id: id)
                _ = try? database?.deleteAmbientIndex(recordID: id)
            }
        }
        notifyChanged()
    }

    /// Retention: notes older than the notes window (nothing when "forever") and ambient entries
    /// older than the ambient window, with their index rows.
    @discardableResult
    public func sweepExpired(now: Date? = nil) throws -> AmbientSweepResult {
        let at = now ?? clock()
        var result = (try? ambient.sweepExpired(now: at)) ?? AmbientSweepResult()
        guard let cutoff = retention().cutoff(now: at) else { return result }
        lock.lock(); defer { lock.unlock() }
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: meetings.root.path)) ?? []
        for id in ids where id.hasPrefix(Self.recordPrefix) {
            guard var record = try? meetings.load(id: id) else { continue }
            let day = record.startedAt
            let expired = record.transcript.utterances.filter { day.addingTimeInterval($0.range.lowerBound) < cutoff }
            guard !expired.isEmpty else { continue }
            record.transcript.utterances.removeAll { day.addingTimeInterval($0.range.lowerBound) < cutoff }
            result.entriesDeleted += expired.count
            for u in expired {
                let entryID = AmbientTranscriptStore.entryID(recordID: id, offset: u.range.lowerBound)
                result.indexRowsDeleted += (try? database?.deleteAmbientIndex(entryID: entryID)) ?? 0
            }
            if record.transcript.utterances.isEmpty {
                try? meetings.delete(id: id)
                result.recordsDeleted += 1
                result.indexRowsDeleted += (try? database?.deleteAmbientIndex(recordID: id)) ?? 0
            } else {
                try? meetings.save(record)
            }
        }
        return result
    }

    // MARK: Export

    /// Markdown, grouped by day, oldest first inside a day: `- 09:14 · Latch — text`.
    public static func markdown(_ entries: [NoteEntry], title: String = "Notes",
                                calendar: Calendar = .current) -> String {
        let days = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.capturedAt) }
        let dayFormat = DateFormatter()
        dayFormat.dateStyle = .full; dayFormat.timeStyle = .none
        let timeFormat = DateFormatter()
        timeFormat.dateFormat = "HH:mm"
        var s = "# \(title)\n"
        for day in days.keys.sorted(by: >) {
            s += "\n## \(dayFormat.string(from: day))\n\n"
            for e in days[day]!.sorted(by: { $0.capturedAt < $1.capturedAt }) {
                s += "- \(timeFormat.string(from: e.capturedAt)) · \(e.source.label) — \(e.text)\n"
            }
        }
        return s
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
