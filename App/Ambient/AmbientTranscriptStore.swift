import Engine
import Foundation
import Shared

// R8.1 / R8.2 — where ambient transcript lives, and every way it leaves.
//
// **Reuses the meeting store** (the R8 build item says so): the same `MeetingStore`, the same
// `MeetingRecord` / `MeetingUtterance` / `MeetingTranscript` types, the same JSON + Markdown on
// disk. No second transcript format, no second writer. It is rooted at
// `…/Application Support/VoicePlus/Ambient` rather than `…/Meetings` for one reason: the Meetings
// section lists everything under its root, and an ambient day silently appearing there as a
// "meeting" — exportable, notes-generated — is the surveillance reading V3 §14.11 is about.
//
// One record per calendar day (`ambient-2026-09-11`), utterances inside it, offsets from midnight.
// Ambient capture has no sessions; a day is the unit a person actually asks about ("what did I say
// this morning"), and per-entry timestamps keep expiry exact rather than rounding to the day.
//
// Deletion always has two halves — the transcript on disk and the search index in SQLite — and
// every path here does both. V3 §8: "expiry clears indexes".
//
// Nothing in this file can type. It writes files and index rows; it has no injector, no pasteboard,
// no CGEvent, and `App/Ambient` does not import `Injection`.

/// The Timeline's store: ambient transcript in, `TimelineRow`s out, and the deletes that R8.2 owes.
public final class AmbientTranscriptStore: AmbientTimelineReading, AmbientTranscriptSink, @unchecked Sendable {
    /// The meeting store, reused. Rooted at the ambient directory.
    public let meetings: MeetingStore
    /// Holds the search index only — never the transcript text.
    private let database: AppDatabase?
    private let retention: () -> AmbientRetentionPolicy
    private let clock: @Sendable () -> Date
    private let lock = NSLock()
    /// When the write path last enforced retention. See `sweepIfDue`.
    private var lastSweep: Date?

    /// How often the write path re-checks expiry. Retention is a promise in days, so an hour is
    /// exact enough, and it keeps a busy capture session from stat-ing the whole directory per entry.
    static let writePathSweepInterval: TimeInterval = 3600

    /// Where ambient transcript is kept. Separate from `Meetings/`; see the note above.
    /// V5 N4: one store with Notes — `…/VoicePlus/Notes`. The legacy `…/Ambient` is folded in by
    /// `NotesStore.preparedDefaultRoot()` at launch; asking for the path moves nothing.
    public static func defaultRoot() -> URL {
        NotesStore.defaultRoot()
    }

    public init(meetings: MeetingStore = MeetingStore(root: AmbientTranscriptStore.defaultRoot()),
                database: AppDatabase?,
                retention: @escaping () -> AmbientRetentionPolicy = { AmbientRetentionPolicy() },
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.meetings = meetings
        self.database = database
        self.retention = retention
        self.clock = clock
        // The clock starts here, so the *first* write after launch does not sweep. Startup expiry is
        // `AmbientWiring.store`'s job and says so in the log; a store that silently deleted on its
        // first write would also delete an entry being restored or backfilled.
        self.lastSweep = clock()
    }

    /// Convenience for the composition root: retention follows the Privacy picker.
    public convenience init(database: AppDatabase?, settings: (any SettingsStore)?) {
        self.init(database: database, retention: { AmbientRetentionPolicy.fromSettings(settings) })
    }

    // MARK: Ids

    static let recordPrefix = "ambient-"

