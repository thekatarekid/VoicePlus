import Foundation
import GRDB
import Shared

/// A focused text field, as far as the counter cares: app + a stable element identity.
public struct FieldIdentity: Hashable, Sendable, Codable {
    public var appBundleID: String
    public var elementID: String

    public init(appBundleID: String, elementID: String) {
        self.appBundleID = appBundleID
        self.elementID = elementID
    }
}

/// Accessibility observation abstracted so the tracker is testable without AX permission.
/// The production implementation (Injection's AX layer) reads `AXValue` of the focused element;
/// `MockFieldObserver` scripts values in tests.
public protocol FieldObserver: AnyObject, Sendable {
    func focusedField() -> FieldIdentity?
    func value(of field: FieldIdentity) -> String?
}

public final class MockFieldObserver: FieldObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [FieldIdentity: String] = [:]
    public var focused: FieldIdentity?

    public init() {}

    public func set(_ value: String, for field: FieldIdentity) {
        lock.lock(); values[field] = value; lock.unlock()
    }
    public func focusedField() -> FieldIdentity? { focused }
    public func value(of field: FieldIdentity) -> String? { lock.lock(); defer { lock.unlock() }; return values[field] }
}

/// Result for one dictation once its 60 s observation window closes.
public struct DictationOutcome: Equatable, Sendable {
    public var utteranceID: String
    public var field: FieldIdentity
    public var wordsDictated: Int
    public var wordsEdited: Int
    public var landedAt: Date
    /// P6.1 — what was dictated and what the field held after the user's edits, so the
    /// adaptation loop can turn a post-dictation edit into a training pair.
    public var originalText: String = ""
    public var finalText: String?
    public var edited: Bool { wordsEdited > 0 }
}

/// Words dictated vs words edited within `window` of landing, in the same field. Local only.
///
/// On `recordLanding` the field value is snapshotted (baseline). Every `poll`/`observe` within
/// the window diffs the baseline against the current value; the word-level edit distance,
/// capped at the words dictated, is the edit count. After the window the outcome is final and
/// handed to `sink` (production: persists a `DictationRecord` with `edited`).
public final class ZeroEditTracker: @unchecked Sendable {
    public struct Pending: Sendable {
        public var utteranceID: String
        public var field: FieldIdentity
        public var text: String
        public var baseline: String
        public var landedAt: Date
        public var maxEdited: Int
        /// Last observed field value inside the window (P6.1 training-pair source).
        public var lastValue: String?
    }

    public let window: TimeInterval
    public let observer: any FieldObserver
    public let sink: @Sendable (DictationOutcome) -> Void
    private let lock = NSLock()
    private var pending: [String: Pending] = [:]
    public private(set) var outcomes: [DictationOutcome] = []

    public init(observer: any FieldObserver, window: TimeInterval = 60, sink: @escaping @Sendable (DictationOutcome) -> Void = { _ in }) {
        self.observer = observer
        self.window = window
        self.sink = sink
    }

    /// Call right after text has been injected. Field defaults to the currently focused one.
    public func recordLanding(utteranceID: String, text: String, field: FieldIdentity? = nil, at now: Date = Date()) {
        guard let field = field ?? observer.focusedField() else { return }
        let baseline = observer.value(of: field) ?? text
        lock.lock()
        pending[utteranceID] = Pending(utteranceID: utteranceID, field: field, text: text, baseline: baseline, landedAt: now, maxEdited: 0, lastValue: nil)
        lock.unlock()
        finalizeExpired(at: now)
    }

    /// Re-read every pending field; call on AX value-changed notifications or a timer.
    public func poll(at now: Date = Date()) {
        lock.lock()
        let items = Array(pending.values)
        lock.unlock()
        for p in items {
            if now.timeIntervalSince(p.landedAt) <= window, let current = observer.value(of: p.field) {
                observe(utteranceID: p.utteranceID, fieldValue: current, at: now)
            }
        }
        finalizeExpired(at: now)
    }

