import Engine
import Foundation
import Pipeline
import Shared
import Sync
import Testing
@testable import VoicePlusApp

/// R8.2 — retention, deletion, and the two stores that both have to forget.
///
/// V3 §8: "seven-day retention, no sync … delete, delete-all; expiry clears indexes." R7.1 shipped
/// the picker and persisted `ambient.retention.days`; nothing read it, which made the seven days a
/// promise the app displayed and did not keep. These tests are that promise.
///
/// Every delete assertion checks **both** halves: the transcript on disk and the search index in
/// SQLite. A sweep that cleared rows and left the tokens would leave deleted words findable.
@Suite("Ambient retention, deletion and index clearing (V3 §8)")
struct AmbientRetentionTests {

    static let now = Date(timeIntervalSince1970: 1_700_000_000)

    struct Rig {
        let store: AmbientTranscriptStore
        let database: AppDatabase
        let meetings: MeetingStore
        let root: URL

        let now: Date

        init(days: Int = AmbientRetentionSettings.defaultDays, now: Date = AmbientRetentionTests.now) throws {
            self.now = now
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("r82-\(UUID().uuidString)", isDirectory: true)
            meetings = MeetingStore(root: root)
            database = try AppDatabase.inMemory()
            store = AmbientTranscriptStore(meetings: meetings, database: database,
                                           retention: { AmbientRetentionPolicy(days: days) },
                                           clock: { now })
        }

        @discardableResult
        func write(_ text: String, daysAgo: Double, speaker: MeetingSpeaker = .you) throws -> String {
            try write(text, at: now.addingTimeInterval(-daysAgo * 86_400), speaker: speaker)
        }

        @discardableResult
        func write(_ text: String, at instant: Date, speaker: MeetingSpeaker = .you) throws -> String {
            try store.store(AmbientEntry(speaker: speaker, text: text, capturedAt: instant))
        }

        var indexedEntryIDs: [String] { (try? database.ambientIndexedEntryIDs()) ?? [] }
        var indexRows: Int { (try? database.ambientSearchIndexCount()) ?? 0 }
        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: The default

    @Test("seven days is the default, and it is the key the Privacy picker writes")
    func sevenDayDefault() {
        #expect(AmbientRetentionPolicy().days == 7)
        #expect(AmbientRetentionSettings.defaultDays == 7)
        #expect(AmbientRetentionPolicy.fromSettings(nil).days == 7)
        #expect(AmbientRetentionPolicy.fromSettings(InMemorySettingsStore()).days == 7)

        let store = InMemorySettingsStore()
        AmbientRetentionSettings.setDays(30, store: store)
        #expect(AmbientRetentionPolicy.fromSettings(store).days == 30)

        let policy = AmbientRetentionPolicy(days: 7)
        #expect(policy.cutoff(now: Self.now) == Self.now.addingTimeInterval(-7 * 86_400))
        #expect(policy.isExpired(Self.now.addingTimeInterval(-8 * 86_400), now: Self.now))
        #expect(!policy.isExpired(Self.now.addingTimeInterval(-6 * 86_400), now: Self.now))
        #expect(policy.sentence.contains("7 days"))
        #expect(AmbientRetentionPolicy(days: 1).sentence.contains("1 day"))
    }

    // MARK: Expiry

    @Test("expiry deletes entries older than the window — rows and index rows both")
    func expiryDeletesRowsAndIndex() throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let old = try rig.write("what I said last week", daysAgo: 8)
        let older = try rig.write("what I said the week before", daysAgo: 20)
        let fresh = try rig.write("what I said yesterday", daysAgo: 1)
        #expect(rig.store.entries().count == 3)
        #expect(Set(rig.indexedEntryIDs) == [old, older, fresh])

        let result = try rig.store.sweepExpired(now: Self.now)
        #expect(result.entriesDeleted == 2)
        #expect(result.recordsDeleted == 2, "the two expired days were whole records")
        #expect(result.indexRowsDeleted > 0, "rows were deleted but the search index was not touched")

        #expect(rig.store.entries().map(\.text) == ["what I said yesterday"])
        #expect(rig.indexedEntryIDs == [fresh], "expired words are still in the search index")
        // The words themselves, not just the ids: a stale token keeps a deleted sentence findable.
        #expect(try rig.database.ambientEntryIDs(matchingAll: ["week"]).isEmpty)
        #expect(try rig.database.ambientEntryIDs(matchingAll: ["yesterday"]) == [fresh])
    }

