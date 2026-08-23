import Foundation
import GRDB

// Simple record structs, one per table. Column names match the migration.

public struct DictationRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord, Identifiable {
    public static let databaseTableName = "dictation_history"

    public var id: String
    public var startedAt: Date
    public var endedAt: Date?
    public var register: String
    public var route: String
    public var appBundleID: String?
    public var rawText: String
    public var finalText: String
    public var spansJSON: String
    public var edited: Bool

    public init(id: String = UUID().uuidString, startedAt: Date, endedAt: Date?, register: String, route: String,
                appBundleID: String?, rawText: String, finalText: String, spansJSON: String, edited: Bool = false) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.register = register
        self.route = route
        self.appBundleID = appBundleID
        self.rawText = rawText
        self.finalText = finalText
        self.spansJSON = spansJSON
        self.edited = edited
    }

    /// Builds a record from an `Utterance`, serialising its spans.
    public init(utterance: Utterance, finalText: String, appBundleID: String?) throws {
        let json = String(decoding: try JSONEncoder().encode(utterance.spans), as: UTF8.self)
        self.init(id: utterance.id.uuidString, startedAt: utterance.startedAt, endedAt: utterance.endedAt,
                  register: utterance.register.rawValue, route: utterance.route.rawValue, appBundleID: appBundleID,
                  rawText: utterance.text, finalText: finalText, spansJSON: json)
    }

    public func spans() throws -> [TranscriptSpan] {
        try JSONDecoder().decode([TranscriptSpan].self, from: Data(spansJSON.utf8))
    }
}

public struct CorrectionRecord: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "corrections"

    public var id: Int64?
    public var utteranceID: String
    public var createdAt: Date
    public var original: String
    public var corrected: String
    public var audioStart: Double
    public var audioEnd: Double
    /// e.g. "voiceRepair", "keyboardEdit", "dualPath"
    public var source: String

    public init(id: Int64? = nil, utteranceID: String, createdAt: Date = Date(), original: String, corrected: String,
                audioRange: ClosedRange<TimeInterval>, source: String) {
        self.id = id
        self.utteranceID = utteranceID
        self.createdAt = createdAt
        self.original = original
        self.corrected = corrected
        self.audioStart = audioRange.lowerBound
        self.audioEnd = audioRange.upperBound
        self.source = source
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct FeatureFlagRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "feature_flags"
    public var id: String
    public var enabled: Bool
    public var updatedAt: Date

    public init(id: String, enabled: Bool, updatedAt: Date = Date()) {
        self.id = id
        self.enabled = enabled
        self.updatedAt = updatedAt
    }
}

public struct LabRunRecord: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "lab_runs"
    public var id: Int64?
    public var startedAt: Date
    public var finishedAt: Date?
    public var name: String
    public var configJSON: String
    public var metricsJSON: String
    public var hardware: String

    public init(id: Int64? = nil, startedAt: Date = Date(), finishedAt: Date? = nil, name: String,
                configJSON: String, metricsJSON: String, hardware: String) {
        self.id = id
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.name = name
        self.configJSON = configJSON
        self.metricsJSON = metricsJSON
        self.hardware = hardware
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// Every byte that leaves the machine (Data Panel, P1.11 T5).
public struct NetworkLogRecord: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "network_log"
    public var id: Int64?
    public var timestamp: Date
    public var stage: String
    public var provider: String
    public var host: String
    public var bytesOut: Int
    public var bytesIn: Int
    public var purpose: String

    public init(id: Int64? = nil, timestamp: Date = Date(), stage: String, provider: String, host: String,
                bytesOut: Int, bytesIn: Int, purpose: String) {
        self.id = id
        self.timestamp = timestamp
        self.stage = stage
        self.provider = provider
        self.host = host
        self.bytesOut = bytesOut
        self.bytesIn = bytesIn
        self.purpose = purpose
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct InjectionOutcomeRecord: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "injection_outcomes"
    public var id: Int64?
    public var timestamp: Date
    public var utteranceID: String?
    public var appBundleID: String
    /// e.g. "ax", "paste", "keystroke"
    public var method: String
    public var succeeded: Bool
    public var latencyMs: Int
    public var detail: String?

    public init(id: Int64? = nil, timestamp: Date = Date(), utteranceID: String?, appBundleID: String, method: String,
                succeeded: Bool, latencyMs: Int, detail: String? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.utteranceID = utteranceID
        self.appBundleID = appBundleID
        self.method = method
        self.succeeded = succeeded
        self.latencyMs = latencyMs
        self.detail = detail
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct SnippetRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord, Identifiable {
    public static let databaseTableName = "snippets"
    public var id: String
    public var trigger: String
    public var body: String
    public var createdAt: Date

    public init(id: String = UUID().uuidString, trigger: String, body: String, createdAt: Date = Date()) {
        self.id = id
        self.trigger = trigger
        self.body = body
        self.createdAt = createdAt
    }
}

public struct PersonaRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord, Identifiable {
    public static let databaseTableName = "personas"
    public var id: String
    public var appBundleID: String
    public var instructions: String
    public var updatedAt: Date

    public init(id: String = UUID().uuidString, appBundleID: String, instructions: String, updatedAt: Date = Date()) {
        self.id = id
        self.appBundleID = appBundleID
        self.instructions = instructions
        self.updatedAt = updatedAt
    }
}

public struct DictionaryRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord, Identifiable {
    public static let databaseTableName = "dictionary"
    public var id: String
    public var term: String
    /// JSON array of spoken forms, or comma-separated; stage-defined.
    public var spokenForms: String
    public var weight: Double
    public var createdAt: Date

    public init(id: String = UUID().uuidString, term: String, spokenForms: String = "", weight: Double = 1.0, createdAt: Date = Date()) {
        self.id = id
        self.term = term
        self.spokenForms = spokenForms
        self.weight = weight
        self.createdAt = createdAt
    }
}
