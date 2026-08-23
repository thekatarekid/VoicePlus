import Foundation
import Shared

/// One hour of egress.
public struct HourBucket: Equatable, Sendable, Identifiable {
    public var hour: Date
    public var requests: Int
    public var bytesOut: Int
    public var bytesIn: Int
    public var hosts: [String]
    public var id: Date { hour }
}

/// Pure rollup + read model for the Data Panel (T5). Views bind to `DataPanelViewModel`.
public struct DataPanelModel: Equatable, Sendable {
    public var records: [NetworkLogRecord]
    public var killSwitchOn: Bool
    public var generatedAt: Date

    public init(records: [NetworkLogRecord], killSwitchOn: Bool, generatedAt: Date = Date()) {
        self.records = records
        self.killSwitchOn = killSwitchOn
        self.generatedAt = generatedAt
    }

    public static func load(db: AppDatabase, gate: EgressGate, hours: Int = 24, now: Date = Date()) throws -> DataPanelModel {
        let since = now.addingTimeInterval(-Double(hours) * 3600)
        return DataPanelModel(records: try db.networkLog(since: since, limit: 5000), killSwitchOn: gate.isKillSwitchOn, generatedAt: now)
    }

    public var totalBytesOut: Int { records.reduce(0) { $0 + $1.bytesOut } }
    public var totalBytesIn: Int { records.reduce(0) { $0 + $1.bytesIn } }
    /// "Nothing left this machine" — the default-config acceptance line.
    public var isClean: Bool { records.isEmpty }

    public func bytesOut(lastHours h: Double) -> Int {
        let since = generatedAt.addingTimeInterval(-h * 3600)
        return records.filter { $0.timestamp >= since }.reduce(0) { $0 + $1.bytesOut }
    }

    /// Hourly buckets covering the last `hours` hours, oldest first, empty hours included.
    public func hourlyRollup(hours: Int = 24, calendar: Calendar = .current) -> [HourBucket] {
        var buckets: [Date: HourBucket] = [:]
        let currentHour = Self.floorHour(generatedAt, calendar)
        for i in 0..<hours {
            let h = currentHour.addingTimeInterval(-Double(i) * 3600)
            buckets[h] = HourBucket(hour: h, requests: 0, bytesOut: 0, bytesIn: 0, hosts: [])
        }
        for r in records {
            let h = Self.floorHour(r.timestamp, calendar)
            guard var b = buckets[h] else { continue }
            b.requests += 1
            b.bytesOut += r.bytesOut
            b.bytesIn += r.bytesIn
            if !b.hosts.contains(r.host) { b.hosts.append(r.host) }
            buckets[h] = b
        }
        return buckets.values.sorted { $0.hour < $1.hour }
    }

    public func byHost() -> [(host: String, bytesOut: Int, requests: Int)] {
        var agg: [String: (Int, Int)] = [:]
        for r in records { let c = agg[r.host] ?? (0, 0); agg[r.host] = (c.0 + r.bytesOut, c.1 + 1) }
        return agg.map { (host: $0.key, bytesOut: $0.value.0, requests: $0.value.1) }.sorted { $0.bytesOut > $1.bytesOut }
    }

    static func floorHour(_ d: Date, _ calendar: Calendar) -> Date {
        let c = calendar.dateComponents([.year, .month, .day, .hour], from: d)
        return calendar.date(from: c) ?? d
    }

    public static func formatBytes(_ n: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .binary)
    }
}
