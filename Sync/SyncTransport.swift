import Foundation

/// A dumb blob store: each device publishes one encrypted envelope under its device id. Zero backend —
/// an iCloud Drive / Dropbox / any synced folder is enough. Transport never sees plaintext.
public protocol SyncTransport: Sendable {
    func publish(envelope: Data, for deviceID: String) throws
    func fetchAll() throws -> [String: Data]   // deviceID → envelope
    func remove(deviceID: String) throws
}

public final class InMemorySyncTransport: SyncTransport, @unchecked Sendable {
    private let lock = NSLock(); private var blobs: [String: Data] = [:]
    public init() {}
    public func publish(envelope: Data, for deviceID: String) throws { lock.lock(); defer { lock.unlock() }; blobs[deviceID] = envelope }
    public func fetchAll() throws -> [String: Data] { lock.lock(); defer { lock.unlock() }; return blobs }
    public func remove(deviceID: String) throws { lock.lock(); defer { lock.unlock() }; blobs[deviceID] = nil }
}

/// `<folder>/<deviceID>.vpsync`. Writes are atomic so a partially-synced file never parses.
public struct DirectorySyncTransport: SyncTransport {
    public static let ext = "vpsync"
    public let directory: URL
    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    /// ~/Library/Mobile Documents/iCloud~in~adityakatare~voiceplus/Documents/Sync — nil if iCloud Drive is unavailable.
    public static func iCloudDrive(containerID: String = "iCloud~in~adityakatare~voiceplus") -> DirectorySyncTransport? {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents").appendingPathComponent(containerID)
        guard FileManager.default.fileExists(atPath: base.path) else { return nil }
        return try? DirectorySyncTransport(directory: base.appendingPathComponent("Documents/Sync"))
    }
    private func url(_ id: String) -> URL { directory.appendingPathComponent(id).appendingPathExtension(Self.ext) }
    public func publish(envelope: Data, for deviceID: String) throws { try envelope.write(to: url(deviceID), options: .atomic) }
    public func fetchAll() throws -> [String: Data] {
        var out: [String: Data] = [:]
        for f in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where f.pathExtension == Self.ext {
            out[f.deletingPathExtension().lastPathComponent] = try Data(contentsOf: f)
        }
        return out
    }
    public func remove(deviceID: String) throws {
        let u = url(deviceID)
        if FileManager.default.fileExists(atPath: u.path) { try FileManager.default.removeItem(at: u) }
    }
}
