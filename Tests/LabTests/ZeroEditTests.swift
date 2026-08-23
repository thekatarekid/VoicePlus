import Foundation
import Testing
import Shared
@testable import Lab

@Suite struct ZeroEditTests {
    let field = FieldIdentity(appBundleID: "com.apple.Notes", elementID: "textarea-1")
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func untouchedDictationIsZeroEdit() {
        let obs = MockFieldObserver()
        obs.focused = field
        obs.set("Hello there team", for: field)
        let tracker = ZeroEditTracker(observer: obs)
        tracker.recordLanding(utteranceID: "u1", text: "Hello there team", at: t0)
        tracker.poll(at: t0.addingTimeInterval(30))
        #expect(tracker.finalizeExpired(at: t0.addingTimeInterval(59)).isEmpty)
        let done = tracker.finalizeExpired(at: t0.addingTimeInterval(61))
        #expect(done == [DictationOutcome(utteranceID: "u1", field: field, wordsDictated: 3, wordsEdited: 0, landedAt: t0,
                                          originalText: "Hello there team", finalText: nil)])
        #expect(tracker.pendingCount == 0)
    }

    @Test func scriptedEditSessionCountsWords() {
        let obs = MockFieldObserver()
        obs.focused = field
        obs.set("Draft: ping kothari about the mumbai call", for: field)
        var sunk: [DictationOutcome] = []
        let box = Box()
        let tracker = ZeroEditTracker(observer: obs) { box.append($0) }
        tracker.recordLanding(utteranceID: "u1", text: "ping kothari about the mumbai call", at: t0)
        obs.set("Draft: ping Kothari about the mumbai call", for: field)     // case-only fix -> not an edit
        tracker.poll(at: t0.addingTimeInterval(5))
        obs.set("Draft: ping Kothari about the Mumbai office call", for: field) // 1 insertion
        tracker.poll(at: t0.addingTimeInterval(20))
        obs.set("Draft: ping Kothari re the Mumbai office call", for: field)   // + 1 substitution
        tracker.poll(at: t0.addingTimeInterval(40))
        obs.set("Draft: completely different", for: field)                      // after the window: ignored
        tracker.poll(at: t0.addingTimeInterval(61))
        sunk = box.items
        #expect(sunk.count == 1)
        #expect(sunk[0].wordsDictated == 6)
        #expect(sunk[0].wordsEdited == 2)
        #expect(sunk[0].edited)
    }

    @Test func editsAreCappedAndOtherFieldsIgnored() {
        let obs = MockFieldObserver()
        let other = FieldIdentity(appBundleID: "com.apple.Notes", elementID: "other")
        obs.focused = field
        obs.set("one two", for: field)
        obs.set("unrelated", for: other)
        let tracker = ZeroEditTracker(observer: obs)
        tracker.recordLanding(utteranceID: "u1", text: "one two", at: t0)
        obs.set("a b c d e f g h i j", for: field)
        obs.set("changed a lot here", for: other)
        tracker.poll(at: t0.addingTimeInterval(1))
        let done = tracker.finalizeExpired(at: t0.addingTimeInterval(100))
        #expect(done.map(\.wordsEdited) == [2])
        // No focused field and no explicit field -> nothing tracked.
        obs.focused = nil
        tracker.recordLanding(utteranceID: "u2", text: "x", at: t0)
        #expect(tracker.pendingCount == 0)
    }

    @Test func outcomePersistsAndDailyTrendRollsUp() throws {
        let db = try AppDatabase.inMemory()
        let cal = Calendar(identifier: .gregorian)
        let now = t0
        func insert(_ id: String, _ text: String, daysAgo: Int) throws {
            let u = Utterance(id: UUID(), spans: [TranscriptSpan(text: text, confidence: 0.9, audioRange: 0...1, provenance: [.asr])],
                              startedAt: cal.date(byAdding: .day, value: -daysAgo, to: now)!, endedAt: nil, register: .chat, route: .dictate)
            var rec = try DictationRecord(utterance: u, finalText: text, appBundleID: "a")
            rec.id = id
            try db.insert(rec)
        }
        try insert("a", "one two three", daysAgo: 0)
        try insert("b", "four five", daysAgo: 0)
        try insert("c", "six", daysAgo: 1)
        try insert("d", "ancient words here", daysAgo: 40)
        try ZeroEditTracker.persist(DictationOutcome(utteranceID: "b", field: field, wordsDictated: 2, wordsEdited: 1, landedAt: now), to: db)
        try ZeroEditTracker.persist(DictationOutcome(utteranceID: "a", field: field, wordsDictated: 3, wordsEdited: 0, landedAt: now), to: db)

        let stat = try ZeroEditStats.trend(db: db, days: 14, now: now, calendar: cal)
        #expect(stat.trend.count == 14)
        #expect(stat.today.dictations == 2 && stat.today.words == 5 && stat.today.editedDictations == 1)
        #expect(stat.today.zeroEditRate == 0.5)
        #expect(stat.trend.last == stat.today)
        #expect(stat.trend[12].dictations == 1 && stat.trend[12].words == 1 && stat.trend[12].zeroEditRate == 1)
        #expect(stat.trend.reduce(0) { $0 + $1.words } == 6, "40-day-old row excluded")
        #expect(stat.menuBarLine == "5 words · 50% zero-edit")
    }

    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        var items: [DictationOutcome] = []
        func append(_ o: DictationOutcome) { lock.lock(); items.append(o); lock.unlock() }
    }
}
