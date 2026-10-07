import Foundation
import Shared

/// Context Writer §2.1 — what is running in the foreground of the focused terminal tab.
///
/// `ShellContext` names the shell on the tab's tty; the packet also needs to know whether that
/// shell is at its prompt (destination `shell`) or running an AI agent CLI such as Claude Code or
/// Codex (destination `ai.agentCLI`, prose not shell). The answer is the process on the same tty
/// whose process group is the tty's foreground group and that is not a shell. One libproc table
/// walk (`LiveProcessTable.all`, the same read the shell probe makes), once per turn, off the
/// key-down thread; no `ps`, no screen text, nothing persisted.
public enum TTYForegroundProcess {
    /// AI agent CLIs by process name (`pbi_comm`, 16 characters at most).
    public static let agentNames: Set<String> = [
        "claude", "codex", "aider", "gemini", "copilot", "cursor-agent", "cursor", "amp", "goose", "opencode",
        "crush", "kiro", "q", "droid", "jules", "cline", "sgpt", "ollama", "llm", "pi", "forge", "plandex",
        "warp-agent", "open-interprete", "interpreter", "continue",
    ]

    public static func isAgent(_ name: String?) -> Bool {
        guard let name, !name.isEmpty else { return false }
        return agentNames.contains(ShellContextProvider.baseName(name).lowercased())
    }

    /// Pure: the foreground process on `tty` other than the shell at its prompt (nil = at the
    /// prompt, or the tty is not in the table). Among several foreground processes the shell's
    /// own descendant wins, then the newest pid.
    public static func resolve(tty: String, shellPID: Int32?, table: [ShellProcessRecord]) -> String? {
        let device = ShellContextProvider.normalizeTTY(tty)
        let onTTY = table.filter { $0.tty == device }
        guard !onTTY.isEmpty else { return nil }
        let tpgid = (onTTY.first { $0.pid == shellPID } ?? onTTY[0]).tpgid
        guard tpgid > 0 else { return nil }
        let foreground = onTTY.filter { $0.pgid == tpgid && !ShellContextProvider.isShell($0.name) && $0.pid != shellPID }
        guard !foreground.isEmpty else { return nil }
        let parents = Dictionary(table.map { ($0.pid, $0.ppid) }, uniquingKeysWith: { a, _ in a })
        func descendsFromShell(_ pid: Int32) -> Bool {
            guard let shellPID else { return false }
            var p = pid, hops = 0
            while let pp = parents[p], hops < 64 {
                if pp == shellPID { return true }
                if pp == p || pp <= 1 { return false }
                p = pp; hops += 1
            }
            return false
        }
        let ranked = foreground.sorted {
            let a = descendsFromShell($0.pid), b = descendsFromShell($1.pid)
            return a != b ? a : $0.pid > $1.pid
        }
        return ranked.first.map { ShellContextProvider.baseName($0.name) }
    }

    /// The live answer for the turn's shell. Call once per turn on a background queue (the
    /// process table is a few milliseconds); nil when the shell has no tty.
    public static func live(_ shell: ShellContext?, table: (() -> [ShellProcessRecord])? = nil) -> String? {
        guard let shell, let tty = shell.tty else { return nil }
        return resolve(tty: tty, shellPID: shell.pid, table: (table ?? LiveProcessTable.all)())
    }
}
