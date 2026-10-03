import CryptoKit
import Foundation
import Shared

// MARK: - V5 D2 · GGUF catalog (cleanup model, on demand)
//
// The ASR `ModelCatalog` (Engine) describes CoreML bundles; the llama.cpp models are single GGUF
// files with their own download and their own runtime, so they get a small catalog here, next to
// the provider that runs them. Every entry is `.onDemand` (HW1/HW2): downloaded when the user turns
// AI cleanup on, loaded through `ModelResidency` under `ResidencyKey.cleanup`, idled out by D5.
//
// Pick (V5 §CM): SpeakoFlow Mini Q4_K_M — vendor numbers restraint 92.6 %, damage 10.7 %, the only
// candidate tuned for restraint. S1-mini is kept as the smaller alternative (vendor-published
// comparison: restraint 22 %, damage 55 % — far worse; listed so V1 can re-measure it). The V1
// `--stage cleanup` gate on the proxy sets decides; until it has run on this Mac the pick is
// provisional (T1).

public struct LocalLLMModel: Sendable, Equatable, Identifiable {
    public var id: String
    public var displayName: String
    public var hfRepo: String
    public var fileName: String
    public var sha256: String
    public var bytes: Int64
    /// RAM while loaded (weights + 4k KV cache), for the residency budget.
    public var residentBytes: Int64
    public var license: String
    /// How the cleanup stage phrases its prompt for this model — a `Pipeline.CleanupPromptStyle` raw
    /// value ("speakoFlow": the exact fine-tune system prompt + raw transcript; "delimited": the
    /// generic template). A string so Providers does not import Pipeline.
    public var promptStyle: String

    public var downloadURL: URL {
        URL(string: "https://huggingface.co/\(hfRepo)/resolve/main/\(fileName)")!
    }

    /// Where the GGUF lives: `~/Library/Application Support/VoicePlus/Models/llm/<file>`.
    public func localURL(root: URL = LocalLLMCatalog.directory) -> URL {
        root.appendingPathComponent(fileName)
    }

    public var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

public enum LocalLLMCatalog {
    public static var directory: URL {
        AppPaths.supportDirectory().appendingPathComponent("Models/llm", isDirectory: true)
    }

    public static let speakoFlowMini = LocalLLMModel(
        id: "speakoflow-mini-0.8b-q4km", displayName: "SpeakoFlow Mini 0.8B (Q4_K_M)",
        hfRepo: "SpeakoFlow/speakoflow-mini", fileName: "SpeakoFlow-Mini-0.8B-Q4_K_M.gguf",
        sha256: "530e0a5d4e9314e3bae2c92aecf3ab39ca48e8cfecac41372058f9fcb742329d",
        bytes: 541_903_616, residentBytes: 700_000_000, license: "Apache-2.0", promptStyle: "speakoFlow")

    public static let s1Mini = LocalLLMModel(
        id: "s1-mini-q4km", displayName: "S1-mini 0.6B (Q4_K_M)",
        hfRepo: "superwhisper/s1-mini-GGUF", fileName: "s1-mini-q4_k_m.gguf",
        sha256: "3b41ebe2502cbd03e811d5d16b022f5ab551eda58d62597d152f89535003c634",
        bytes: 484_219_808, residentBytes: 620_000_000, license: "Apache-2.0 + naming clause", promptStyle: "delimited")

    // V5 CU8 — the one shared local instruct model (act planner, meeting notes/Ask, Hinglish/style
    // cleanup, N5, I3). Qwen3.5 ships unified instruct weights; the GGUFs are Unsloth's Q4_K_M
    // (Apache-2.0). Which one a Mac gets follows the HW2 plan: 16 GB → 2B, ≥ 24 GB → 4B. The cleanup
    // specialist (SpeakoFlow) stays separate. Sizes and hashes from the HF tree API (LFS oid).
    public static let qwen35_2B = LocalLLMModel(
        id: "qwen3.5-2b-q4km", displayName: "Qwen3.5-2B (Q4_K_M)",
        hfRepo: "unsloth/Qwen3.5-2B-GGUF", fileName: "Qwen3.5-2B-Q4_K_M.gguf",
        sha256: "aaf42c8b7c3cab2bf3d69c355048d4a0ee9973d48f16c731c0520ee914699223",
        bytes: 1_280_835_840, residentBytes: 1_600_000_000, license: "Apache-2.0", promptStyle: "delimited")

