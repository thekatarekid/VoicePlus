import Foundation
import Shared

/// V5 V1 — one public evaluation set: `Fixtures/public/<set>/manifest.json` (committed, small) or
/// `<eval cache>/<set>/manifest.json` (built by the downloader next to the audio). Audio paths are
/// relative to `audioRoot`, which is relative to the eval cache; audio is never committed.
public struct EvalManifest: Codable, Equatable, Sendable {
    public var set: String
    public var language: String
    /// Directory (relative to the eval cache, or absolute) that `EvalItem.audio` paths hang off.
    public var audioRoot: String
    public var licence: String?
    public var source: String?
    public var items: [EvalItem]

    public init(set: String, language: String = "en", audioRoot: String, licence: String? = nil,
                source: String? = nil, items: [EvalItem]) {
        self.set = set; self.language = language; self.audioRoot = audioRoot
        self.licence = licence; self.source = source; self.items = items
    }
}

/// One utterance (or one cleanup / decision example). Only the fields a stage needs are set.
public struct EvalItem: Codable, Equatable, Sendable {
    public var id: String
    /// Audio path relative to the manifest's `audioRoot` (nil for text-only stages).
    public var audio: String?
    /// Reference transcript (asr), or the clean target (cleanup).
    public var reference: String
    /// Condition tags ("clean", "far-field", "snr-5", "en-IN", …) — the report breaks down by tag.
    public var tags: [String]
    /// NER-tagged entity strings that must appear in the hypothesis (entity recall).
    public var entities: [String]?
    /// cleanup: the raw ASR text fed to the cleanup model.
    public var input: String?
    /// decide: the expected label (dictate / command / edit / note / ignore …).
    public var label: String?
    /// diar: reference speaker turns.
    public var segments: [SpeakerTurn]?

    public init(id: String, audio: String? = nil, reference: String, tags: [String] = [], entities: [String]? = nil,
                input: String? = nil, label: String? = nil, segments: [SpeakerTurn]? = nil) {
        self.id = id; self.audio = audio; self.reference = reference; self.tags = tags; self.entities = entities
        self.input = input; self.label = label; self.segments = segments
    }

    enum CodingKeys: String, CodingKey { case id, audio, reference, tags, entities, input, label, segments }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        audio = try c.decodeIfPresent(String.self, forKey: .audio)
        reference = try c.decodeIfPresent(String.self, forKey: .reference) ?? ""
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        entities = try c.decodeIfPresent([String].self, forKey: .entities)
        input = try c.decodeIfPresent(String.self, forKey: .input)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        segments = try c.decodeIfPresent([SpeakerTurn].self, forKey: .segments)
    }
}

/// A speaker turn (seconds). Used for reference and hypothesis diarization.
public struct SpeakerTurn: Codable, Equatable, Sendable {
    public var speaker: String
    public var start: Double
    public var end: Double
    public init(speaker: String, start: Double, end: Double) { self.speaker = speaker; self.start = start; self.end = end }
}

public enum EvalStage: String, Codable, Sendable, CaseIterable { case asr, cleanup, diar, decide }

/// Where eval data lives. Audio cache defaults to `~/Library/Application Support/VoicePlus/Eval/`
/// (outside the repo, so never committed); manifests prefer `Fixtures/public/<set>/`.
public struct EvalPaths: Sendable {
    public var cacheDirectory: URL
    public var fixturesDirectory: URL?
    public var resultsDirectory: URL

    public init(cacheDirectory: URL = EvalPaths.defaultCache(), fixturesDirectory: URL? = AppPaths.fixturesDirectory(),
                resultsDirectory: URL? = nil) {
        self.cacheDirectory = cacheDirectory
        self.fixturesDirectory = fixturesDirectory
        self.resultsDirectory = resultsDirectory ?? EvalPaths.defaultResults(fixturesDirectory: fixturesDirectory)
    }

    public static func defaultCache() -> URL {
        if let override = ProcessInfo.processInfo.environment["VOICEPLUS_EVAL_CACHE"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return AppPaths.supportDirectory().appendingPathComponent("Eval", isDirectory: true)
    }

    /// `Lab/results` beside `Fixtures/` in the package root; falls back to the cache.
    public static func defaultResults(fixturesDirectory: URL?) -> URL {
        if let f = fixturesDirectory {
            return f.deletingLastPathComponent().appendingPathComponent("Lab/results", isDirectory: true)
        }
        return defaultCache().appendingPathComponent("results", isDirectory: true)
    }

    public func manifestCandidates(set: String) -> [URL] {
        var urls: [URL] = []
        if let f = fixturesDirectory { urls.append(f.appendingPathComponent("public/\(set)/manifest.json")) }
        urls.append(cacheDirectory.appendingPathComponent("\(set)/manifest.json"))
        return urls
    }

    public func loadManifest(set: String) throws -> EvalManifest {
        for url in manifestCandidates(set: set) where FileManager.default.fileExists(atPath: url.path) {
            return try JSONDecoder().decode(EvalManifest.self, from: Data(contentsOf: url))
        }
        throw EvalError.manifestMissing(set, hint: DatasetCatalog.entry(set).map { "run `lab fetch --set \(set)` (\($0.sizeNote))" }
                                        ?? "unknown set; `lab datasets` lists the catalogue")
    }

    public func audioURL(_ item: EvalItem, manifest: EvalManifest) -> URL? {
        guard let audio = item.audio else { return nil }
        if audio.hasPrefix("/") { return URL(fileURLWithPath: audio) }
        let root = manifest.audioRoot.hasPrefix("/") ? URL(fileURLWithPath: manifest.audioRoot, isDirectory: true)
            : cacheDirectory.appendingPathComponent(manifest.audioRoot, isDirectory: true)
        return root.appendingPathComponent(audio)
    }
}

public enum EvalError: Error, Equatable, Sendable, CustomStringConvertible {
    case manifestMissing(String, hint: String)
    case audioMissing(String)
    case backendUnavailable(String)
    case stageUnsupported(String)
    case downloadFailed(String)

    public var description: String {
        switch self {
        case .manifestMissing(let s, let hint): return "no manifest for set '\(s)': \(hint)"
        case .audioMissing(let p): return "audio not downloaded: \(p) (run `lab fetch`)"
        case .backendUnavailable(let m): return "no eval backend '\(m)'"
        case .stageUnsupported(let s): return "stage unsupported: \(s)"
        case .downloadFailed(let s): return "download failed: \(s)"
        }
    }
}
