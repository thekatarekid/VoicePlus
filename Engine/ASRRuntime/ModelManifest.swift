import CryptoKit
import Foundation

/// Sidecar written next to each downloaded model: `<modelFolder>/voiceplus-manifest.json`.
/// Records SHA256 per file so integrity can be re-verified without the network.
public struct ModelManifest: Codable, Equatable, Sendable {
    public static let fileName = "voiceplus-manifest.json"

    public struct Entry: Codable, Equatable, Sendable {
        public var path: String
        public var sha256: String
        public var size: Int64
        public init(path: String, sha256: String, size: Int64) { self.path = path; self.sha256 = sha256; self.size = size }
    }

    public var modelID: ModelID
    public var hfRepo: String
    public var downloadedAt: Date
    public var files: [Entry]

    public init(modelID: ModelID, hfRepo: String, downloadedAt: Date = Date(), files: [Entry]) {
        self.modelID = modelID; self.hfRepo = hfRepo; self.downloadedAt = downloadedAt; self.files = files
    }

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    public static func url(in folder: URL) -> URL { folder.appendingPathComponent(fileName) }

    public static func load(from folder: URL) -> ModelManifest? {
        guard let data = try? Data(contentsOf: url(in: folder)) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(ModelManifest.self, from: data)
    }

    public func save(to folder: URL) throws {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: Self.url(in: folder), options: .atomic)
    }

    /// Build a manifest by hashing every regular file under `folder` (excluding the manifest itself).
    public static func build(modelID: ModelID, hfRepo: String, folder: URL, fileManager: FileManager = .default) throws -> ModelManifest {
        var entries: [Entry] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        if let en = fileManager.enumerator(at: folder, includingPropertiesForKeys: keys) {
            for case let url as URL in en {
                let rv = try url.resourceValues(forKeys: Set(keys))
                guard rv.isRegularFile == true, url.lastPathComponent != fileName else { continue }
                let rel = url.path.replacingOccurrences(of: folder.path + "/", with: "")
                entries.append(Entry(path: rel, sha256: try SHA256Hasher.hexDigest(of: url), size: Int64(rv.fileSize ?? 0)))
            }
        }
        return ModelManifest(modelID: modelID, hfRepo: hfRepo, files: entries.sorted { $0.path < $1.path })
    }

    /// Re-hash every file; returns paths that are missing or whose digest differs.
    public func verify(in folder: URL) -> [String] {
        files.compactMap { e in
            let url = folder.appendingPathComponent(e.path)
            guard let d = try? SHA256Hasher.hexDigest(of: url), d == e.sha256 else { return e.path }
            return nil
        }
    }
}

public enum SHA256Hasher {
    /// Streaming digest (1 MB reads) so 500 MB files don't get loaded into memory.
    public static func hexDigest(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func hexDigest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
