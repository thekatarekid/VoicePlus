import Foundation
import Shared

/// Everything that syncs between devices. **Never audio** — see `SyncPayload.audit()`.
/// Each record carries `version` + `updatedAt` so conflicts resolve last-writer-wins per record.
public protocol SyncRecord: Codable, Equatable, Sendable, Identifiable where ID == String {
    var id: String { get }
    var version: Int { get set }
    var updatedAt: Date { get set }
    var deleted: Bool { get set }
}

public struct DictionaryEntry: SyncRecord {
    public var id: String
    public var word: String
    public var pronunciationHint: String?
    public var version: Int
    public var updatedAt: Date
    public var deleted: Bool
    public init(id: String = UUID().uuidString, word: String, pronunciationHint: String? = nil,
                version: Int = 1, updatedAt: Date = Date(), deleted: Bool = false) {
        self.id = id; self.word = word; self.pronunciationHint = pronunciationHint
        self.version = version; self.updatedAt = updatedAt; self.deleted = deleted
    }
}

public struct Persona: SyncRecord {
    public var id: String
    public var name: String
    public var styleRules: [String]
    public var version: Int
    public var updatedAt: Date
    public var deleted: Bool
    public init(id: String = UUID().uuidString, name: String, styleRules: [String] = [],
                version: Int = 1, updatedAt: Date = Date(), deleted: Bool = false) {
        self.id = id; self.name = name; self.styleRules = styleRules
        self.version = version; self.updatedAt = updatedAt; self.deleted = deleted
    }
}

public struct Snippet: SyncRecord {
    public var id: String
    public var trigger: String
    public var expansion: String
    public var version: Int
    public var updatedAt: Date
    public var deleted: Bool
    public init(id: String = UUID().uuidString, trigger: String, expansion: String,
                version: Int = 1, updatedAt: Date = Date(), deleted: Bool = false) {
        self.id = id; self.trigger = trigger; self.expansion = expansion
        self.version = version; self.updatedAt = updatedAt; self.deleted = deleted
    }
}

/// Opaque personal-adapter weights (P6.1). Opaque bytes, keyed by model id; never audio.
public struct AdapterWeights: SyncRecord {
    public var id: String            // model identifier the adapter applies to
    public var blob: Data
    public var version: Int
    public var updatedAt: Date
    public var deleted: Bool
    public init(id: String, blob: Data, version: Int = 1, updatedAt: Date = Date(), deleted: Bool = false) {
        self.id = id; self.blob = blob; self.version = version; self.updatedAt = updatedAt; self.deleted = deleted
    }
}

/// One settings key/value (string-encoded JSON) so each setting merges independently.
public struct SettingRecord: SyncRecord {
    public var id: String            // setting key
    public var value: String
    public var version: Int
    public var updatedAt: Date
    public var deleted: Bool
    public init(id: String, value: String, version: Int = 1, updatedAt: Date = Date(), deleted: Bool = false) {
        self.id = id; self.value = value; self.version = version; self.updatedAt = updatedAt; self.deleted = deleted
    }
}

public struct SyncPayload: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public var schemaVersion: Int
    public var deviceID: String
    public var generatedAt: Date
    public var dictionary: [DictionaryEntry]
    public var personas: [Persona]
    public var snippets: [Snippet]
    public var adapters: [AdapterWeights]
    public var settings: [SettingRecord]

    public init(deviceID: String, generatedAt: Date = Date(), dictionary: [DictionaryEntry] = [], personas: [Persona] = [],
                snippets: [Snippet] = [], adapters: [AdapterWeights] = [], settings: [SettingRecord] = []) {
        self.schemaVersion = Self.schemaVersion; self.deviceID = deviceID; self.generatedAt = generatedAt
        self.dictionary = dictionary; self.personas = personas; self.snippets = snippets
        self.adapters = adapters; self.settings = settings
    }

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e
    }
    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }
    public func encoded() throws -> Data { try Self.encoder().encode(self) }
    public static func decode(_ data: Data) throws -> SyncPayload { try decoder().decode(SyncPayload.self, from: data) }

    /// Type-level guard: walks the payload's static shape and rejects any field whose name or type
    /// smells like audio. Tests assert `audit().isEmpty`; this also runs in debug builds before every push.
    public static let forbiddenTypeNames = ["AVAudio", "AudioBuffer", "PCMBuffer", "Waveform", "Sample", "WAV"]
    public static let forbiddenFieldNames = ["audio", "wav", "pcm", "recording", "waveform", "samples"]
    public static func audit(_ sample: SyncPayload = .exampleShape) -> [String] {
        var violations: [String] = []
        func walk(_ value: Any, path: String, depth: Int) {
            guard depth < 6 else { return }
            let m = Mirror(reflecting: value)
            let tname = String(describing: type(of: value))
            if forbiddenTypeNames.contains(where: { tname.contains($0) }) { violations.append("\(path): type \(tname)") }
            for child in m.children {
                let label = child.label ?? "[]"
                let lower = label.lowercased()
                if forbiddenFieldNames.contains(where: { lower.contains($0) }) { violations.append("\(path).\(label)") }
                walk(child.value, path: "\(path).\(label)", depth: depth + 1)
            }
        }
        walk(sample, path: "SyncPayload", depth: 0)
        return violations
    }

    /// A fully populated instance so `audit()` sees every field of every record type.
    public static var exampleShape: SyncPayload {
        SyncPayload(deviceID: "x", dictionary: [DictionaryEntry(word: "w", pronunciationHint: "h")],
                    personas: [Persona(name: "p", styleRules: ["r"])], snippets: [Snippet(trigger: "t", expansion: "e")],
                    adapters: [AdapterWeights(id: "m", blob: Data([1]))], settings: [SettingRecord(id: "k", value: "v")])
    }
}