    @Test("a day that only partly expired keeps its surviving entries")
    func partiallyExpiredDayIsTrimmedNotDropped() throws {
        // The cutoff is anchored at *local* noon, so both entries are in one calendar day in every
        // timezone this ever runs in — one an hour before it, one an hour after.
        let cutoff = try #require(Calendar.current.date(from: DateComponents(year: 2023, month: 11, day: 14, hour: 12)))
        let now = cutoff.addingTimeInterval(86_400)
        let rig = try Rig(days: 1, now: now)
        defer { rig.cleanUp() }
        let gone = try rig.write("early", at: cutoff.addingTimeInterval(-3600))
        let kept = try rig.write("late", at: cutoff.addingTimeInterval(3600))
        #expect(AmbientTranscriptStore.recordID(ofEntry: gone) == AmbientTranscriptStore.recordID(ofEntry: kept),
                "the fixture no longer puts both entries in one day")

        let result = try rig.store.sweepExpired(now: now)
        #expect(result.entriesDeleted == 1)
        #expect(result.recordsDeleted == 0, "a day with surviving entries was deleted whole")
        #expect(rig.store.entries().map(\.text) == ["late"])
        #expect(rig.indexedEntryIDs == [kept])
    }

    @Test("a shorter window the user picked is honoured, and a longer one keeps what it promised")
    func thePickerIsWhatIsEnforced() throws {
        let oneDay = try Rig(days: 1)
        defer { oneDay.cleanUp() }
        try oneDay.write("two days ago", daysAgo: 2)
        #expect(try oneDay.store.sweepExpired(now: Self.now).entriesDeleted == 1)
        #expect(oneDay.store.entries().isEmpty)
        #expect(oneDay.indexRows == 0)

        let ninetyDays = try Rig(days: 90)
        defer { ninetyDays.cleanUp() }
        try ninetyDays.write("two days ago", daysAgo: 2)
        try ninetyDays.write("thirty days ago", daysAgo: 30)
        #expect(try ninetyDays.store.sweepExpired(now: Self.now).isEmpty)
        #expect(ninetyDays.store.entries().count == 2)
    }

    @Test("the Timeline sweeps before it answers, so an expired row can never be shown")
    func readingSweepsFirst() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        try rig.write("expired words", daysAgo: 9)
        try rig.write("recent words", daysAgo: 2)

        let rows = try await rig.store.rows(matching: "")
        #expect(rows.map(\.text) == ["recent words"], "the Timeline showed a row retention had promised to delete")
        #expect(rig.store.entries().count == 1, "reading did not actually enforce retention")
        #expect(try await rig.store.rows(matching: "expired").isEmpty)
    }

    /// A user who never opens the window must still get the seven days.
    @Test("the write path enforces retention too, without needing the Timeline to be opened")
    func writePathEnforcesRetention() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("r82-write-\(UUID().uuidString)", isDirectory: true)
        let database = try AppDatabase.inMemory()
        let clock = Clock(Self.now)
        let store = AmbientTranscriptStore(meetings: MeetingStore(root: root), database: database,
                                           retention: { AmbientRetentionPolicy(days: 7) },
                                           clock: { clock.now })
        defer { try? FileManager.default.removeItem(at: root) }

        try store.store(AmbientEntry(speaker: .you, text: "long ago", capturedAt: Self.now.addingTimeInterval(-9 * 86_400)))
        #expect(store.entries().count == 1, "the first write swept its own entry")

        // An hour later, another entry arrives: the write path re-checks expiry.
        clock.now = Self.now.addingTimeInterval(AmbientTranscriptStore.writePathSweepInterval + 1)
        try store.store(AmbientEntry(speaker: .you, text: "just now", capturedAt: clock.now))
        #expect(store.entries().map(\.text) == ["just now"], "the write path never enforced retention")
        #expect(try database.ambientEntryIDs(matchingAll: ["ago"]).isEmpty)
    }

    /// Tokens whose entry is already gone (an interrupted delete) would otherwise stay searchable
    /// forever — a 7-day promise about one of two stores.
    @Test("orphaned index rows past the cutoff are swept even when their entry is long gone")
    func orphanedIndexRowsAreSwept() throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        try rig.database.indexAmbientEntry(entryID: "ambient-2020-01-01#0", recordID: "ambient-2020-01-01",
                                          capturedAt: Self.now.addingTimeInterval(-40 * 86_400),
                                          text: "orphaned words nobody can see")
        #expect(rig.indexRows > 0)
        #expect(rig.store.entries().isEmpty, "the fixture wrote a transcript it should not have")

        let result = try rig.store.sweepExpired(now: Self.now)
        #expect(result.entriesDeleted == 0)
        #expect(result.indexRowsDeleted > 0)
        #expect(rig.indexRows == 0, "deleted words stayed findable")
    }

    // MARK: Explicit delete

    @Test("deleting one row clears that row's index entries and nothing else")
    func deleteOneRowClearsItsIndex() throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let doomed = try rig.write("delete this sentence", daysAgo: 1)
        let kept = try rig.write("keep this sentence", daysAgo: 1)

        try rig.store.delete(id: doomed)
        #expect(rig.store.entries().map(\.id) == [kept])
        #expect(rig.indexedEntryIDs == [kept], "a deleted row's words are still in the search index")
        #expect(try rig.database.ambientEntryIDs(matchingAll: ["delete"]).isEmpty)
        #expect(try rig.database.ambientEntryIDs(matchingAll: ["keep"]) == [kept])
    }

    @Test("deleting the last row of a day removes the day's record and every token it had")
    func deletingLastRowRemovesTheRecord() throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let only = try rig.write("the only thing said", daysAgo: 1)
        let recordID = AmbientTranscriptStore.recordID(ofEntry: only)

        try rig.store.delete(id: only)
        #expect(rig.store.entries().isEmpty)
        #expect(rig.indexRows == 0)
        #expect((try? rig.meetings.load(id: recordID)) == nil, "an empty ambient day was left on disk")
    }

    @Test("delete-all clears every day and empties the search index")
    func deleteAllClearsBothStores() throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        try rig.write("monday", daysAgo: 1)
        try rig.write("tuesday", daysAgo: 2)
        try rig.write("wednesday", daysAgo: 3, speaker: .others(1))
        #expect(rig.store.entries().count == 3)

        try rig.store.deleteAll()
        #expect(rig.store.entries().isEmpty)
        #expect(rig.indexRows == 0, "delete-all left the search index populated")
        #expect(rig.meetings.list().isEmpty)
        #expect(try rig.database.ambientEntryIDs(matchingAll: ["monday"]).isEmpty)
    }

    @Test("deleting an id that is not there is a no-op, not a crash and not a partial wipe")
    func deletingAnUnknownIDIsHarmless() throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let kept = try rig.write("still here", daysAgo: 1)
        try rig.store.delete(id: "ambient-1999-12-31#0")
        try rig.store.delete(id: "not-even-an-id")
        #expect(rig.store.entries().map(\.id) == [kept])
        #expect(rig.indexedEntryIDs == [kept])
    }

    // MARK: Search

    @Test("Timeline search is an AND over the index, and finds nothing that was deleted")
    func searchMatchesEveryWord() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        try rig.write("the standup is at ten", daysAgo: 1)
        try rig.write("the review is at four", daysAgo: 1)

        #expect(try await rig.store.rows(matching: "standup").map(\.text) == ["the standup is at ten"])
        #expect(try await rig.store.rows(matching: "is at").count == 2)
        #expect(try await rig.store.rows(matching: "standup four").isEmpty, "search ORed its tokens")
        #expect(try await rig.store.rows(matching: "STANDUP").count == 1, "search is case-sensitive")
        #expect(try await rig.store.rows(matching: "   ").count == 2, "a blank search hid rows")

        try rig.store.deleteAll()
        #expect(try await rig.store.rows(matching: "standup").isEmpty)
    }

    @Test("rows carry the source label, and another voice never reads as the enrolled user")
    func rowsAreLabelledHonestly() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        try rig.write("I said this", daysAgo: 1)
        try rig.write("they said this", daysAgo: 1, speaker: .others(1))

        let rows = try await rig.store.rows(matching: "")
        #expect(Set(rows.map(\.source)) == [AmbientEntry.enrolledSource, AmbientEntry.otherVoiceSource])
        let theirs = try #require(rows.first { $0.text == "they said this" })
        #expect(theirs.source == AmbientEntry.otherVoiceSource)
        #expect(theirs.source != AmbientEntry.enrolledSource)
    }

    // MARK: Launch wiring

    @Test("the composition root's store sweeps expired transcript as soon as it is built")
    func launchSweepsRetention() throws {
        // The production root, checked by name only: nothing in this suite reads or sweeps the real
        // Application Support directory, because a retention test must not delete a user's transcript.
        #expect(AmbientTranscriptStore.defaultRoot().lastPathComponent == "Ambient")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("r82-launch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try AppDatabase.inMemory()
        let settings = InMemorySettingsStore()

        // A fresh install: building the store creates nothing at all.
        let fresh = AmbientWiring.store(database: database, settings: settings, root: root)
        #expect(fresh.entries().isEmpty)
        #expect(FileManager.default.fileExists(atPath: root.path) == false,
                "building the ambient store created a directory before anything was captured")

        // Seed a long-expired day behind the launch path's back, then let launch find it.
        let seed = AmbientTranscriptStore(meetings: MeetingStore(root: root), database: database,
                                          retention: { AmbientRetentionPolicy(days: 3650) })
        try seed.store(AmbientEntry(speaker: .you, text: "ancient", capturedAt: Date().addingTimeInterval(-40 * 86_400)))
        try seed.store(AmbientEntry(speaker: .you, text: "today", capturedAt: Date()))
        #expect(seed.entries().count == 2)

        let atLaunch = AmbientWiring.store(database: database, settings: settings, root: root)
        #expect(atLaunch.entries().map(\.text) == ["today"], "the launch path did not enforce retention")
        #expect(try database.ambientEntryIDs(matchingAll: ["ancient"]).isEmpty)
    }

    @Test("the gate is read from settings, so turning ambient off stops capture immediately")
    func gateFollowsSettings() {
        let settings = InMemorySettingsStore()
        let filter = SpeakerFilter(isOn: true, gate: SpeakerGate(profile: nil), canIdentify: true)
        #expect(AmbientWiring.gate(settings: settings, filter: filter).isEnabled == false)
        AmbientCaptureSettings.setEnabled(true, store: settings)
        #expect(AmbientWiring.gate(settings: settings, filter: filter).isEnabled)
        #expect(AmbientWiring.gate(settings: settings, filter: filter).capturesEverySpeaker == false)
        AmbientCaptureSettings.setCapturesEverySpeaker(true, store: settings)
        #expect(AmbientWiring.gate(settings: settings, filter: filter).capturesEverySpeaker)
    }

    // MARK: No sync, no export, no diagnostics (V3 §8, §7.3)

    @Test("ambient transcript is in no sync payload and no export bundle")
    func ambientIsNeverSynced() throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let secret = "zebracrossing"
        try rig.write("the word \(secret) was spoken in the room", daysAgo: 1)

        let sync = SyncService(database: rig.database, snippets: InMemorySnippetStore(),
                               settings: InMemorySettingsStore())
        let payload = sync.payload(now: Self.now)

        // The payload's *shape* has no ambient field at all…
        let shape = Mirror(reflecting: SyncPayload.exampleShape).children.compactMap(\.label)
        #expect(shape.allSatisfy { !$0.lowercased().contains("ambient") && !$0.lowercased().contains("timeline") },
                "SyncPayload grew an ambient field: \(shape)")
        // …and settings are not synced either, so the ambient switches and the retention length stay
        // on the machine that set them.
        #expect(payload.settings.isEmpty)
        #expect(payload.dictionary.isEmpty)
        #expect(payload.snippets.isEmpty)

        // …and the encoded bytes — which is what an export bundle contains — hold none of the words.
        let encoded = try payload.encoded()
        let text = try #require(String(data: encoded, encoding: .utf8))
        #expect(!text.contains(secret), "ambient transcript reached the sync payload")
        #expect(!text.lowercased().contains("ambient"))

        let bundle = try ExportBundle.export(payload, passphrase: "correct horse")
        let round = try ExportBundle.`import`(bundle, passphrase: "correct horse")
        let roundText = try #require(String(data: try round.encoded(), encoding: .utf8))
        #expect(!roundText.contains(secret), "ambient transcript reached the export bundle")

        // The transcript is still on the Mac that heard it.
        #expect(rig.store.entries().count == 1)
    }

    /// V3 §7.3's rule for screen text applies to ambient transcript for the same reason: a
    /// diagnostics paste is a copy the user cannot see the inside of, and this is other people's
    /// speech.
    @Test("diagnostics report counts and never words")
    func diagnosticsCarryNoAmbientWords() throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        try rig.write("the quarterly numbers are confidential", daysAgo: 1)
        try rig.write("and so is this", daysAgo: 2, speaker: .others(1))

        let summary = rig.store.diagnosticsSummary
        #expect(summary.contains("2 entries"))
        #expect(summary.contains("2 day(s)"))
        #expect(summary.contains("retained 7 day(s)"))
        for word in ["quarterly", "numbers", "confidential", "and so is this"] {
            #expect(!summary.lowercased().contains(word), "diagnostics quoted ambient speech: \(word)")
        }
    }

    /// A mutable clock, so the write-path sweep can be tested without sleeping.
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ value: Date) { self.value = value }
        var now: Date {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }
}
