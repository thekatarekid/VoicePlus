import Foundation

/// N9 / F26 — the shell behind the focused terminal surface, as plain data.
///
/// Filled by the app (L5: the terminal app's child shell on the focused tab's tty, its current
/// folder and a listing of that one folder) and read by the resolver (pty ownership is
/// medium-high terminal evidence), the command-line grammar (N12: is the first word a real
/// command?) and the path matcher (N13: "documents" → `Documents/`). Nothing here is read from
/// the screen and nothing is persisted.
public struct ShellContext: Sendable, Equatable, Codable {
    /// One entry of the current folder (not recursive).
    public struct Entry: Sendable, Equatable, Hashable, Codable {
        public var name: String
        public var isDirectory: Bool
        public init(name: String, isDirectory: Bool) { self.name = name; self.isDirectory = isDirectory }
        /// `Documents/` for a folder, `notes.txt` for a file.
        public var displayName: String { isDirectory ? name + "/" : name }
    }

    /// The shell process (`zsh`, `bash`, `fish`…), when known.
    public var pid: Int32?
    public var shellName: String?
    /// The tty device of the focused tab (`/dev/ttys004`), when known.
    public var tty: String?
    /// Absolute current folder of the shell; `nil` when it could not be read.
    public var currentDirectory: String?
    /// The current folder's entries. Empty when the listing was not permitted (Settings →
    /// "Use folder names in Terminal" is off, or macOS refused).
    public var entries: [Entry]
    /// Commands this shell can run: `$PATH` executables, builtins, aliases, and what the user
    /// has actually run. The command-line grammar matches the first word against this set,
    /// not a hardcoded `cd`/`ls` list.
    public var knownCommands: Set<String>

    public init(pid: Int32? = nil, shellName: String? = nil, tty: String? = nil,
                currentDirectory: String? = nil, entries: [Entry] = [], knownCommands: Set<String> = []) {
        self.pid = pid; self.shellName = shellName; self.tty = tty
        self.currentDirectory = currentDirectory; self.entries = entries; self.knownCommands = knownCommands
    }

    /// Builtins every POSIX-ish shell has. A floor for `knownCommands`, not a decision table:
    /// the grammar validates against the union with the user's real commands.
    public static let shellBuiltins: Set<String> = [
        "cd", "pwd", "echo", "export", "alias", "unalias", "source", "exit", "history", "type",
        "which", "set", "unset", "pushd", "popd", "jobs", "fg", "bg", "kill", "exec", "eval",
        "test", "read", "true", "false", "umask", "wait", "command", "builtin",
    ]

    /// `knownCommands` plus the builtins.
    public var allCommands: Set<String> { knownCommands.union(Self.shellBuiltins) }

    public var directories: [Entry] { entries.filter(\.isDirectory) }
}
