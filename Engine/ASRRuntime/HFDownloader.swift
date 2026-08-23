import FluidAudio
import Foundation
import Shared

public struct DownloadProgressInfo: Equatable, Sendable {
    public var modelID: ModelID
    public var fraction: Double          // 0…1
    public var bytesReceived: Int64
    public var bytesExpected: Int64?     // nil when unknown
    public init(modelID: ModelID, fraction: Double, bytesReceived: Int64, bytesExpected: Int64?) {
        self.modelID = modelID; self.fraction = fraction; self.bytesReceived = bytesReceived; self.bytesExpected = bytesExpected
    }
}

public typealias ModelProgressHandler = @Sendable (DownloadProgressInfo) -> Void

public enum DownloadError: Error, Equatable {
    case httpStatus(Int, String)
    case checksumMismatch(path: String, expected: String, actual: String)
    case sizeMismatch(path: String, expected: Int64, actual: Int64)
    case cancelled
    case noRemoteFiles(ModelID)
}

/// Fetches a model's files into `folder`. Implementations: `ManifestFetcher` (our own
/// URLSession downloader) and `FluidAudioFetcher` (upstream ModelHub, handles `.mlmodelc` trees).
public protocol ModelFetcher: Sendable {
    func fetch(_ descriptor: ModelDescriptor, into folder: URL, progress: ModelProgressHandler?) async throws
}

/// Resumable HTTP downloader: keeps a `<name>.part` file, resumes with `Range: bytes=N-`,
/// verifies SHA256 / size when the descriptor provides them. Session injectable (URLProtocol mocks).
public struct HFDownloader: Sendable {
    public let session: URLSession
    public let baseURL: URL

    public init(session: URLSession = .shared, baseURL: URL = URL(string: "https://huggingface.co")!) {
        self.session = session
        self.baseURL = baseURL
    }

    public func fileURL(repo: String, subdirectory: String, path: String) -> URL {
        var p = "\(repo)/resolve/main/"
        if !subdirectory.isEmpty { p += subdirectory + "/" }
        return baseURL.appendingPathComponent(p + path)
    }

    /// Download `remote` to `destination`, resuming any partial file. Returns bytes written in total.
    @discardableResult
    public func download(_ remote: URL, to destination: URL, expectedSHA256: String? = nil, expectedSize: Int64? = nil,
                         onBytes: (@Sendable (Int64, Int64?) -> Void)? = nil) async throws -> Int64 {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let part = destination.appendingPathExtension("part")
        var offset: Int64 = 0
        if let attrs = try? fm.attributesOfItem(atPath: part.path), let size = attrs[.size] as? Int64 { offset = size }
        if let expectedSize, offset >= expectedSize { offset = 0; try? fm.removeItem(at: part) }

        var request = URLRequest(url: remote)
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw DownloadError.httpStatus(-1, remote.absoluteString) }
        switch http.statusCode {
        case 200:
            if offset > 0 { offset = 0; try? fm.removeItem(at: part) }   // server ignored Range
        case 206: break
        default: throw DownloadError.httpStatus(http.statusCode, remote.absoluteString)
        }
        let total: Int64? = expectedSize ?? (http.expectedContentLength > 0 ? http.expectedContentLength + offset : nil)

        if !fm.fileExists(atPath: part.path) { fm.createFile(atPath: part.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: part)
        try handle.seekToEnd()
        var written = offset
        var buffer = Data(); buffer.reserveCapacity(1 << 16)
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 16 {
                try handle.write(contentsOf: buffer); written += Int64(buffer.count); buffer.removeAll(keepingCapacity: true)
                onBytes?(written, total)
                try Task.checkCancellation()
            }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer); written += Int64(buffer.count) }
        try handle.close()
        onBytes?(written, total)

        if let expectedSize, written != expectedSize {
            throw DownloadError.sizeMismatch(path: destination.lastPathComponent, expected: expectedSize, actual: written)
        }
        if let expectedSHA256 {
            let actual = try SHA256Hasher.hexDigest(of: part)
            guard actual == expectedSHA256.lowercased() else {
                try? fm.removeItem(at: part)
                throw DownloadError.checksumMismatch(path: destination.lastPathComponent, expected: expectedSHA256, actual: actual)
            }
        }
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: part, to: destination)
        return written
    }
}

/// Downloads `descriptor.remoteFiles` with `HFDownloader` and writes a manifest.
public struct ManifestFetcher: ModelFetcher {
    public let downloader: HFDownloader
    public init(downloader: HFDownloader = HFDownloader()) { self.downloader = downloader }

    public func fetch(_ d: ModelDescriptor, into folder: URL, progress: ModelProgressHandler?) async throws {
        guard !d.remoteFiles.isEmpty else { throw DownloadError.noRemoteFiles(d.id) }
        let expectedTotal = d.remoteFiles.compactMap(\.size).reduce(0, +)
        var doneBytes: Int64 = 0
        for file in d.remoteFiles {
            let dest = folder.appendingPathComponent(file.path)
            if FileManager.default.fileExists(atPath: dest.path) { doneBytes += file.size ?? 0; continue }
            let base = doneBytes
            let total: Int64? = expectedTotal > 0 ? expectedTotal : nil
            let got = try await downloader.download(
                downloader.fileURL(repo: d.hfRepo, subdirectory: d.hfSubdirectory, path: file.path),
                to: dest, expectedSHA256: file.sha256, expectedSize: file.size
            ) { received, _ in
                let frac = total.map { Double(base + received) / Double($0) } ?? 0
                progress?(DownloadProgressInfo(modelID: d.id, fraction: min(frac, 1), bytesReceived: base + received, bytesExpected: total))
            }
            doneBytes += got
        }
        try ModelManifest.build(modelID: d.id, hfRepo: d.hfRepo, folder: folder).save(to: folder)
    }
}

/// Uses FluidAudio's `ModelHub` (tree listing + per-file resume + retry) for CoreML repos,
/// then records our SHA256 manifest for offline verification.
public struct FluidAudioFetcher: ModelFetcher {
    public init() {}

    public func fetch(_ d: ModelDescriptor, into folder: URL, progress: ModelProgressHandler?) async throws {
        guard let repo = Repo(rawValue: d.hfSubdirectory.isEmpty ? d.hfRepo : d.hfRepo + "/" + d.hfSubdirectory) else {
            throw DownloadError.noRemoteFiles(d.id)
        }
        // ModelHub downloads into `<root>/<repo.folderName>`; we stage there and move into our folder.
        let staging = folder.deletingLastPathComponent().appendingPathComponent(".staging-\(d.id.rawValue)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let approx = d.approxBytes
        try await ModelHub.download(repo, to: staging, progressHandler: { p in
            progress?(DownloadProgressInfo(modelID: d.id, fraction: p.fractionCompleted,
                                           bytesReceived: Int64(p.fractionCompleted * Double(approx)), bytesExpected: approx))
        })
        let produced = staging.appendingPathComponent(repo.folderName, isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: folder.path) { try fm.removeItem(at: folder) }
        try fm.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: produced, to: folder)
        try? fm.removeItem(at: staging)
        try ModelManifest.build(modelID: d.id, hfRepo: d.hfRepo, folder: folder).save(to: folder)
    }
}
