import Foundation
import Shared

// S7f — the dated network activity list (design §8.5): every request VoicePlus made or refused, by
// day, each with its destination, purpose, time and Allowed / Blocked status.
//
// Allowed rows come from the network log (`network_log`, what a provider actually sent); blocked rows
// are the attempts the kill switch refused (`EgressGate.blockedAttempts`, kept in memory for this
// session). A refused request is still activity: the list says so rather than letting "nothing left"
// hide an attempt.

public struct NetworkActivityRow: Identifiable, Equatable, Sendable {
    public enum Status: String, Equatable, Sendable {
        case allowed, blocked

        public var label: String {
            switch self {
            case .allowed: return PrivacyCopy.allowedStatus
            case .blocked: return PrivacyCopy.blockedStatus
            }
        }
    }

    public var id: String
    public var time: Date
    /// The host the request went to (or would have).
    public var destination: String
    /// Who it was for: the provider, when the log names one.
    public var provider: String?
    public var purpose: String
    public var bytesOut: Int?
    public var bytesIn: Int?
    public var status: Status

    public init(id: String, time: Date, destination: String, provider: String? = nil, purpose: String,
                bytesOut: Int? = nil, bytesIn: Int? = nil, status: Status) {
        self.id = id
        self.time = time
        self.destination = destination
        self.provider = provider
        self.purpose = purpose
        self.bytesOut = bytesOut
        self.bytesIn = bytesIn
        self.status = status
    }

    /// "12:42 · api.openai.com · plan an action · Allowed" — for VoiceOver and the export.
    public var summary: String {
        [time.formatted(date: .omitted, time: .shortened), destination, purpose, status.label].joined(separator: " · ")
    }
}

/// One calendar day of activity, newest first inside.
public struct NetworkActivityDay: Identifiable, Equatable, Sendable {
    public var day: Date
    public var title: String
    public var rows: [NetworkActivityRow]
    public var id: Date { day }
}

public enum NetworkActivity {
    /// Merges the log and the refused attempts inside `[since, now]`, groups them by day (newest day
    /// first) and titles each day with its date — "Today · 19 Sep", "Yesterday · 18 Sep",
    /// "Thursday 17 Sep".
    public static func days(records: [NetworkLogRecord],
                            blocked: [(Date, String)],
                            since: Date,
                            now: Date = Date(),
                            calendar: Calendar = .current) -> [NetworkActivityDay] {
        var rows: [NetworkActivityRow] = records.enumerated().map { index, record in
            NetworkActivityRow(id: "log-\(record.id.map(String.init) ?? "n\(index)")-\(record.timestamp.timeIntervalSince1970)",
                               time: record.timestamp, destination: record.host,
                               provider: record.provider.isEmpty ? nil : record.provider,
                               purpose: record.purpose.isEmpty ? record.stage : record.purpose,
                               bytesOut: record.bytesOut, bytesIn: record.bytesIn, status: .allowed)
        }
        rows += blocked.enumerated().map { index, attempt in
            NetworkActivityRow(id: "blocked-\(index)-\(attempt.0.timeIntervalSince1970)", time: attempt.0,
                               destination: attempt.1, purpose: PrivacyCopy.blockedPurpose, status: .blocked)
        }
        rows = rows.filter { $0.time >= since && $0.time <= now.addingTimeInterval(60) }
        rows.sort { $0.time > $1.time }

        var order: [Date] = []
        var byDay: [Date: [NetworkActivityRow]] = [:]
        for row in rows {
            let day = calendar.startOfDay(for: row.time)
            if byDay[day] == nil { order.append(day) }
            byDay[day, default: []].append(row)
        }
        return order.map { NetworkActivityDay(day: $0, title: title(for: $0, now: now, calendar: calendar), rows: byDay[$0] ?? []) }
    }

    /// Every day is dated, including today: a list someone reads next week must still say when.
    public static func title(for day: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let date = day.formatted(.dateTime.day().month(.abbreviated))
        if calendar.isDate(day, inSameDayAs: now) { return "Today · \(date)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)),
           calendar.isDate(day, inSameDayAs: yesterday) {
            return "Yesterday · \(date)"
        }
        return day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }

    /// Bytes out per destination over the rows given, largest first — the data panel's rollup.
    public static func byDestination(_ records: [NetworkLogRecord]) -> [(destination: String, requests: Int, bytesOut: Int)] {
        var totals: [String: (Int, Int)] = [:]
        for record in records {
            let current = totals[record.host] ?? (0, 0)
            totals[record.host] = (current.0 + 1, current.1 + record.bytesOut)
        }
        return totals.map { (destination: $0.key, requests: $0.value.0, bytesOut: $0.value.1) }
            .sorted { $0.bytesOut == $1.bytesOut ? $0.destination < $1.destination : $0.bytesOut > $1.bytesOut }
    }
}
