import Foundation
import Shared

/// Per-day WER of what the engine produced vs what the user ended up with (after repair /
/// edits). Backs the Lab "you" tab. Stored as JSON under the store root.
public final class PersonalWERTracker: @unchecked Sendable {
    public struct Day: Codable, Equatable, Sendable {
        public var day: String            // yyyy-MM-dd (UTC)
        public var referenceWords: Int
        public var errors: Int
        public var utterances: Int
        public var wer: Double { referenceWords == 0 ? 0 : Double(errors) / Double(referenceWords) }
    }

    private let file: URL?
    private let lock = NSLock()
    private var days: [String: Day] = [:]
    private static let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC"); f.locale = Locale(identifier: "en_US_POSIX"); return f }()

    public init(file: URL? = nil) {
        self.file = file
        if let file, let d = try? Data(contentsOf: file), let arr = try? JSONDecoder().decode([Day].self, from: d) {
            for x in arr { days[x.day] = x }
        }
    }

    public static func dayKey(_ date: Date) -> String { fmt.string(from: date) }

    /// Word-level Levenshtein distance (case-insensitive, punctuation-stripped).
    public static func wordErrors(hypothesis: String, reference: String) -> (errors: Int, referenceWords: Int) {
        func norm(_ s: String) -> [String] {
            s.lowercased().split(whereSeparator: \.isWhitespace).map { $0.trimmingCharacters(in: .punctuationCharacters) }.filter { !$0.isEmpty }
        }
        let h = norm(hypothesis), r = norm(reference)
        var prev = Array(0...h.count)
        for i in 1...max(1, r.count) where i <= r.count {
            var cur = [i] + [Int](repeating: 0, count: h.count)
            for j in stride(from: 1, through: h.count, by: 1) {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return (r.isEmpty ? h.count : prev[h.count], r.count)
    }

    /// Records one utterance: what the engine emitted vs the final text after the user's corrections.
    public func record(hypothesis: String, finalText: String, at: Date = Date()) {
        let (e, n) = Self.wordErrors(hypothesis: hypothesis, reference: finalText)
        let k = Self.dayKey(at)
        lock.lock()
        var d = days[k] ?? Day(day: k, referenceWords: 0, errors: 0, utterances: 0)
        d.referenceWords += n; d.errors += e; d.utterances += 1
        days[k] = d
        let snapshot = days.values.sorted { $0.day < $1.day }
        lock.unlock()
        if let file { try? JSONEncoder().encode(snapshot).write(to: file) }
    }

    public func report() -> [Day] { lock.lock(); defer { lock.unlock() }; return days.values.sorted { $0.day < $1.day } }
    public func wer(on date: Date) -> Double? { lock.lock(); defer { lock.unlock() }; return days[Self.dayKey(date)]?.wer }

    /// Lab "you" tab payload.
    public func labRunRecord(hardware: String = ProcessInfo.processInfo.hostName) -> LabRunRecord {
        let r = report()
        let perDay = r.map { ["day": $0.day, "wer": $0.wer, "words": $0.referenceWords, "errors": $0.errors, "utterances": $0.utterances] as [String: Any] }
        let total = r.reduce(into: (0, 0)) { $0.0 += $1.errors; $0.1 += $1.referenceWords }
        let metrics: [String: Any] = ["perDay": perDay, "overallWER": total.1 == 0 ? 0 : Double(total.0) / Double(total.1), "days": r.count]
        let m = (try? JSONSerialization.data(withJSONObject: metrics)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return LabRunRecord(startedAt: Date(), finishedAt: Date(), name: "personalWER", configJSON: "{\"tab\":\"you\"}", metricsJSON: m, hardware: hardware)
    }
}
