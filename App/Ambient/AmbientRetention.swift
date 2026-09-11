import Foundation

// R8.2 — the seven-day promise, enforced.
//
// R7.1 shipped the picker and persisted `ambient.retention.days` (default 7). Nothing read it. A
// retention setting that nothing enforces is worse than no setting: it is a promise the app displays
// and does not keep. This is the reader, and `AmbientTranscriptStore.sweepExpired` is the enforcer.

/// How long ambient transcript may live, and the cutoff that follows from it.
public struct AmbientRetentionPolicy: Equatable, Sendable {
    public var days: Int

    public init(days: Int = AmbientRetentionSettings.defaultDays) {
        self.days = days
    }

    /// Reads the same key the Privacy picker writes, with the same default (7).
    public static func fromSettings(_ store: (any SettingsStore)?) -> AmbientRetentionPolicy {
        AmbientRetentionPolicy(days: AmbientRetentionSettings.days(store))
    }

    /// Anything spoken strictly before this instant has expired.
    public func cutoff(now: Date) -> Date { now.addingTimeInterval(-Double(days) * 86_400) }

    public func isExpired(_ capturedAt: Date, now: Date) -> Bool { capturedAt < cutoff(now: now) }

    /// What Privacy says under the picker. Plain days, never "about a week".
    public var sentence: String {
        "Ambient transcript is deleted after \(days) day\(days == 1 ? "" : "s"), and deleting it clears the Timeline's search index too."
    }
}

/// What one sweep did. Reported, not inferred: an expiry that cleared rows but left the search index
/// populated is a failure, and this makes it visible.
public struct AmbientSweepResult: Equatable, Sendable {
    /// Timeline entries whose text was deleted.
    public var entriesDeleted: Int
    /// Whole day-records removed because every entry in them had expired.
    public var recordsDeleted: Int
    /// Rows removed from the search index.
    public var indexRowsDeleted: Int

    public init(entriesDeleted: Int = 0, recordsDeleted: Int = 0, indexRowsDeleted: Int = 0) {
        self.entriesDeleted = entriesDeleted
        self.recordsDeleted = recordsDeleted
        self.indexRowsDeleted = indexRowsDeleted
    }

    public var isEmpty: Bool { entriesDeleted == 0 && recordsDeleted == 0 && indexRowsDeleted == 0 }
}
