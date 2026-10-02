import Foundation

/// N13 / F26 — "Use folder names in Terminal". Off by default. Listing Documents, Desktop or
/// Downloads triggers a macOS privacy prompt, so the prompt is raised once, from Settings, when the
/// user turns this on — never during a dictation. Keys live here and are read through the
/// `SettingsStore` protocol.
public enum ShellFolderSettings {
    public static let enabledKey = "shell.folderNames.enabled"
    /// Set once the Settings toggle has made the one-time protected-folder listing (the prompt).
    public static let promptedKey = "shell.folderNames.prompted"

    public static let title = "Use folder names in Terminal"
    public static let detail = "Reads the name of the folder your shell is in and the names inside it (not their contents, not subfolders) so \"cd documents\" becomes cd Documents/. macOS may ask once for Documents, Desktop and Downloads. Nothing leaves this Mac."

    public static func isEnabled(_ store: SettingsStore?) -> Bool {
        store?.bool(enabledKey) ?? false
    }

    public static func wasPrompted(_ store: SettingsStore?) -> Bool {
        store?.bool(promptedKey) ?? false
    }

    /// Settings toggle. Turning it on makes the one-time protected-folder touch (`promptOnce`,
    /// which lists each folder's names and discards them) so macOS asks here, not mid-dictation.
    public static func setEnabled(_ on: Bool, store: SettingsStore?,
                                  promptOnce: () -> Void = ShellFolderSettings.touchProtectedFolders) {
        store?.set(on, for: enabledKey)
        guard on, !wasPrompted(store) else { return }
        promptOnce()
        store?.set(true, for: promptedKey)
    }

    /// The macOS-protected folders whose listing raises a privacy prompt.
    public static func protectedFolders(home: String = NSHomeDirectory()) -> [String] {
        ["Documents", "Desktop", "Downloads"].map { (home as NSString).appendingPathComponent($0) }
    }

    /// Lists (names only, result discarded) each protected folder, which is what makes macOS ask.
    public static func touchProtectedFolders() {
        for path in protectedFolders() { _ = try? FileManager.default.contentsOfDirectory(atPath: path) }
    }
}