    public static let qwen35_4B = LocalLLMModel(
        id: "qwen3.5-4b-q4km", displayName: "Qwen3.5-4B (Q4_K_M)",
        hfRepo: "unsloth/Qwen3.5-4B-GGUF", fileName: "Qwen3.5-4B-Q4_K_M.gguf",
        sha256: "00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4",
        bytes: 2_740_937_888, residentBytes: 3_200_000_000, license: "Apache-2.0", promptStyle: "delimited")

    public static let all: [LocalLLMModel] = [speakoFlowMini, s1Mini]
    /// CU8's shared instruct models (not cleanup candidates).
    public static let shared: [LocalLLMModel] = [qwen35_2B, qwen35_4B]
    /// D2's shipping pick (provisional until the V1 cleanup gate runs on hardware).
    public static let cleanupDefault = speakoFlowMini

    public static func model(id: String) -> LocalLLMModel? { (all + shared).first { $0.id == id } }

    /// The shared model for an HW2 plan's `localLLMKey` (`Engine.ResidencyKey.localLLM2B` = "llm.qwen3.5-2b",
    /// `.localLLM4B` = "llm.qwen3.5-4b"); nil when the plan offers no on-device shared LLM (8 GB).
    /// The HW2 residency key a shared model registers under (`Engine.ResidencyKey.localLLM2B/4B`).
    public static func residencyKey(for model: LocalLLMModel) -> String {
        model.id == qwen35_4B.id ? "llm.qwen3.5-4b" : "llm.qwen3.5-2b"
    }

    /// H16 — physical memory from which the 4B is the recommended pick (24 GB+).
    public static let fourBRecommendedBytes: UInt64 = 24 << 30

    public static func sharedDefault(localLLMKey: String?) -> LocalLLMModel? {
        switch localLLMKey {
        case "llm.qwen3.5-4b"?: return qwen35_4B
        case "llm.qwen3.5-2b"?: return qwen35_2B
        default: return nil
        }
    }
}

/// What the Settings model row shows.
public enum LocalLLMInstallState: Equatable, Sendable {
    case notDownloaded
    case downloading(Double)
    case downloaded
    case failed(String)
}

public enum LocalLLMDownloadError: Error, Equatable, Sendable {
    case checksumMismatch(expected: String, actual: String)
    case transport(String)
}

/// Fetches one GGUF, verifies its SHA-256, then moves it into place. Nothing is written at the
/// final path unless the hash matches, so a half-download never looks installed.
public struct LocalLLMDownloader: Sendable {
    public var session: URLSession
    public var root: URL
    public init(session: URLSession = .shared, root: URL = LocalLLMCatalog.directory) {
        self.session = session
        self.root = root
    }

    public func isInstalled(_ model: LocalLLMModel) -> Bool {
        FileManager.default.fileExists(atPath: model.localURL(root: root).path)
    }

    @discardableResult
    public func download(_ model: LocalLLMModel, from source: URL? = nil) async throws -> URL {
        let target = model.localURL(root: root)
        if FileManager.default.fileExists(atPath: target.path) { return target }
        let temp: URL
        do {
            (temp, _) = try await session.download(from: source ?? model.downloadURL)
        } catch {
            throw LocalLLMDownloadError.transport("\(error)")
        }
        defer { try? FileManager.default.removeItem(at: temp) }
        return try installVerified(temp, as: model)
    }

    /// Verify a fetched file's SHA-256 and move it into place. Throws (and leaves nothing at the
    /// final path) on a mismatch.
    @discardableResult
    public func installVerified(_ temp: URL, as model: LocalLLMModel) throws -> URL {
        let target = model.localURL(root: root)
        let actual = try Self.sha256(of: temp)
        guard actual == model.sha256 else {
            throw LocalLLMDownloadError.checksumMismatch(expected: model.sha256, actual: actual)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        try FileManager.default.moveItem(at: temp, to: target)
        Log.providers.info("downloaded \(model.fileName) (\(model.sizeLabel))")
        return target
    }

    /// Streaming SHA-256 (a GGUF is hundreds of MB; never read it whole).
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