    static func recordID(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%@%04d-%02d-%02d", recordPrefix, c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// `<recordID>#<milliseconds from midnight>` — stable under deletion of *other* entries, which
    /// an index-based id would not be.
    static func entryID(recordID: String, offset: TimeInterval) -> String {
        "\(recordID)#\(Int((offset * 1000).rounded()))"
    }

    static func recordID(ofEntry entryID: String) -> String {
        String(entryID.split(separator: "#").first ?? "")
    }

    // MARK: Writing

    /// Appends one entry to its day, indexes its words, and returns the Timeline id.
    ///
    /// Transcript only: no audio is written here, whatever the audio-retention switch says. That
    /// switch belongs to the recorder (`AmbientCaptureSettings.audioRetentionKey`) and nothing on
    /// this path reads it.
    @discardableResult
    public func store(_ entry: AmbientEntry) throws -> String {
        lock.lock(); defer { lock.unlock() }
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: entry.capturedAt)
        let id = Self.recordID(for: entry.capturedAt, calendar: calendar)
        var record = (try? meetings.load(id: id))
            ?? MeetingRecord(id: id, title: "Ambient", startedAt: day, labeler: "ambient")

        var offset = entry.capturedAt.timeIntervalSince(day)
        // Two entries in the same millisecond would collide on the id; nudge rather than overwrite.
        while record.transcript.utterances.contains(where: { abs($0.range.lowerBound - offset) < 0.0005 }) {
            offset += 0.001
        }
        let upper = offset + max(0, entry.duration)
        record.transcript.utterances.append(MeetingUtterance(speaker: entry.speaker, text: entry.text,
                                                            range: offset...max(offset, upper),
                                                            confidence: entry.confidence))
        record.transcript.utterances.sort { $0.range.lowerBound < $1.range.lowerBound }
        try meetings.save(record)

        let entryID = Self.entryID(recordID: id, offset: offset)
        try? database?.indexAmbientEntry(entryID: entryID, recordID: id,
                                        capturedAt: day.addingTimeInterval(offset), text: entry.text)
        sweepIfDueLocked()
        return entryID
    }

    /// R8.2 — retention on the *write* path, so the seven days hold on a Mac whose Timeline is never
    /// opened. At most hourly; `sweepExpired` is what actually deletes.
    private func sweepIfDueLocked() {
        let now = clock()
        if let last = lastSweep, now.timeIntervalSince(last) < Self.writePathSweepInterval { return }
        lastSweep = now
        _ = try? sweepExpiredLocked(now: now)
    }

    // MARK: Reading

