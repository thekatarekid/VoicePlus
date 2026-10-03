import AppKit
import Foundation
import GRDB

/// X6 — where a site's favicon comes from. `cachedFavicon` must be cheap (memory / disk only) because the
/// key-down path calls it; `fetchFavicon` may read the browser's store or the network.
public protocol FaviconSource: AnyObject {
    func cachedFavicon(host: String, browserBundleID: String?) -> NSImage?
    func fetchFavicon(host: String, browserBundleID: String?) async -> NSImage?
}

public extension FaviconSource {
    func fetchFavicon(host: String) async -> NSImage? { await fetchFavicon(host: host, browserBundleID: nil) }
}

/// Raw byte sources the pipeline chains (each mockable; tests never touch the network or real stores).
public protocol FaviconBytesSource {
    func faviconData(host: String, browserBundleID: String?) async -> Data?
}

/// X6 — the live chain: memory → disk cache → browser favicon store (read-only copy) → network
/// (`https://<host>/favicon.ico`, host only). Every hit from the store or network is written to the disk cache.
public final class FaviconPipeline: FaviconSource {
    private let store: FaviconBytesSource?
    private let network: FaviconBytesSource?
    private let cacheDirectory: URL?
    private let lock = NSLock()
    private var memory: [String: NSImage] = [:]
    private var misses: [String: Date] = [:]
    private let missTTL: TimeInterval
    private let now: () -> Date

    public init(store: FaviconBytesSource?, network: FaviconBytesSource?, cacheDirectory: URL?,
                missTTL: TimeInterval = 600, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.network = network
        self.cacheDirectory = cacheDirectory
        self.missTTL = missTTL
        self.now = now
    }

    public static func live() -> FaviconPipeline {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("VoicePlus/Favicons", isDirectory: true)
        return FaviconPipeline(store: ChromiumFaviconStore(), network: NetworkFaviconFetcher(), cacheDirectory: caches)
    }

    public func cachedFavicon(host: String, browserBundleID: String?) -> NSImage? {
        guard let key = Self.normalizedHost(host) else { return nil }
        lock.lock()
        if let hit = memory[key] { lock.unlock(); return hit }
        lock.unlock()
        guard let url = diskURL(key), let data = try? Data(contentsOf: url), let image = NSImage(data: data) else { return nil }
        remember(key, image)
        return image
    }

    public func fetchFavicon(host: String, browserBundleID: String?) async -> NSImage? {
        guard let key = Self.normalizedHost(host) else { return nil }
        if let hit = cachedFavicon(host: key, browserBundleID: browserBundleID) { return hit }
        lock.lock()
        let recentMiss = misses[key].map { now().timeIntervalSince($0) < missTTL } ?? false
        lock.unlock()
        if recentMiss { return nil }
        for source in [store, network].compactMap({ $0 }) {
            if let data = await source.faviconData(host: key, browserBundleID: browserBundleID),
               let image = NSImage(data: data), image.size.width > 0 {
                remember(key, image)
                writeDisk(key, data)
                return image
            }
        }
        lock.lock(); misses[key] = now(); lock.unlock()
        return nil
    }

    /// Host only, lower-cased, DNS characters only — nothing else ever reaches a path or a URL.
    public static func normalizedHost(_ host: String) -> String? {
        let h = host.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty, h.count <= 253, !h.hasPrefix("."), !h.contains(".."),
              h.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-").contains($0) })
        else { return nil }
        return h
    }

    private func remember(_ key: String, _ image: NSImage) {
        lock.lock(); memory[key] = image; misses[key] = nil; lock.unlock()
    }

    private func diskURL(_ key: String) -> URL? { cacheDirectory?.appendingPathComponent(key + ".ico") }

    private func writeDisk(_ key: String, _ data: Data) {
        guard let dir = cacheDirectory, let url = diskURL(key) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// X6 — Chromium-family browsers keep favicons in `<profile>/Default/Favicons` (SQLite). We copy it to a
/// temp file (the browser holds a lock) at most once a minute and query the copy read-only.
public final class ChromiumFaviconStore: FaviconBytesSource {
    private let supportDirectory: URL?
    private let lock = NSLock()
    private var copies: [String: (url: URL, at: Date)] = [:]

    public init(supportDirectory: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first) {
        self.supportDirectory = supportDirectory
    }

    public func faviconData(host: String, browserBundleID: String?) async -> Data? {
        guard let bundleID = browserBundleID, let profile = KnownBrowser.chromiumProfiles[bundleID],
              let source = supportDirectory?.appendingPathComponent(profile).appendingPathComponent("Default/Favicons"),
              FileManager.default.isReadableFile(atPath: source.path),
              let copy = readOnlyCopy(of: source, key: bundleID) else { return nil }
        return Self.query(databaseAt: copy, host: host)
    }

    /// Pure half (tests feed a fixture database).
    public static func query(databaseAt url: URL, host: String) -> Data? {
        var config = Configuration()
        config.readonly = true
        guard let db = try? DatabaseQueue(path: url.path, configuration: config) else { return nil }
        return try? db.read { db in
            try Data.fetchOne(db, sql: """
                SELECT fb.image_data FROM icon_mapping im
                JOIN favicon_bitmaps fb ON fb.icon_id = im.icon_id
                WHERE im.page_url LIKE ? OR im.page_url LIKE ?
                ORDER BY fb.width DESC LIMIT 1
                """, arguments: ["https://\(host)/%", "http://\(host)/%"])
        }
    }

    private func readOnlyCopy(of source: URL, key: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        if let c = copies[key], Date().timeIntervalSince(c.at) < 60 { return c.url }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("voiceplus-favicons-\(key).sqlite")
        try? FileManager.default.removeItem(at: dest)
        guard (try? FileManager.default.copyItem(at: source, to: dest)) != nil else { return nil }
        copies[key] = (dest, Date())
        return dest
    }
}

/// X6 — `GET https://<host>/favicon.ico`: host only (no path, no query, no cookies), ephemeral session,
/// 3 s timeout, at most 512 KB, image bodies only.
public final class NetworkFaviconFetcher: FaviconBytesSource {
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 5
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        session = URLSession(configuration: config)
    }

    public static func requestURL(host: String) -> URL? {
        guard let h = FaviconPipeline.normalizedHost(host) else { return nil }
        return URL(string: "https://\(h)/favicon.ico")
    }

    public func faviconData(host: String, browserBundleID: String?) async -> Data? {
        guard let url = Self.requestURL(host: host) else { return nil }
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              data.count > 0, data.count <= 512 * 1024 else { return nil }
        return data
    }
}
