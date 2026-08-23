import Foundation
import Shared

/// One row of `Fixtures/audio/<suite>/manifest.json`.
public struct FixtureItem: Codable, Equatable, Sendable, Identifiable {
    public var file: String
    public var transcript: String
    public var suite: String
    public var speaker: String?
    public var notes: String?
    public var source: String?
    /// Optional curated entity list; when absent `EntityScorer.detectEntities` is used.
    public var entities: [String]?

    public var id: String { "\(suite)/\(file)" }

    public init(file: String, transcript: String, suite: String, speaker: String? = nil, notes: String? = nil,
                source: String? = nil, entities: [String]? = nil) {
        self.file = file
        self.transcript = transcript
        self.suite = suite
        self.speaker = speaker
        self.notes = notes
        self.source = source
        self.entities = entities
    }
}

/// A named directory of WAVs plus its manifest.
public struct FixtureSuite: Equatable, Sendable {
    public var name: String
    public var directory: URL
    public var items: [FixtureItem]

    public init(name: String, directory: URL, items: [FixtureItem]) {
        self.name = name
        self.directory = directory
        self.items = items
    }

    public func audioURL(for item: FixtureItem) -> URL { directory.appendingPathComponent(item.file) }

    /// Suites the harness scores by default (the `vad`/`silence`/`clipping` dirs are engine-level fixtures).
    public static let defaultNames = ["clean", "noisy", "entity", "technical", "commands"]

    public static func audioRoot(fixturesDirectory: URL? = AppPaths.fixturesDirectory()) -> URL? {
        fixturesDirectory?.appendingPathComponent("audio", isDirectory: true)
    }

    public static func load(named name: String, fixturesDirectory: URL? = AppPaths.fixturesDirectory()) throws -> FixtureSuite {
        guard let root = audioRoot(fixturesDirectory: fixturesDirectory) else { throw LabError.fixturesUnavailable }
        let dir = root.appendingPathComponent(name, isDirectory: true)
        let manifest = dir.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifest.path) else { throw LabError.suiteNotFound(name) }
        let items = try JSONDecoder().decode([FixtureItem].self, from: Data(contentsOf: manifest))
        return FixtureSuite(name: name, directory: dir, items: items.sorted { $0.file < $1.file })
    }

    /// Every directory under `Fixtures/audio` that has a manifest, sorted by name.
    public static func available(fixturesDirectory: URL? = AppPaths.fixturesDirectory()) -> [String] {
        guard let root = audioRoot(fixturesDirectory: fixturesDirectory),
              let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.filter {
            FileManager.default.fileExists(atPath: root.appendingPathComponent($0).appendingPathComponent("manifest.json").path)
        }.sorted()
    }
}

public enum LabError: Error, Equatable, Sendable {
    case fixturesUnavailable
    case suiteNotFound(String)
    case transcriberUnavailable(String)
    case badArguments(String)
}
