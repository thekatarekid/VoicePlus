import AppKit
import Foundation
import GRDB
import Testing
@testable import VoicePlusApp

private func png() -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    return rep.representation(using: .png, properties: [:])!
}

private final class MockBytes: FaviconBytesSource {
    var data: Data?
    var calls: [String] = []
    init(_ data: Data?) { self.data = data }
    func faviconData(host: String, browserBundleID: String?) async -> Data? { calls.append(host); return data }
}

private final class MockFavicons: FaviconSource {
    var cached: [String: NSImage] = [:]
    var fetched: NSImage?
    var fetchCalls = 0
    func cachedFavicon(host: String, browserBundleID: String?) -> NSImage? { cached[host] }
    func fetchFavicon(host: String, browserBundleID: String?) async -> NSImage? { fetchCalls += 1; return fetched }
}

private func tempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("x6-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

@Suite("X6 destination identity")
struct DestinationIdentityTests {
    let appIcon = NSImage(size: NSSize(width: 16, height: 16))

    private func resolver(bundle: String, name: String, title: String?, url: String?,
                          favicons: FaviconSource = MockFavicons()) -> DestinationIdentityResolver {
        let icon = appIcon
        return DestinationIdentityResolver(
            appLookup: { _ in DestinationAppInfo(name: name, bundleID: bundle, icon: icon) },
            windowLookup: { _ in DestinationWindowInfo(title: title, url: url.flatMap(URL.init(string:))) },
            favicons: favicons, ownBundleID: "com.voiceplus.app")
    }

    @Test func nativeAppIsIconAndName() {
        let id = resolver(bundle: "com.apple.mail", name: "Mail", title: "Inbox", url: nil).resolve(pid: 1, axWindow: nil)
        #expect(id?.appName == "Mail")
        #expect(id?.appIcon != nil)
        #expect(id?.isBrowser == false)
        #expect(id?.tabTitle == nil)
        #expect(id?.label == "Mail")
    }

    @Test func electronAppIsTreatedAsApp() {
        let id = resolver(bundle: "com.tinyspeck.slackmacgap", name: "Slack", title: "general", url: nil).resolve(pid: 1, axWindow: nil)
        #expect(id?.isBrowser == false)
        #expect(id?.label == "Slack")
    }

    @Test func ownAppResolvesToNil() {
        #expect(resolver(bundle: "com.voiceplus.app", name: "VoicePlus", title: nil, url: nil).resolve(pid: 1, axWindow: nil) == nil)
    }

    @Test func browserHasTabTitleHostAndCachedFavicon() {
        let fav = MockFavicons()
        fav.cached["claude.ai"] = NSImage(size: NSSize(width: 32, height: 32))
        let id = resolver(bundle: "com.google.Chrome", name: "Google Chrome", title: "New chat - Claude - Google Chrome",
                          url: "https://claude.ai/new?x=secret", favicons: fav).resolve(pid: 1, axWindow: nil)
        #expect(id?.isBrowser == true)
        #expect(id?.appName == "Google Chrome")
        #expect(id?.tabTitle == "New chat - Claude")
        #expect(id?.siteHost == "claude.ai")
        #expect(id?.siteFavicon != nil)
        #expect(id?.label == "New chat - Claude")
    }

    @Test func tabTitleNeverTheURL() {
        #expect(DestinationIdentityResolver.tabTitle("https://claude.ai/new", browserName: "Safari", host: "claude.ai") == nil)
        #expect(DestinationIdentityResolver.tabTitle("claude.ai", browserName: "Safari", host: "claude.ai") == nil)
        #expect(DestinationIdentityResolver.tabTitle("example.com/path/x", browserName: "Safari", host: nil) == nil)
        #expect(DestinationIdentityResolver.tabTitle("Safari", browserName: "Safari", host: nil) == nil)
        #expect(DestinationIdentityResolver.tabTitle("Docs — Safari", browserName: "Safari", host: nil) == "Docs")
    }

    @Test func hostOnlyForWebSchemes() {
        #expect(DestinationIdentityResolver.host(of: URL(string: "file:///tmp/a.html")) == nil)
        #expect(DestinationIdentityResolver.host(of: URL(string: "about:blank")) == nil)
        #expect(DestinationIdentityResolver.host(of: URL(string: "HTTPS://Mail.Google.com/u/0")) == "mail.google.com")
    }

    @Test func resolveFaviconFetchesWhenNotCached() async {
        let fav = MockFavicons()
        fav.fetched = NSImage(size: NSSize(width: 16, height: 16))
        let r = resolver(bundle: "com.apple.Safari", name: "Safari", title: "Home", url: "https://example.com/", favicons: fav)
        let id = r.resolve(pid: 1, axWindow: nil)!
        #expect(id.siteFavicon == nil)
        let done = await r.resolveFavicon(for: id)
        #expect(done.siteFavicon != nil)
        #expect(fav.fetchCalls == 1)
        // An app identity never fetches.
        let app = resolver(bundle: "com.apple.mail", name: "Mail", title: nil, url: nil, favicons: fav).resolve(pid: 1, axWindow: nil)!
        _ = await r.resolveFavicon(for: app)
        #expect(fav.fetchCalls == 1)
    }

    @Test func pipelineStoreFirstThenNetworkThenDiskCache() async {
        let dir = tempDir()
        let store = MockBytes(nil), net = MockBytes(png())
        let p = FaviconPipeline(store: store, network: net, cacheDirectory: dir)
        #expect(p.cachedFavicon(host: "example.com", browserBundleID: nil) == nil)
        #expect(await p.fetchFavicon(host: "example.com", browserBundleID: "com.google.Chrome") != nil)
        #expect(store.calls == ["example.com"])
        #expect(net.calls == ["example.com"])
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("example.com.ico").path))
        // A fresh pipeline reads the disk cache without any source.
        let cold = FaviconPipeline(store: nil, network: nil, cacheDirectory: dir)
        #expect(cold.cachedFavicon(host: "EXAMPLE.com", browserBundleID: nil) != nil)
    }

    @Test func storeHitSkipsNetwork() async {
        let store = MockBytes(png()), net = MockBytes(png())
        let p = FaviconPipeline(store: store, network: net, cacheDirectory: tempDir())
        #expect(await p.fetchFavicon(host: "a.com", browserBundleID: "com.google.Chrome") != nil)
        #expect(net.calls.isEmpty)
    }

    @Test func missIsRememberedForTTL() async {
        let net = MockBytes(nil)
        var t = Date(timeIntervalSince1970: 0)
        let p = FaviconPipeline(store: nil, network: net, cacheDirectory: nil, missTTL: 600, now: { t })
        _ = await p.fetchFavicon(host: "a.com", browserBundleID: nil)
        _ = await p.fetchFavicon(host: "a.com", browserBundleID: nil)
        #expect(net.calls.count == 1)
        t = t.addingTimeInterval(601)
        _ = await p.fetchFavicon(host: "a.com", browserBundleID: nil)
        #expect(net.calls.count == 2)
    }

    @Test func networkURLIsHostOnly() {
        #expect(NetworkFaviconFetcher.requestURL(host: "Claude.AI")?.absoluteString == "https://claude.ai/favicon.ico")
        #expect(NetworkFaviconFetcher.requestURL(host: "evil.com/x?y") == nil)
        #expect(NetworkFaviconFetcher.requestURL(host: "a.com@b.com") == nil)
        #expect(NetworkFaviconFetcher.requestURL(host: "") == nil)
    }

    @Test func chromiumStoreQueryReadsLargestBitmapForHost() throws {
        let url = tempDir().appendingPathComponent("Favicons")
        let q = try DatabaseQueue(path: url.path)
        let small = Data([1]), big = Data([2, 2])
        try q.write { db in
            try db.execute(sql: "CREATE TABLE icon_mapping (page_url TEXT, icon_id INTEGER)")
            try db.execute(sql: "CREATE TABLE favicon_bitmaps (icon_id INTEGER, width INTEGER, image_data BLOB)")
            try db.execute(sql: "INSERT INTO icon_mapping VALUES ('https://claude.ai/new', 1), ('https://other.com/', 2)")
            try db.execute(sql: "INSERT INTO favicon_bitmaps VALUES (1, 16, ?), (1, 32, ?), (2, 64, ?)", arguments: [small, big, Data([9])])
        }
        #expect(ChromiumFaviconStore.query(databaseAt: url, host: "claude.ai") == big)
        #expect(ChromiumFaviconStore.query(databaseAt: url, host: "none.com") == nil)
    }
}
