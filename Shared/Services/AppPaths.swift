import Foundation

/// Filesystem locations. Everything lives under ~/Library/Application Support/VoicePlus.
public enum AppPaths {
    public static let appFolderName = "VoicePlus"

    public static func supportDirectory(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(appFolderName, isDirectory: true)
    }

    public static func databaseURL() -> URL {
        supportDirectory().appendingPathComponent("voiceplus.sqlite")
    }

    /// Directory of bundled/dev fixtures.
    ///
    /// The shipped bundle is tried *first*: the `#filePath`-relative source checkout below does not
    /// exist on a user's Mac, so looking there first meant every dev build exercised a lookup no
    /// user ever takes — the shipping path was only ever tested by shipping.
    public static func fixturesDirectory() -> URL? {
        // Packaged app: Fixtures copied next to the executable's Resources.
        if let resources = Bundle.main.resourceURL?.appendingPathComponent("Fixtures"),
           FileManager.default.fileExists(atPath: resources.path) {
            return resources
        }
        // Source checkout (`swift test` / `swift run`): walk up from this file to the package root.
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        let candidate = url.appendingPathComponent("Fixtures", isDirectory: true)
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        return nil
    }
}
