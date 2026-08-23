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

    /// Directory of bundled/dev fixtures, resolved from the package root when running from source.
    public static func fixturesDirectory() -> URL? {
        // Walk up from this source file to the package root (works for `swift test` / `swift run`).
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        let candidate = url.appendingPathComponent("Fixtures", isDirectory: true)
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        // Packaged app: Fixtures copied next to the executable's Resources.
        if let resources = Bundle.main.resourceURL?.appendingPathComponent("Fixtures"),
           FileManager.default.fileExists(atPath: resources.path) {
            return resources
        }
        return nil
    }
}
