import CryptoKit
import Foundation
import Shared

// V5 J5 — the updater that replaces `NoopUpdater`. Reads the appcast (`Appcast.swift`), offers the
// newest build on the chosen channel, downloads only when the user asks ("Updates are downloaded
// only when you choose to"), verifies the DMG (length, SHA-256 from the feed, then the installer's
// bundle-id / build / codesign checks) and installs on "Install and restart" — which the Settings
// page gates behind `UpdateRestartGuard`. Every request asks the egress gate first (kill switch).

public protocol AppcastFetching: Sendable {
    func fetch(_ url: URL) async throws -> Data
}

public protocol UpdatePayloadDownloading: Sendable {
    /// Downloads `url` to a local file. `progress` gets a fraction when the size is known.
    func download(_ url: URL, expectedLength: Int64,
                  progress: @escaping @Sendable (Double?) -> Void) async throws -> URL
}

/// A verified, staged new app bundle, ready to swap in.
public struct PreparedUpdate: Equatable, Sendable {
    public var stagedApp: URL
    public var installedApp: URL
    public var build: String
    public var version: String
    public init(stagedApp: URL, installedApp: URL, build: String, version: String) {
        self.stagedApp = stagedApp
        self.installedApp = installedApp
        self.build = build
        self.version = version
    }
}

public protocol UpdateInstalling: AnyObject {
    /// Mounts / verifies / stages the DMG at `payload` for `offer`. Throws on any mismatch.
    func prepare(payload: URL, offer: UpdateOffer) async throws -> PreparedUpdate
    /// Hands the swap to a helper that waits for this process to exit, then quits the app.
    func installAndRelaunch(_ prepared: PreparedUpdate) throws
}

public enum UpdateFailure: Error, Equatable {
    case noFeed
    case egressBlocked(host: String)
    case feed(String)
    case integrity(String)
    case install(String)
}