    /// Feed a field value directly (AX notification payload).
    public func observe(utteranceID: String, fieldValue: String, at now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        guard var p = pending[utteranceID], now.timeIntervalSince(p.landedAt) <= window else { return }
        let edits = WERScorer.score(reference: p.baseline, hypothesis: fieldValue).errors
        p.maxEdited = max(p.maxEdited, min(edits, Self.wordCount(p.text)))
        if fieldValue != p.baseline { p.lastValue = fieldValue }
        pending[utteranceID] = p
    }

    /// Closes every window older than `window`. Returns the outcomes finalised by this call.
    @discardableResult
    public func finalizeExpired(at now: Date = Date()) -> [DictationOutcome] {
        lock.lock()
        let done = pending.values.filter { now.timeIntervalSince($0.landedAt) > window }.sorted { $0.landedAt < $1.landedAt }
        for p in done { pending[p.utteranceID] = nil }
        let results = done.map {
            DictationOutcome(utteranceID: $0.utteranceID, field: $0.field, wordsDictated: Self.wordCount($0.text),
                             wordsEdited: $0.maxEdited, landedAt: $0.landedAt,
                             originalText: $0.text, finalText: $0.lastValue)
        }
        outcomes.append(contentsOf: results)
        lock.unlock()
        results.forEach(sink)
        return results
    }

    public var pendingCount: Int { lock.lock(); defer { lock.unlock() }; return pending.count }

    public static func wordCount(_ text: String) -> Int { TextNormalizer.words(text).count }

    /// Persists an outcome as the `edited` flag on its dictation row (if the row exists) so the
    /// daily trend can be rebuilt from `AppDatabase` alone.
    public static func persist(_ outcome: DictationOutcome, to db: AppDatabase) throws {
        try db.writer.write { db in
            try db.execute(sql: "UPDATE dictation_history SET edited = ? WHERE id = ?", arguments: [outcome.edited, outcome.utteranceID])
        }
    }
}

// MARK: Stats / trend

public struct DayStat: Equatable, Sendable, Identifiable {
    public var day: Date
    public var dictations: Int
    public var words: Int
    public var editedDictations: Int
    public var id: Date { day }
    public var zeroEditRate: Double { dictations == 0 ? 0 : Double(dictations - editedDictations) / Double(dictations) }
}

public struct ZeroEditStat: Equatable, Sendable {
    public var today: DayStat
    public var trend: [DayStat]
    /// "1,234 words · 91% zero-edit"
    public var menuBarLine: String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        let words = f.string(from: NSNumber(value: today.words)) ?? "\(today.words)"
        return "\(words) words · \(Int((today.zeroEditRate * 100).rounded()))% zero-edit"
    }
}

public enum ZeroEditStats {
    /// Daily rollup of `dictation_history` for the last `days` days (oldest first), from `AppDatabase`.
    public static func trend(db: AppDatabase, days: Int = 14, now: Date = Date(), calendar: Calendar = .current) throws -> ZeroEditStat {
        let start = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -(days - 1), to: now) ?? now)
        let rows = try db.reader.read { db in
            try DictationRecord.filter(Column("startedAt") >= start).order(Column("startedAt")).fetchAll(db)
        }
        return rollup(rows, days: days, now: now, calendar: calendar)
    }

    public static func rollup(_ rows: [DictationRecord], days: Int, now: Date, calendar: Calendar = .current) -> ZeroEditStat {
        var byDay: [Date: DayStat] = [:]
        for offset in 0..<days {
            let day = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -offset, to: now) ?? now)
            byDay[day] = DayStat(day: day, dictations: 0, words: 0, editedDictations: 0)
        }
        for row in rows {
            let day = calendar.startOfDay(for: row.startedAt)
            guard var stat = byDay[day] else { continue }
            stat.dictations += 1
            stat.words += TextNormalizer.words(row.finalText).count
            if row.edited { stat.editedDictations += 1 }
            byDay[day] = stat
        }
        let trend = byDay.values.sorted { $0.day < $1.day }
        let todayKey = calendar.startOfDay(for: now)
        return ZeroEditStat(today: byDay[todayKey] ?? DayStat(day: todayKey, dictations: 0, words: 0, editedDictations: 0), trend: trend)
    }
}
