import Foundation
import Shared

// V5 J5 — the real network and install pieces behind `AppcastUpdater`. Kept apart so the updater's
// logic is tested against protocols; what is here needs a published feed, a real DMG and a real
// relaunch, and is listed in T1 (needs hardware/owner).

/// Ephemeral session: no cookies, no cache, no credentials — the check carries nothing about the user.
public struct URLSessionAppcastFetcher: AppcastFetching {
    public init() {}

    public func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpShouldHandleCookies = false
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateFailure.feed("HTTP \(http.statusCode)")
        }
        return data
    }
}

/// Downloads into `~/Library/Caches/VoicePlus/Updates` with real progress.
public final class URLSessionPayloadDownloader: NSObject, UpdatePayloadDownloading, URLSessionDownloadDelegate,
                                                @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    private var pending: [Int: (continuation: CheckedContinuation<URL, Error>,
                                progress: @Sendable (Double?) -> Void, expected: Int64, name: String)] = [:]
    private lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoicePlus/Updates", isDirectory: true)
    }

    public func download(_ url: URL, expectedLength: Int64,
                         progress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try await withCheckedThrowingContinuation { continuation in
            let task = session.downloadTask(with: url)
            lock.lock()
            pending[task.taskIdentifier] = (continuation, progress, expectedLength, url.lastPathComponent)
            lock.unlock()
            task.resume()
        }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                           totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        lock.lock(); let entry = pending[downloadTask.taskIdentifier]; lock.unlock()
        guard let entry else { return }
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : entry.expected
        entry.progress(total > 0 ? Double(totalBytesWritten) / Double(total) : nil)
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        lock.lock(); let entry = pending.removeValue(forKey: downloadTask.taskIdentifier); lock.unlock()
        guard let entry else { return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            entry.continuation.resume(throwing: UpdateFailure.feed("HTTP \(http.statusCode)"))
            return
        }
        let name = entry.name.isEmpty ? "VoicePlus-update.dmg" : entry.name
        let destination = directory.appendingPathComponent(name)
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            entry.continuation.resume(returning: destination)
        } catch {
            entry.continuation.resume(throwing: error)
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        lock.lock(); let entry = pending.removeValue(forKey: task.taskIdentifier); lock.unlock()
        entry?.continuation.resume(throwing: error)
    }
}

/// Mounts the DMG read-only, checks the app inside (bundle id, advertised build, codesign), stages a
/// copy next to the installed bundle (same volume, so the swap is a rename), carries bundled models
/// out of the installed app when the new one is thin (delta), and on install hands the swap to a
/// detached shell that waits for this process to exit, swaps, and reopens the app.
public final class DMGUpdateInstaller: UpdateInstalling {
    public enum InstallError: Error, Equatable {
        case command(String)
        case noAppInImage
        case wrongBundle(String)
        case wrongBuild(expected: String, found: String)
        case signature
        case notWritable(String)
    }

    private let installedApp: URL
    private let bundleIdentifier: String
    private let modelsRoot: URL
    private let terminate: () -> Void

    public init(installedApp: URL = Bundle.main.bundleURL,
                bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "in.adityakatare.voiceplus",
                modelsRoot: URL, terminate: @escaping () -> Void) {
        self.installedApp = installedApp
        self.bundleIdentifier = bundleIdentifier
        self.modelsRoot = modelsRoot
        self.terminate = terminate
    }