public final class AppcastUpdater: UpdaterProtocol, UpdateStatusReporting, UpdateChannelSelecting,
                                   @unchecked Sendable {
    public static let automaticKey = "updates.automatic"
    public static let channelKey = "updates.channel"
    public static let lastCheckedKey = "updates.lastChecked"
    /// Automatic checks run at most this often.
    public static let checkInterval: TimeInterval = 24 * 60 * 60

    public let feedURL: URL?
    public let installedBuild: String
    public let systemVersion: String
    private let defaults: UserDefaults
    private let fetcher: AppcastFetching
    private let downloader: UpdatePayloadDownloading
    private let installer: UpdateInstalling
    private let egressAllowed: (String) -> Bool
    private let onEgress: ((_ host: String, _ bytesIn: Int, _ purpose: String) -> Void)?
    private let deliver: (@escaping () -> Void) -> Void
    private let now: () -> Date

    private let lock = NSLock()
    private var phase: UpdatePhase
    private var offer: UpdateOffer?
    private var prepared: PreparedUpdate?
    private var timer: Timer?
    public private(set) var lastFailure: UpdateFailure?

    public var onUpdatePhaseChange: ((UpdatePhase) -> Void)?

    public init(feedURL: URL?, installedBuild: String, systemVersion: String, defaults: UserDefaults,
                fetcher: AppcastFetching, downloader: UpdatePayloadDownloading, installer: UpdateInstalling,
                egressAllowed: @escaping (String) -> Bool,
                onEgress: ((_ host: String, _ bytesIn: Int, _ purpose: String) -> Void)? = nil,
                deliver: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
                now: @escaping () -> Date = Date.init) {
        self.feedURL = feedURL
        self.installedBuild = installedBuild
        self.systemVersion = systemVersion
        self.defaults = defaults
        self.fetcher = fetcher
        self.downloader = downloader
        self.installer = installer
        self.egressAllowed = egressAllowed
        self.onEgress = onEgress
        self.deliver = deliver
        self.now = now
        self.phase = .idle(lastChecked: defaults.object(forKey: Self.lastCheckedKey) as? Date)
    }

    // MARK: UpdaterProtocol

    public var canCheckForUpdates: Bool { feedURL != nil }

    /// On by default: a check only reads the feed; nothing downloads without the user.
    public var automaticallyChecksForUpdates: Bool {
        get { defaults.object(forKey: Self.automaticKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.automaticKey) }
    }

    public var channel: UpdateChannel {
        get { defaults.string(forKey: Self.channelKey).flatMap(UpdateChannel.init(rawValue:)) ?? .release }
        set {
            guard newValue != channel else { return }
            defaults.set(newValue.rawValue, forKey: Self.channelKey)
            // An offer from the other channel no longer applies; a staged install stays.
            lock.lock(); let staged = prepared != nil; if !staged { offer = nil }; lock.unlock()
            if !staged { setPhase(.idle(lastChecked: lastChecked)) }
        }
    }

    public var lastChecked: Date? { defaults.object(forKey: Self.lastCheckedKey) as? Date }

    public var updatePhase: UpdatePhase { lock.lock(); defer { lock.unlock() }; return phase }

    public var currentOffer: UpdateOffer? { lock.lock(); defer { lock.unlock() }; return offer }

    public func checkForUpdates() { Task { await self.performCheck() } }

    public func downloadUpdate() { Task { await self.performDownload() } }

    public func installAndRelaunch() {
        lock.lock(); let staged = prepared; lock.unlock()
        guard let staged else { return }
        do {
            try installer.installAndRelaunch(staged)
        } catch {
            fail(.install(String(describing: error)))
        }
    }

    // MARK: Automatic checks

    /// Due when automatic checks are on and the last one is older than `checkInterval`.
    public func isCheckDue(at date: Date) -> Bool {
        guard canCheckForUpdates, automaticallyChecksForUpdates else { return false }
        guard let last = lastChecked else { return true }
        return date.timeIntervalSince(last) >= Self.checkInterval
    }

    /// Launch: check if due, then re-evaluate hourly. Busy phases (download, staged) are left alone.
    public func startAutomaticChecks() {
        checkIfDue()
        let timer = Timer(timeInterval: 60 * 60, repeats: true) { [weak self] _ in self?.checkIfDue() }
        timer.tolerance = 10 * 60
        RunLoop.main.add(timer, forMode: .common)
        lock.lock(); self.timer?.invalidate(); self.timer = timer; lock.unlock()
    }

    public func stopAutomaticChecks() {
        lock.lock(); timer?.invalidate(); timer = nil; lock.unlock()
    }

    private func checkIfDue() {
        guard isCheckDue(at: now()) else { return }
        switch updatePhase {
        case .idle, .upToDate, .failed: checkForUpdates()
        default: break
        }
    }

    // MARK: Steps (async so tests can await them)

    @discardableResult
    public func performCheck() async -> UpdatePhase {
        switch updatePhase {
        case .checking, .downloading, .readyToInstall: return updatePhase
        default: break
        }
        guard let feedURL else { return fail(.noFeed) }
        setPhase(.checking)
        let host = feedURL.host ?? feedURL.absoluteString
        guard egressAllowed(host) else { return fail(.egressBlocked(host: host)) }
        let data: Data
        do {
            data = try await fetcher.fetch(feedURL)
        } catch {
            return fail(.feed(String(describing: error)))
        }
        onEgress?(host, data.count, "update check")
        let items: [AppcastItem]
        do { items = try AppcastParser.parse(data) } catch { return fail(.feed(String(describing: error))) }
        defaults.set(now(), forKey: Self.lastCheckedKey)
        let found = AppcastSelector.offer(in: items, installedBuild: installedBuild, channel: channel,
                                          systemVersion: systemVersion)
        withLock { offer = found; lastFailure = nil }
        if let found {
            Log.app.notice("update available: \(found.item.displayVersion) (\(found.kind.rawValue))")
            return setPhase(.available(version: found.item.displayVersion))
        }
        return setPhase(.upToDate)
    }

    @discardableResult
    public func performDownload() async -> UpdatePhase {
        guard let offer = currentOffer, case .available = updatePhase else { return updatePhase }
        let version = offer.item.displayVersion
        let url = offer.enclosure.url
        let host = url.host ?? url.absoluteString
        guard egressAllowed(host) else { return fail(.egressBlocked(host: host)) }
        setPhase(.downloading(version: version, fraction: nil))
        let file: URL
        do {
            file = try await downloader.download(url, expectedLength: offer.enclosure.length) { [weak self] fraction in
                self?.setPhase(.downloading(version: version, fraction: fraction.map { min(max($0, 0), 1) }))
            }
        } catch {
            return fail(.feed(String(describing: error)))
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        onEgress?(host, Int(size), "update download (\(offer.kind.rawValue))")
        if let problem = Self.integrityProblem(file: file, size: size, enclosure: offer.enclosure) {
            try? FileManager.default.removeItem(at: file)
            return fail(.integrity(problem))
        }
        do {
            let staged = try await installer.prepare(payload: file, offer: offer)
            withLock { prepared = staged }
            return setPhase(.readyToInstall(version: version))
        } catch {
            return fail(.install(String(describing: error)))
        }
    }

    /// Nil when the file matches the feed's length and SHA-256 (each checked only when given).
    public static func integrityProblem(file: URL, size: Int64, enclosure: AppcastEnclosure) -> String? {
        if enclosure.length > 0, size != enclosure.length {
            return "length \(size) != \(enclosure.length)"
        }
        if let expected = enclosure.sha256 {
            guard let actual = sha256Hex(of: file) else { return "unreadable download" }
            if actual != expected { return "sha256 mismatch" }
        }
        return nil
    }

    public static func sha256Hex(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Phase plumbing

    private func withLock<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    @discardableResult
    private func setPhase(_ next: UpdatePhase) -> UpdatePhase {
        lock.lock(); phase = next; lock.unlock()
        deliver { [weak self] in self?.onUpdatePhaseChange?(next) }
        return next
    }

    @discardableResult
    private func fail(_ failure: UpdateFailure) -> UpdatePhase {
        lock.lock(); lastFailure = failure; lock.unlock()
        Log.app.error("update failed: \(String(describing: failure))")
        return setPhase(.failed)
    }
}
