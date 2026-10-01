import CryptoKit
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

@Suite("V5 J5 — appcast updater")
struct AppcastUpdaterJ5Tests {
    // MARK: Fixtures

    static func feed(_ items: String) -> Data {
        Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel><title>VoicePlus</title><language>en</language>
        \(items)
          </channel>
        </rss>
        """.utf8)
    }

    static func item(build: String, version: String, channel: String? = nil, minOS: String = "15.0",
                     url: String? = nil, length: Int = 100, sha: String? = nil, deltas: String = "") -> String {
        let enclosureURL = url ?? "https://example.com/VoicePlus_\(version).dmg"
        return """
            <item>
              <title>VoicePlus \(version)</title>
              <sparkle:version>\(build)</sparkle:version>
              <sparkle:shortVersionString>\(version)</sparkle:shortVersionString>
              <sparkle:minimumSystemVersion>\(minOS)</sparkle:minimumSystemVersion>
              \(channel.map { "<sparkle:channel>\($0)</sparkle:channel>" } ?? "")
              <enclosure url="\(enclosureURL)" length="\(length)" \(sha.map { "sha256=\"\($0)\"" } ?? "") type="application/octet-stream" />
              \(deltas)
            </item>
        """
    }

    final class StubFetcher: AppcastFetching, @unchecked Sendable {
        var data: Data
        var calls = 0
        init(_ data: Data) { self.data = data }
        func fetch(_ url: URL) async throws -> Data { calls += 1; return data }
    }

    final class StubDownloader: UpdatePayloadDownloading, @unchecked Sendable {
        let bytes: Data
        var requested: [URL] = []
        init(bytes: Data) { self.bytes = bytes }
        func download(_ url: URL, expectedLength: Int64, progress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
            requested.append(url)
            progress(0.5)
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("j5-\(UUID().uuidString).dmg")
            try bytes.write(to: file)
            progress(1)
            return file
        }
    }

    final class StubInstaller: UpdateInstalling {
        var prepared: [UpdateOffer] = []
        var installed: [PreparedUpdate] = []
        var failPrepare = false
        func prepare(payload: URL, offer: UpdateOffer) async throws -> PreparedUpdate {
            if failPrepare { throw DMGUpdateInstaller.InstallError.signature }
            prepared.append(offer)
            return PreparedUpdate(stagedApp: URL(fileURLWithPath: "/tmp/new.app"),
                                  installedApp: URL(fileURLWithPath: "/Applications/VoicePlus.app"),
                                  build: offer.item.build, version: offer.item.displayVersion)
        }
        func installAndRelaunch(_ prepared: PreparedUpdate) throws { installed.append(prepared) }
    }

    static func defaults() -> UserDefaults {
        let name = "j5-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func updater(feed: Data, bytes: Data = Data(repeating: 7, count: 100), installed: String = "100",
                        egress: @escaping (String) -> Bool = { _ in true }, defaults: UserDefaults = defaults(),
                        installer: StubInstaller = StubInstaller(), downloader: StubDownloader? = nil,
                        feedURL: URL? = URL(string: "https://updates.example.com/appcast.xml"),
                        deliver: @escaping (@escaping () -> Void) -> Void = { $0() })
        -> (AppcastUpdater, StubInstaller, StubDownloader) {
        let dl = downloader ?? StubDownloader(bytes: bytes)
        let u = AppcastUpdater(feedURL: feedURL, installedBuild: installed, systemVersion: "15.2.0",
                               defaults: defaults, fetcher: StubFetcher(feed), downloader: dl, installer: installer,
                               egressAllowed: egress, deliver: deliver)
        return (u, installer, dl)
    }

    // MARK: Parsing

    @Test func parsesThePublishedAppcast() throws {
        let root = try #require(AppPaths.fixturesDirectory()).deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Packaging/appcast.xml"))
        let items = try AppcastParser.parse(data)
        #expect(items.count >= 3)
        let first = try #require(items.first)
        #expect(!first.build.isEmpty && !first.shortVersion.isEmpty)
        #expect(first.channel == "release")
        #expect(first.full?.url.scheme == "https")
        #expect((first.full?.length ?? 0) > 0)
    }

    @Test func parsesDeltasShaAndChannel() throws {
        let deltas = """
        <sparkle:deltas>
          <enclosure url="https://example.com/thin.dmg" sparkle:deltaFrom="100" length="20" sha256="ABCD" type="application/octet-stream" />
        </sparkle:deltas>
        """
        let items = try AppcastParser.parse(Self.feed(Self.item(build: "200", version: "2.0.0", channel: "beta",
                                                                 sha: "ff00", deltas: deltas)))
        let item = try #require(items.first)
        #expect(item.channel == "beta")
        #expect(item.full?.sha256 == "ff00")
        #expect(item.deltas.count == 1)
        #expect(item.deltas[0].deltaFrom == "100")
        #expect(item.deltas[0].sha256 == "abcd")
        #expect(item.deltas[0].length == 20)
    }

    @Test func malformedFeedThrows() {
        #expect(throws: AppcastParseError.self) { try AppcastParser.parse(Data("<rss><channel><item>".utf8)) }
    }

    // MARK: Ordering and selection

    @Test func buildVersionIsNumeric() {
        #expect(BuildVersion.isNewer("1.10.0", than: "1.9.9"))
        #expect(BuildVersion.isNewer("202609191856", than: "202609110439"))
        #expect(BuildVersion.compare("1.0", "1.0.0") == .orderedSame)
        #expect(!BuildVersion.isNewer("1.0.0", than: "1.0.0"))
    }

    @Test func selectsNewestEligibleOnChannel() throws {
        let items = try AppcastParser.parse(Self.feed(
            Self.item(build: "300", version: "3.0.0-nightly", channel: "beta")
            + Self.item(build: "250", version: "2.5.0", minOS: "99.0")
            + Self.item(build: "200", version: "2.0.0", channel: "release")
            + Self.item(build: "90", version: "0.9.0")))
        let release = try #require(AppcastSelector.offer(in: items, installedBuild: "100", channel: .release, systemVersion: "15.2"))
        #expect(release.item.build == "200")   // beta skipped, minOS 99 skipped
        #expect(release.kind == .full)
        let beta = try #require(AppcastSelector.offer(in: items, installedBuild: "100", channel: .beta, systemVersion: "15.2"))
        #expect(beta.item.build == "300")
        #expect(AppcastSelector.offer(in: items, installedBuild: "300", channel: .beta, systemVersion: "15.2") == nil)
    }

    @Test func deltaOnlyForTheInstalledBuild() throws {
        let deltas = """
        <sparkle:deltas>
          <enclosure url="https://example.com/thin-from-100.dmg" sparkle:deltaFrom="100" length="20" />
        </sparkle:deltas>
        """
        let items = try AppcastParser.parse(Self.feed(Self.item(build: "200", version: "2.0.0", deltas: deltas)))
        let fromMatch = try #require(AppcastSelector.offer(in: items, installedBuild: "100", channel: .release, systemVersion: "15.0"))
        #expect(fromMatch.kind == .delta)
        #expect(fromMatch.enclosure.url.lastPathComponent == "thin-from-100.dmg")
        let fromOther = try #require(AppcastSelector.offer(in: items, installedBuild: "150", channel: .release, systemVersion: "15.0"))
        #expect(fromOther.kind == .full)
    }

    @Test func insecureEnclosuresAreNeverOffered() throws {
        let items = try AppcastParser.parse(Self.feed(
            Self.item(build: "300", version: "3.0.0", url: "http://example.com/a.dmg")
            + Self.item(build: "200", version: "2.0.0")))
        let offer = try #require(AppcastSelector.offer(in: items, installedBuild: "100", channel: .release, systemVersion: "15.0"))
        #expect(offer.item.build == "200")
    }

    // MARK: Updater flow

    @Test func checkDownloadInstall() async throws {
        let bytes = Data(repeating: 7, count: 100)
        let feed = Self.feed(Self.item(build: "200", version: "2.0.0", length: 100, sha: Self.sha(bytes)))
        let (u, installer, _) = Self.updater(feed: feed, bytes: bytes)
        var seen: [UpdatePhase] = []
        u.onUpdatePhaseChange = { seen.append($0) }
        #expect(u.canCheckForUpdates)
        #expect(await u.performCheck() == .available(version: "2.0.0"))
        #expect(u.lastChecked != nil)
        #expect(await u.performDownload() == .readyToInstall(version: "2.0.0"))
        #expect(installer.prepared.map(\.item.build) == ["200"])
        #expect(seen.contains(.downloading(version: "2.0.0", fraction: 0.5)))
        #expect(seen.first == .checking)
        u.installAndRelaunch()
        #expect(installer.installed.map(\.build) == ["200"])
    }

    @Test func upToDateWhenNothingNewer() async {
        let (u, _, _) = Self.updater(feed: Self.feed(Self.item(build: "100", version: "1.0.0")))
        #expect(await u.performCheck() == .upToDate)
        #expect(u.currentOffer == nil)
    }

    @Test func killSwitchBlocksCheckAndDownload() async {
        var asked: [String] = []
        let (u, _, dl) = Self.updater(feed: Self.feed(Self.item(build: "200", version: "2.0.0")),
                                      egress: { asked.append($0); return false })
        #expect(await u.performCheck() == .failed)
        #expect(u.lastFailure == .egressBlocked(host: "updates.example.com"))
        #expect(asked == ["updates.example.com"])
        #expect(dl.requested.isEmpty)
    }

    @Test func downloadAsksTheGateForTheDMGHost() async {
        let (u, _, dl) = Self.updater(feed: Self.feed(Self.item(build: "200", version: "2.0.0")),
                                      egress: { $0 == "updates.example.com" })
        #expect(await u.performCheck() == .available(version: "2.0.0"))
        #expect(await u.performDownload() == .failed)
        #expect(u.lastFailure == .egressBlocked(host: "example.com"))
        #expect(dl.requested.isEmpty)
    }

    @Test func shaMismatchFailsAndNeverStages() async {
        let feed = Self.feed(Self.item(build: "200", version: "2.0.0", length: 100, sha: String(repeating: "0", count: 64)))
        let (u, installer, _) = Self.updater(feed: feed)
        _ = await u.performCheck()
        #expect(await u.performDownload() == .failed)
        #expect(u.lastFailure == .integrity("sha256 mismatch"))
        #expect(installer.prepared.isEmpty)
    }

    @Test func lengthMismatchFails() async {
        let (u, installer, _) = Self.updater(feed: Self.feed(Self.item(build: "200", version: "2.0.0", length: 999)))
        _ = await u.performCheck()
        #expect(await u.performDownload() == .failed)
        #expect(installer.prepared.isEmpty)
    }

    @Test func installerRejectionIsAFailure() async {
        let installer = StubInstaller()
        installer.failPrepare = true
        let (u, _, _) = Self.updater(feed: Self.feed(Self.item(build: "200", version: "2.0.0")), installer: installer)
        _ = await u.performCheck()
        #expect(await u.performDownload() == .failed)
        #expect(u.lastFailure == .install(String(describing: DMGUpdateInstaller.InstallError.signature)))
    }

    @Test func noDownloadWithoutAnOffer() async {
        let (u, installer, dl) = Self.updater(feed: Self.feed(""))
        #expect(await u.performDownload() == .idle(lastChecked: nil))
        u.installAndRelaunch()
        #expect(dl.requested.isEmpty && installer.installed.isEmpty)
    }

    @Test func channelPersistsAndDropsAStaleOffer() async {
        let d = Self.defaults()
        let feed = Self.feed(Self.item(build: "300", version: "3.0.0-nightly", channel: "beta"))
        let (u, _, _) = Self.updater(feed: feed, defaults: d)
        #expect(u.channel == .release)
        #expect(await u.performCheck() == .upToDate)
        u.channel = .beta
        #expect(d.string(forKey: AppcastUpdater.channelKey) == "beta")
        #expect(await u.performCheck() == .available(version: "3.0.0-nightly"))
        u.channel = .release
        #expect(u.currentOffer == nil)
        if case .idle = u.updatePhase {} else { Issue.record("expected idle, got \(u.updatePhase)") }
    }

    @Test func automaticChecksAreDailyAndOptOut() async {
        let d = Self.defaults()
        let (u, _, _) = Self.updater(feed: Self.feed(""), defaults: d)
        #expect(u.automaticallyChecksForUpdates)
        #expect(u.isCheckDue(at: Date()))
        _ = await u.performCheck()
        let last = try! #require(u.lastChecked)
        #expect(!u.isCheckDue(at: last.addingTimeInterval(60 * 60)))
        #expect(u.isCheckDue(at: last.addingTimeInterval(AppcastUpdater.checkInterval + 1)))
        u.automaticallyChecksForUpdates = false
        #expect(!u.isCheckDue(at: last.addingTimeInterval(AppcastUpdater.checkInterval + 1)))
    }

    @Test func noFeedMeansNoUpdater() async {
        let (u, _, _) = Self.updater(feed: Self.feed(""), feedURL: nil)
        #expect(!u.canCheckForUpdates)
        #expect(!u.isCheckDue(at: Date()))
        #expect(await u.performCheck() == .failed)
        #expect(u.lastFailure == .noFeed)
    }

    @Test func feedURLComesFromInfoPlistAndIsHttpsOnly() {
        // The test runner's bundle is not an .app and has no SUFeedURL: no updater.
        #expect(AppcastUpdater.feedURL(bundle: Bundle(for: StubInstaller.self)) == nil)
        #expect(AppcastSelector.isSecure(AppcastUpdater.defaultFeedURL))
    }

    // MARK: Settings › Updates

    @MainActor @Test func settingsShowsAndWritesTheChannel() {
        let (u, _, _) = Self.updater(feed: Self.feed(""))
        let page = UpdatesPageModel(updater: u, version: "1.0.0", captureActive: { false }, heldDrafts: { 0 },
                                    draftsPersisted: { true })
        #expect(page.canUpdate && page.hasChannels)
        #expect(page.channel == .release)
        page.channel = .beta
        #expect(u.channel == .beta)
        let noop = UpdatesPageModel(updater: NoopUpdater(), version: "1.0.0", captureActive: { false },
                                    heldDrafts: { 0 }, draftsPersisted: { true })
        #expect(!noop.hasChannels)
    }

    @MainActor @Test func settingsCheckNowDrivesThePhase() async {
        let (u, _, _) = Self.updater(feed: Self.feed(Self.item(build: "200", version: "2.0.0")),
                                     deliver: { DispatchQueue.main.async(execute: $0) })
        let page = UpdatesPageModel(updater: u, version: "1.0.0", captureActive: { false }, heldDrafts: { 0 },
                                    draftsPersisted: { true })
        _ = await u.performCheck()
        for _ in 0..<200 where page.phase != .available(version: "2.0.0") { try? await Task.sleep(nanoseconds: 5_000_000) }
        #expect(page.phase == .available(version: "2.0.0"))
        #expect(page.statusLine == UpdatesCopy.available("2.0.0"))
    }

    // MARK: Install pieces

    @Test func swapScriptQuotesPathsAndRestoresOnFailure() {
        let prepared = PreparedUpdate(stagedApp: URL(fileURLWithPath: "/Apps/.VoicePlus-update-2.app"),
                                      installedApp: URL(fileURLWithPath: "/Apps/Voice'Plus.app"), build: "2", version: "2")
        let script = DMGUpdateInstaller.swapScript(pid: 42, prepared: prepared)
        #expect(script.contains("kill -0 42"))
        #expect(script.contains("'/Apps/Voice'\\''Plus.app'"))
        #expect(script.contains("mv '/Apps/.VoicePlus-update-2.app' '/Apps/Voice'\\''Plus.app'"))
        #expect(script.contains("|| mv '/Apps/.Voice'\\''Plus-previous.app' '/Apps/Voice'\\''Plus.app'"))
        #expect(script.contains("open '/Apps/Voice'\\''Plus.app'"))
    }

    @Test func modelCarryOverCopiesOnlyWhatTheThinBundleLacks() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("j5-carry-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let old = root.appendingPathComponent("old/Models"), new = root.appendingPathComponent("new/Models")
        let support = root.appendingPathComponent("support/Models")
        for dir in [old.appendingPathComponent("asr"), old.appendingPathComponent("vad"), old.appendingPathComponent("eou"),
                    new.appendingPathComponent("vad"), support.appendingPathComponent("eou")] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("w".utf8).write(to: dir.appendingPathComponent("weights.bin"))
        }
        let copied = try ModelCarryOver.carry(from: old, newBundleModels: new, into: support)
        #expect(copied == ["asr"])   // vad ships in the thin bundle; eou already in support
        #expect(fm.fileExists(atPath: support.appendingPathComponent("asr/weights.bin").path))
        #expect(try ModelCarryOver.carry(from: old, newBundleModels: new, into: support).isEmpty)
    }

    @Test func integrityCheckHashesTheFile() throws {
        let bytes = Data("voiceplus".utf8)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("j5-\(UUID().uuidString)")
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let good = AppcastEnclosure(url: URL(string: "https://e.com/a.dmg")!, length: Int64(bytes.count),
                                    sha256: Self.sha(bytes), edSignature: nil, deltaFrom: nil)
        #expect(AppcastUpdater.integrityProblem(file: file, size: Int64(bytes.count), enclosure: good) == nil)
        var unknown = good
        unknown.length = 0
        unknown.sha256 = nil
        #expect(AppcastUpdater.integrityProblem(file: file, size: 1, enclosure: unknown) == nil)
    }
}
