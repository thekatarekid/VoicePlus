import Foundation

/// What the app talks to for updates. V5 J5: `AppcastUpdater` (reads the Sparkle-format feed
/// `Packaging/release.sh` publishes, no Sparkle dependency); `NoopUpdater` stays for tests and for
/// builds without a feed URL.
public protocol UpdaterProtocol: AnyObject {
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    var feedURL: URL? { get }
    func checkForUpdates()
}

public final class NoopUpdater: UpdaterProtocol {
    public var canCheckForUpdates: Bool { false }
    public var automaticallyChecksForUpdates: Bool = false
    public let feedURL: URL?
    public private(set) var checkCount = 0

    public init(feedURL: URL? = URL(string: "https://updates.adityakatare.in/voiceplus/appcast.xml")) {
        self.feedURL = feedURL
    }

    public func checkForUpdates() { checkCount += 1 }
}

/// V5 J5 — an updater whose release channel the user picks in Settings › Updates.
public protocol UpdateChannelSelecting: AnyObject {
    var channel: UpdateChannel { get set }
}
