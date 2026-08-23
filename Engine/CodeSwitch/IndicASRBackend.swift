import Foundation
import Shared

/// Engine slot for an Indic (AI4Bharat IndicConformer RNNT) recognizer. No weights ship with the
/// app — see Engine/CodeSwitch/README.md for how to add them. Conforms to `FinalRecognizer` so the
/// runtime can swap it in for the English TDT final pass when code-switching is detected.
public protocol IndicASRBackend: FinalRecognizer {
    /// ISO 639-1 codes the backend can emit (e.g. ["hi", "en"]).
    var languages: [String] { get }
    /// True only when model weights are present and loadable on this machine.
    var isAvailable: Bool { get }
}

/// Locates IndicConformer CoreML weights on disk. Expected layout (relative to the models dir):
/// `indic-conformer-600m/{Encoder,Decoder,Joint}.mlmodelc` + `vocab.json`.
public enum IndicASRAvailability {
    public static let modelFolder = "indic-conformer-600m"
    public static let requiredFiles = ["Encoder.mlmodelc", "Decoder.mlmodelc", "Joint.mlmodelc", "vocab.json"]

    public enum Status: Equatable, Sendable {
        case available(path: String)
        case missing(files: [String])
        case noModelsDirectory
    }

    public static func check(modelsDirectory: URL?, fileManager: FileManager = .default) -> Status {
        guard let dir = modelsDirectory?.appendingPathComponent(modelFolder) else { return .noModelsDirectory }
        let missing = requiredFiles.filter { !fileManager.fileExists(atPath: dir.appendingPathComponent($0).path) }
        return missing.isEmpty ? .available(path: dir.standardizedFileURL.path) : .missing(files: missing)
    }
}

/// Placeholder used until weights are installed: reports unavailable and refuses to recognize.
public final class UnavailableIndicBackend: IndicASRBackend, @unchecked Sendable {
    public let name = "indic-conformer (not installed)"
    public let languages: [String] = []
    public let isAvailable = false
    public let status: IndicASRAvailability.Status
    public init(status: IndicASRAvailability.Status) { self.status = status }

    public struct NotInstalled: Error, Equatable { public let status: IndicASRAvailability.Status }
    public func recognize(_ samples: [Float]) async throws -> [TranscriptSpan] { throw NotInstalled(status: status) }
}

/// Scripted backend for tests and the Lab: returns fixed spans regardless of audio.
public final class MockIndicBackend: IndicASRBackend, @unchecked Sendable {
    public let name = "indic-mock"
    public let languages = ["hi", "en"]
    public let isAvailable = true
    public var scripted: [TranscriptSpan]
    public private(set) var calls = 0
    public init(scripted: [TranscriptSpan]) { self.scripted = scripted }
    public func recognize(_ samples: [Float]) async throws -> [TranscriptSpan] { calls += 1; return scripted }
}

/// Picks the Indic backend when it is installed and the preview text looks code-switched;
/// otherwise falls back to the primary (English) recognizer. No user-facing toggle.
public struct CodeSwitchRouter: Sendable {
    public let primary: FinalRecognizer
    public let indic: IndicASRBackend
    /// Minimum share of Hindi words in the preview before routing to the Indic backend.
    public var hindiThreshold: Float

    public init(primary: FinalRecognizer, indic: IndicASRBackend, hindiThreshold: Float = 0.2) {
        self.primary = primary; self.indic = indic; self.hindiThreshold = hindiThreshold
    }

    public func shouldRouteToIndic(previewText: String) -> Bool {
        guard indic.isAvailable else { return false }
        let d = LanguageDetector.detect(previewText)
        if d.language == .hindi { return true }
        let hi = d.words.filter { $0.language == .hindi }.count
        let total = d.words.filter { $0.language != .unknown }.count
        return total > 0 && Float(hi) / Float(total) >= hindiThreshold
    }

    public func recognize(_ samples: [Float], previewText: String) async throws -> ScriptSegments {
        let spans = shouldRouteToIndic(previewText: previewText)
            ? try await indic.recognize(samples)
            : try await primary.recognize(samples)
        return ScriptAwareMerger().merge(spans)
    }
}