    /// Every stored entry, newest first. The Timeline's own ordering.
    public func entries() -> [StoredEntry] {
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: meetings.root.path)) ?? []
        var out: [StoredEntry] = []
        for id in ids where id.hasPrefix(Self.recordPrefix) {
            guard let record = try? meetings.load(id: id) else { continue }
            let day = record.startedAt
            for u in record.transcript.utterances {
                out.append(StoredEntry(id: Self.entryID(recordID: id, offset: u.range.lowerBound),
                                       recordID: id,
                                       capturedAt: day.addingTimeInterval(u.range.lowerBound),
                                       speaker: u.speaker, text: u.text))
            }
        }
        return out.sorted { $0.capturedAt > $1.capturedAt }
    }

    /// One entry as stored: no audio, no spans, no route.
    public struct StoredEntry: Equatable, Sendable, Identifiable {
        public var id: String
        public var recordID: String
        public var capturedAt: Date
        public var speaker: MeetingSpeaker
        public var text: String

        public var sourceLabel: String {
            switch speaker {
            case .you: return AmbientEntry.enrolledSource
            case .others: return AmbientEntry.otherVoiceSource
            }
        }

        public var row: TimelineRow { TimelineRow(id: id, time: capturedAt, source: sourceLabel, text: text) }
    }

    /// `AmbientTimelineReading`: sweeps expired transcript first, so the Timeline can never show a
    /// row that retention has already promised to have deleted, and then answers the query.
    public func rows(matching query: String) async throws -> [TimelineRow] {
        _ = try? sweepExpired()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = entries()
        guard !trimmed.isEmpty else { return all.map(\.row) }

        let tokens = AmbientSearchIndex.uniqueTokens(trimmed)
        guard !tokens.isEmpty else { return all.map(\.row) }
        if let database, let matches = try? database.ambientEntryIDs(matchingAll: tokens) {
            let wanted = Set(matches)
            return all.filter { wanted.contains($0.id) }.map(\.row)
        }
        // No index available (no database on this install): match the same tokens directly, so
        // search never silently returns nothing.
        return all.filter { entry in
            let have = Set(AmbientSearchIndex.tokens(entry.text))
            return tokens.allSatisfy(have.contains)
        }.map(\.row)
    }

    // MARK: Deleting — transcript *and* index, every time

    /// Explicit delete of one Timeline row.
    public func delete(id: String) throws {
        lock.lock(); defer { lock.unlock() }
        try deleteLocked(id: id)
    }

    private func deleteLocked(id: String) throws {
        let recordID = Self.recordID(ofEntry: id)
        if var record = try? meetings.load(id: recordID) {
            let before = record.transcript.utterances.count
            record.transcript.utterances.removeAll {
                Self.entryID(recordID: recordID, offset: $0.range.lowerBound) == id
            }
            if record.transcript.utterances.isEmpty {
                try? meetings.delete(id: recordID)
            } else if record.transcript.utterances.count != before {
                try meetings.save(record)
            }
        }
        _ = try? database?.deleteAmbientIndex(entryID: id)
    }

    /// Delete-all. Both halves, and the directory itself, so nothing is left to re-index.
    public func deleteAll() throws {
        lock.lock(); defer { lock.unlock() }
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: meetings.root.path)) ?? []
        for id in ids where id.hasPrefix(Self.recordPrefix) { try? meetings.delete(id: id) }
        _ = try? database?.deleteAllAmbientIndex()
    }

    /// R8.2 — expiry. Deletes every entry older than the retention window and the index rows that
    /// made those words findable. Safe to call often; it is what `rows(matching:)` calls first.
    @discardableResult
    public func sweepExpired(now: Date? = nil) throws -> AmbientSweepResult {
        lock.lock(); defer { lock.unlock() }
        return try sweepExpiredLocked(now: now)
    }

    private func sweepExpiredLocked(now: Date? = nil) throws -> AmbientSweepResult {
        let at = now ?? clock()
        let cutoff = retention().cutoff(now: at)
        var result = AmbientSweepResult()

        let ids = (try? FileManager.default.contentsOfDirectory(atPath: meetings.root.path)) ?? []
        for id in ids where id.hasPrefix(Self.recordPrefix) {
            guard var record = try? meetings.load(id: id) else { continue }
            let day = record.startedAt
            let expired = record.transcript.utterances.filter { day.addingTimeInterval($0.range.lowerBound) < cutoff }
            guard !expired.isEmpty else { continue }
            record.transcript.utterances.removeAll { day.addingTimeInterval($0.range.lowerBound) < cutoff }
            result.entriesDeleted += expired.count
            for u in expired {
                let entryID = Self.entryID(recordID: id, offset: u.range.lowerBound)
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
        // Backstop: tokens older than the cutoff whose entry is already gone (an interrupted delete)
        // would otherwise stay searchable forever.
        result.indexRowsDeleted += (try? database?.deleteAmbientIndex(before: cutoff)) ?? 0
        if !result.isEmpty {
            Log.app.notice("ambient retention: \(result.entriesDeleted) entries, \(result.recordsDeleted) days, \(result.indexRowsDeleted) index rows deleted")
        }
        return result
    }

    // MARK: Diagnostics

    /// What may be said about this store in a diagnostics copy: counts and paths, never words.
    /// V3 §7.3's rule for screen text applies to ambient transcript for the same reason — it is
    /// other people's speech, and a diagnostics paste is a copy the user cannot see the inside of.
    public var diagnosticsSummary: String {
        let all = entries()
        let days = Set(all.map(\.recordID)).count
        let indexRows = database.flatMap { try? $0.ambientSearchIndexCount() } ?? 0
        return "ambient: \(all.count) entries across \(days) day(s), \(indexRows) index rows, retained \(retention().days) day(s)"
    }
}
