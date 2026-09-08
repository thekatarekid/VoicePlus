import Foundation
import Testing
import Shared
@testable import Engine

/// In-memory HTTP server honouring `Range` requests; records requests for assertions.
final class MockHTTPProtocol: URLProtocol {
    nonisolated(unsafe) static var files: [String: Data] = [:]      // path → bytes
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var failAfterBytes: Int? = nil       // simulate a dropped connection
    nonisolated(unsafe) static var ignoreRange = false
    static let lock = NSLock()

    static func reset() { lock.withLock { files = [:]; requests = []; failAfterBytes = nil; ignoreRange = false } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self.requests.append(request) }
        guard let url = request.url, let data = Self.files[url.path] else {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self); return
        }
        var start = 0
        var status = 200
        if !Self.ignoreRange, let range = request.value(forHTTPHeaderField: "Range"), range.hasPrefix("bytes=") {
            start = Int(range.dropFirst(6).split(separator: "-")[0]) ?? 0
            status = 206
        }
        var body = data.subdata(in: start..<data.count)
        let failAfter = Self.failAfterBytes
        if let failAfter, failAfter < body.count { body = body.prefix(failAfter) }
        let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Length": "\(data.count - start)"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        if let failAfter, failAfter < data.count - start {
            Self.lock.withLock { Self.failAfterBytes = nil }
            // Let the delivered bytes drain to the consumer before the connection "drops".
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { [self] in
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            }
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

