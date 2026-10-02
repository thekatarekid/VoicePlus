import Foundation
import Shared

/// N12 — the command-line grammar's data. Data, not decisions: the grammar asks "is this word a
/// command this shell can run?" and answers it from `ShellContext.knownCommands` (the user's
/// real `$PATH`, builtins, aliases and history) whenever the app supplied one. `common` is only
/// the stand-in when no shell context is available (the Lab, a replay, a terminal whose shell
/// could not be read).
public enum CommandLexicon {
    /// Stand-in command set when the shell is unknown.
    public static let common: Set<String> = [
        "ls", "cat", "rm", "cp", "mv", "mkdir", "rmdir", "touch", "chmod", "chown", "grep", "rg", "find", "open",
        "code", "cursor", "vim", "nvim", "vi", "nano", "kill", "ps", "top", "tar", "zip", "unzip", "curl", "wget",
        "ssh", "scp", "rsync", "sudo", "python", "python3", "node", "ruby", "go", "cargo", "swift", "make", "brew",
        "pip", "pip3", "npm", "npx", "yarn", "pnpm", "bun", "deno", "docker", "kubectl", "git", "gh", "less", "more",
        "head", "tail", "man", "ln", "df", "du", "env", "xargs", "sort", "uniq", "wc", "sed", "awk", "cut", "tr",
        "diff", "say", "xcodebuild", "xcrun", "defaults", "launchctl", "claude", "codex", "tmux", "clear", "time",
        "nohup", "ping", "dig", "jq", "uv", "pytest", "terraform", "ffmpeg", "date", "whoami", "printf", "tree",
    ]

    /// Commands whose next word is a sub-command ("git add", "npm install"). A sub-command is
    /// still in command position, so a following "dot" is an argument (`git add .`).
    public static let subcommands: [String: Set<String>] = [
        "git": ["add", "commit", "push", "pull", "checkout", "branch", "merge", "rebase", "status", "diff", "log",
                "stash", "clone", "fetch", "reset", "restore", "switch", "tag", "init", "show", "rm", "mv", "remote"],
        "npm": ["install", "i", "run", "test", "start", "build", "init", "ci", "exec", "add", "publish", "uninstall"],
        "yarn": ["add", "install", "run", "test", "start", "build", "init", "remove"],
        "pnpm": ["add", "install", "run", "test", "start", "build", "init", "exec"],
        "bun": ["add", "install", "run", "test", "build", "init"],
        "cargo": ["build", "run", "test", "add", "install", "check", "init", "new"],
        "swift": ["build", "run", "test", "package"],
        "brew": ["install", "uninstall", "upgrade", "update", "list", "info", "search"],
        "docker": ["run", "build", "exec", "ps", "pull", "push", "compose", "images", "stop", "rm"],
        "pip": ["install", "uninstall", "show", "list"], "pip3": ["install", "uninstall", "show", "list"],
        "make": ["install", "test", "build", "clean", "all"],
        "gh": ["pr", "issue", "repo", "run"], "kubectl": ["get", "apply", "describe", "logs", "delete"],
        "go": ["build", "run", "test", "get", "mod"],
    ]

    /// Commands that run the next word as a command (`sudo rm`, `xargs grep`).
    public static let wrappers: Set<String> = ["sudo", "env", "xargs", "time", "nohup", "exec", "command", "builtin", "watch"]

    /// The commands the grammar validates against: the shell's real ones when known, else the
    /// stand-in plus the POSIX builtins.
    public static func commands(for shell: ShellContext?) -> Set<String> {
        if let shell, !shell.knownCommands.isEmpty { return shell.allCommands }
        return common.union(ShellContext.shellBuiltins)
    }
}

/// N12 — the shell context travels to the formatter inside `StageContext.extra` as JSON (the
/// stage context carries only strings). Written by `App` (L5's shell probe), read by
/// `TerminalFormatter` and the path matcher.
public extension ShellContext {
    static let stageKey = "shell.context"

    init?(stageContext: StageContext) {
        guard let raw = stageContext.extra[Self.stageKey], let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ShellContext.self, from: data) else { return nil }
        self = decoded
    }

    func write(into stageContext: inout StageContext) {
        guard let data = try? JSONEncoder().encode(self), let raw = String(data: data, encoding: .utf8) else { return }
        stageContext.extra[Self.stageKey] = raw
    }
}