    public func prepare(payload: URL, offer: UpdateOffer) async throws -> PreparedUpdate {
        let parent = installedApp.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else { throw InstallError.notWritable(parent.path) }
        let mount = FileManager.default.temporaryDirectory.appendingPathComponent("VoicePlusUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try Self.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, payload.path])
        defer {
            _ = try? Self.run("/usr/bin/hdiutil", ["detach", "-force", mount.path])
            try? FileManager.default.removeItem(at: mount)
        }
        let contents = try FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)
        guard let app = contents.first(where: { $0.pathExtension == "app" }) else { throw InstallError.noAppInImage }
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any] ?? [:]
        let id = info["CFBundleIdentifier"] as? String ?? ""
        guard id == bundleIdentifier else { throw InstallError.wrongBundle(id) }
        let build = info["CFBundleVersion"] as? String ?? ""
        guard build == offer.item.build else { throw InstallError.wrongBuild(expected: offer.item.build, found: build) }
        do { try Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) } catch { throw InstallError.signature }

        let staged = parent.appendingPathComponent(".\(installedApp.deletingPathExtension().lastPathComponent)-update-\(build).app")
        try? FileManager.default.removeItem(at: staged)
        try Self.run("/usr/bin/ditto", [app.path, staged.path])
        // Delta (thin) bundle: the models the installed full bundle carried must survive the swap.
        _ = try? ModelCarryOver.carry(from: installedApp.appendingPathComponent("Contents/Resources/Models"),
                                      newBundleModels: staged.appendingPathComponent("Contents/Resources/Models"),
                                      into: modelsRoot)
        return PreparedUpdate(stagedApp: staged, installedApp: installedApp, build: build, version: offer.item.displayVersion)
    }

    public func installAndRelaunch(_ prepared: PreparedUpdate) throws {
        let script = Self.swapScript(pid: ProcessInfo.processInfo.processIdentifier, prepared: prepared)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try process.run()
        terminate()
    }

    /// The detached helper: wait for `pid` to exit, move the old bundle aside, move the staged one
    /// in, restore the old one if that fails, reopen, then drop the old copy.
    public static func swapScript(pid: Int32, prepared: PreparedUpdate) -> String {
        let old = shellQuote(prepared.installedApp.path)
        let new = shellQuote(prepared.stagedApp.path)
        let backup = shellQuote(prepared.installedApp.deletingLastPathComponent()
            .appendingPathComponent(".\(prepared.installedApp.deletingPathExtension().lastPathComponent)-previous.app").path)
        return """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        rm -rf \(backup)
        if mv \(old) \(backup) && mv \(new) \(old); then rm -rf \(backup); else [ -d \(old) ] || mv \(backup) \(old); fi
        open \(old)
        """
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw InstallError.command("\((tool as NSString).lastPathComponent) \(process.terminationStatus): \(text.prefix(200))")
        }
        return text
    }
}

/// A thin (delta) bundle ships without the default models; the full bundle being replaced has them
/// as read-only candidates (`BundledModelResources`). Before the swap, copy any model folder the new
/// bundle lacks into Application Support (the maintenance root) unless it is already there.
public enum ModelCarryOver {
    /// Folder names copied.
    @discardableResult
    public static func carry(from oldBundleModels: URL, newBundleModels: URL, into modelsRoot: URL,
                             fileManager: FileManager = .default) throws -> [String] {
        guard let folders = try? fileManager.contentsOfDirectory(atPath: oldBundleModels.path) else { return [] }
        var copied: [String] = []
        for name in folders.sorted() where !name.hasPrefix(".") {
            let source = oldBundleModels.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: source.path, isDirectory: &isDir), isDir.boolValue else { continue }
            if fileManager.fileExists(atPath: newBundleModels.appendingPathComponent(name).path) { continue }
            let target = modelsRoot.appendingPathComponent(name)
            if fileManager.fileExists(atPath: target.path) { continue }
            try fileManager.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
            try fileManager.copyItem(at: source, to: target)
            copied.append(name)
        }
        return copied
    }
}

public extension AppcastUpdater {
    /// The feed: `SUFeedURL` from Info.plist (Packaging/Info.plist.template), else the default.
    static let defaultFeedURL = URL(string: "https://updates.adityakatare.in/voiceplus/appcast.xml")!

    static func feedURL(bundle: Bundle = .main) -> URL? {
        if let raw = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String, let url = URL(string: raw),
           AppcastSelector.isSecure(url) {
            return url
        }
        // A `swift run` binary has no Info.plist and no bundle to replace: no updater.
        return bundle.bundleURL.pathExtension == "app" ? defaultFeedURL : nil
    }

    /// The composition root's updater.
    static func live(egressAllowed: @escaping (String) -> Bool,
                     onEgress: ((String, Int, String) -> Void)?,
                     modelsRoot: URL, terminate: @escaping () -> Void,
                     bundle: Bundle = .main, defaults: UserDefaults = .standard) -> AppcastUpdater {
        AppcastUpdater(feedURL: feedURL(bundle: bundle),
                       installedBuild: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
                       systemVersion: BuildVersion.string(ProcessInfo.processInfo.operatingSystemVersion),
                       defaults: defaults, fetcher: URLSessionAppcastFetcher(),
                       downloader: URLSessionPayloadDownloader(),
                       installer: DMGUpdateInstaller(installedApp: bundle.bundleURL,
                                                     bundleIdentifier: bundle.bundleIdentifier ?? "in.adityakatare.voiceplus",
                                                     modelsRoot: modelsRoot, terminate: terminate),
                       egressAllowed: egressAllowed, onEgress: onEgress)
    }
}