private func mockSession() -> URLSession {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [MockHTTPProtocol.self]
    return URLSession(configuration: cfg)
}

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("voiceplus-asr-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("ModelManager / HF download (T2)", .serialized)
struct ASRModelManagerTests {
    @Test func downloadResumesFromPartialFile() async throws {
        MockHTTPProtocol.reset()
        let payload = Data((0..<300_000).map { UInt8($0 % 251) })
        MockHTTPProtocol.files["/acme/m/resolve/main/blob.bin"] = payload
        MockHTTPProtocol.failAfterBytes = 120_000
        let dl = HFDownloader(session: mockSession(), baseURL: URL(string: "https://mock.local")!)
        let dest = try tempDir().appendingPathComponent("blob.bin")
        let remote = dl.fileURL(repo: "acme/m", subdirectory: "", path: "blob.bin")
        #expect(remote.absoluteString == "https://mock.local/acme/m/resolve/main/blob.bin")

        // First attempt: connection drops mid-way, .part is kept.
        await #expect(throws: (any Error).self) { try await dl.download(remote, to: dest, expectedSize: Int64(payload.count)) }
        let partSize = try FileManager.default.attributesOfItem(atPath: dest.path + ".part")[.size] as? Int64
        #expect((partSize ?? 0) > 0 && (partSize ?? 0) < Int64(payload.count))

        // Second attempt resumes with a Range header and completes + verifies sha256.
        let sha = SHA256Hasher.hexDigest(of: payload)
        let written = try await dl.download(remote, to: dest, expectedSHA256: sha, expectedSize: Int64(payload.count))
        #expect(written == Int64(payload.count))
        #expect(try Data(contentsOf: dest) == payload)
        let ranges = MockHTTPProtocol.requests.compactMap { $0.value(forHTTPHeaderField: "Range") }
        #expect(ranges.count == 1 && ranges[0] == "bytes=\(partSize!)-")
        #expect(!FileManager.default.fileExists(atPath: dest.path + ".part"))
    }

    @Test func serverIgnoringRangeRestartsCleanly() async throws {
        MockHTTPProtocol.reset()
        let payload = Data(repeating: 7, count: 50_000)
        MockHTTPProtocol.files["/r/resolve/main/f"] = payload
        MockHTTPProtocol.ignoreRange = true
        let dir = try tempDir()
        let dest = dir.appendingPathComponent("f")
        try Data(repeating: 1, count: 10_000).write(to: dir.appendingPathComponent("f.part"))
        let dl = HFDownloader(session: mockSession(), baseURL: URL(string: "https://mock.local")!)
        try await dl.download(URL(string: "https://mock.local/r/resolve/main/f")!, to: dest)
        #expect(try Data(contentsOf: dest) == payload)
    }

    @Test func checksumMismatchIsRejected() async throws {
        MockHTTPProtocol.reset()
        MockHTTPProtocol.files["/r/resolve/main/f"] = Data("hello".utf8)
        let dl = HFDownloader(session: mockSession(), baseURL: URL(string: "https://mock.local")!)
        let dest = try tempDir().appendingPathComponent("f")
        await #expect(throws: DownloadError.self) {
            try await dl.download(URL(string: "https://mock.local/r/resolve/main/f")!, to: dest, expectedSHA256: String(repeating: "0", count: 64))
        }
        #expect(!FileManager.default.fileExists(atPath: dest.path))
    }

    @Test func manifestFetcherWritesVerifiableManifest() async throws {
        MockHTTPProtocol.reset()
        let a = Data("model-a".utf8), b = Data("model-b".utf8)
        MockHTTPProtocol.files["/org/repo/resolve/main/sub/a.bin"] = a
        MockHTTPProtocol.files["/org/repo/resolve/main/sub/b.bin"] = b
        let d = ModelDescriptor(id: .whisperSmall, kind: .whisper, hfRepo: "org/repo", hfSubdirectory: "sub",
                                requiredPaths: ["a.bin", "b.bin"],
                                remoteFiles: [RemoteFile(path: "a.bin", sha256: SHA256Hasher.hexDigest(of: a), size: Int64(a.count)),
                                              RemoteFile(path: "b.bin", size: Int64(b.count))],
                                approxBytes: 14, displayName: "t", license: "MIT")
        let folder = try tempDir().appendingPathComponent("m")
        let fetcher = ManifestFetcher(downloader: HFDownloader(session: mockSession(), baseURL: URL(string: "https://mock.local")!))
        nonisolated(unsafe) var fractions: [Double] = []
        try await fetcher.fetch(d, into: folder) { fractions.append($0.fraction) }
        #expect(fractions.last == 1.0)
        let manifest = try #require(ModelManifest.load(from: folder))
        #expect(manifest.files.map(\.path) == ["a.bin", "b.bin"])
        #expect(manifest.totalBytes == 14)
        #expect(manifest.verify(in: folder).isEmpty)
        try Data("corrupt".utf8).write(to: folder.appendingPathComponent("b.bin"))
        #expect(manifest.verify(in: folder) == ["b.bin"])
    }

    /// Fake fetcher that materialises the required files, counting calls.
    final class FakeFetcher: ModelFetcher, @unchecked Sendable {
        var calls = 0
        let delay: UInt64
        init(delay: UInt64 = 0) { self.delay = delay }
        func fetch(_ d: ModelDescriptor, into folder: URL, progress: ModelProgressHandler?) async throws {
            calls += 1
            progress?(DownloadProgressInfo(modelID: d.id, fraction: 0.5, bytesReceived: 1, bytesExpected: 2))
            try await Task.sleep(nanoseconds: delay)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for p in d.requiredPaths { try Data(p.utf8).write(to: folder.appendingPathComponent(p)) }
            try ModelManifest.build(modelID: d.id, hfRepo: d.hfRepo, folder: folder).save(to: folder)
        }
    }

    @Test func managerStatusDownloadAndDedup() async throws {
        let root = try tempDir()
        let fetcher = FakeFetcher(delay: 50_000_000)
        let m = ModelManager(root: root, fetchers: [.finalTDT: fetcher, .streamingEOU: fetcher, .whisper: fetcher], externalCaches: [:])
        #expect(await m.status(.parakeetTDTv3) == .missing)
        #expect(await m.bestFinalModelOnDisk() == nil)
        async let a = m.ensureAvailable(.parakeetTDTv3)
        async let b = m.ensureAvailable(.parakeetTDTv3)
        let (ua, ub) = try await (a, b)
        #expect(ua == ub && fetcher.calls == 1)
        #expect(await m.status(.parakeetTDTv3) == .present(await m.folder(for: .parakeetTDTv3)))
        #expect(await m.verify(.parakeetTDTv3).isEmpty)
        #expect(await m.bestFinalModelOnDisk() == .parakeetTDTv3)
        _ = try await m.ensureAvailable(.parakeetTDTv3)
        #expect(fetcher.calls == 1)   // already present: no re-download
        #expect(await m.isPresent(.parakeetTDTv3))
        #expect(await !m.isLoaded(.parakeetTDTv3))
    }

    @Test func managerFindsExternalCacheAndRefusesWhisperLoad() async throws {
        let root = try tempDir()
        let ext = try tempDir().appendingPathComponent("parakeet-tdt-ctc-110m-coreml")
        try FileManager.default.createDirectory(at: ext, withIntermediateDirectories: true)
        for p in ModelCatalog.descriptor(.parakeetTDTCTC110m).requiredPaths { try Data().write(to: ext.appendingPathComponent(p)) }
        let m = ModelManager(root: root, fetchers: [:], externalCaches: [.parakeetTDTCTC110m: [ext]])
        #expect(await m.locate(.parakeetTDTCTC110m) == ext)
        #expect(await m.bestFinalModelOnDisk() == .parakeetTDTCTC110m)
        await #expect(throws: ModelManagerError.unsupported(.whisperSmall)) { try await m.ensureAvailable(.whisperSmall) }
        await #expect(throws: ModelManagerError.notPresent(.parakeetEOU160)) { try await m.load(.parakeetEOU160) }
        #expect(await m.warmStart(preferred: [.parakeetEOU160]) == [])   // nothing present, no network, no throw
    }

    @Test func catalogAndPaths() {
        #expect(ModelCatalog.all.count == ModelID.allCases.count)
        #expect(ModelCatalog.modelsRoot().path.hasSuffix("VoicePlus/Models"))
        #expect(BundledModel.id == .parakeetTDTCTC110m)
        // Cold start only: with a better final model already on disk the tiny one is skipped
        // entirely. See `ModelLayoutTests.bestAvailableModelWinsFirstLaunch`.
        #expect(BundledModel.firstLaunchOrder(bestFinalOnDisk: nil).first == BundledModel.id)
        #expect(ModelCatalog.descriptor(.parakeetTDTv3).requiredPaths.contains("JointDecisionv3.mlmodelc"))
    }
}
