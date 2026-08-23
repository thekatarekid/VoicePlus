import Foundation

/// Sparkle wiring stub (T1). Packaging (P1.13) swaps in a real `SPUStandardUpdaterController`-backed
/// implementation; the app only ever talks to this protocol so there is no Sparkle dependency yet.
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
