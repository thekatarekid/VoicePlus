import Darwin
import Foundation
import Shared

/// N13 / F26 — the shell behind the focused terminal surface, found through the process tree.
///
/// The terminal app (Terminal, iTerm, WezTerm, Ghostty, VS Code…) is the frontmost app; its shell
/// is a *descendant* on a terminal device (VS Code and iTerm put a helper / `login` in between).
/// Of those shells we pick the one on the focused tab's tty: the caller's hint when it has one,
/// otherwise the tty that most recently received input (the tab the user is typing in). On that
/// tty the shell owning the foreground process group (the one at its prompt) wins.
///
/// Privacy: nothing here reads file contents or screen text. The current folder and the names
/// in it (one level) are read only when Settings → "Use folder names in Terminal" is on and its
/// one-time prompt was made from Settings; otherwise only the shell's identity and the `$PATH`
/// command names are returned. Nothing is persisted.
public struct ShellProcessRecord: Sendable, Equatable {
    public var pid: Int32
    public var ppid: Int32
    public var name: String
    /// `/dev/ttys004`, or nil when the process has no controlling terminal.
    public var tty: String?
    public var pgid: Int32
    /// Foreground process group of the controlling terminal.
    public var tpgid: Int32
    public init(pid: Int32, ppid: Int32, name: String, tty: String?, pgid: Int32, tpgid: Int32) {
        self.pid = pid; self.ppid = ppid; self.name = name; self.tty = tty; self.pgid = pgid; self.tpgid = tpgid
    }
}

public final class ShellContextProvider: @unchecked Sendable {
    /// Injectable OS reads (tests pass fakes; `.live` uses libproc and FileManager).
    public struct Sources {
        public var processes: () -> [ShellProcessRecord]
        public var currentDirectory: (Int32) -> String?
        /// Names of one folder's entries (not recursive); nil when unreadable.
        public var listFolder: (String) -> [ShellContext.Entry]?
        /// Last input time on a tty device (its access time).
        public var ttyActivity: (String) -> Date?
        public var pathCommands: () -> Set<String>
        /// User alias names from shell rc files (names only).
        public var aliases: () -> Set<String>
        public init(processes: @escaping () -> [ShellProcessRecord],
                    currentDirectory: @escaping (Int32) -> String?,
                    listFolder: @escaping (String) -> [ShellContext.Entry]?,
                    ttyActivity: @escaping (String) -> Date?,
                    pathCommands: @escaping () -> Set<String>,
                    aliases: @escaping () -> Set<String>) {
            self.processes = processes; self.currentDirectory = currentDirectory; self.listFolder = listFolder
            self.ttyActivity = ttyActivity; self.pathCommands = pathCommands; self.aliases = aliases
        }
    }

    public static let shellNames: Set<String> = [
        "zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "csh", "nu", "elvish", "xonsh", "pwsh",
    ]
    public static let maxEntries = 500

    private let sources: Sources
    private let settings: SettingsStore?
    private let home: String
    private let commandTTL: TimeInterval
    private let lock = NSLock()
    private var cachedCommands: (at: Date, value: Set<String>)?

    public init(sources: Sources = .live, settings: SettingsStore?, home: String = NSHomeDirectory(),
                commandTTL: TimeInterval = 300) {
        self.sources = sources; self.settings = settings; self.home = home; self.commandTTL = commandTTL
    }

    /// Whether folder names may be read right now (Settings on, and its prompt was made there).
    public var folderNamesAllowed: Bool {
        ShellFolderSettings.isEnabled(settings) && ShellFolderSettings.wasPrompted(settings)
    }

    /// The focused shell of the terminal app `terminalPID`, or nil when it runs no shell.
    public func context(terminalPID: Int32, ttyHint: String? = nil, now: Date = Date()) -> ShellContext? {
        guard let shell = Self.focusedShell(in: sources.processes(), terminalPID: terminalPID,
                                            ttyHint: ttyHint, ttyActivity: sources.ttyActivity) else { return nil }
        var ctx = ShellContext(pid: shell.pid, shellName: Self.baseName(shell.name), tty: shell.tty)
        var commands = commandsCached(now: now)
        if folderNamesAllowed {
            commands.formUnion(sources.aliases())
            if let cwd = sources.currentDirectory(shell.pid) {
                ctx.currentDirectory = cwd
                ctx.entries = Array((sources.listFolder(cwd) ?? []).prefix(Self.maxEntries))
            }
        }
        ctx.knownCommands = commands
        return ctx
    }

    private func commandsCached(now: Date) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        if let c = cachedCommands, now.timeIntervalSince(c.at) < commandTTL { return c.value }
        let v = sources.pathCommands()
        cachedCommands = (now, v)
        return v
    }

    // MARK: - Pure selection

    static func baseName(_ name: String) -> String {
        var n = (name as NSString).lastPathComponent
        if n.hasPrefix("-") { n.removeFirst() }   // login shells show as "-zsh"
        return n
    }

    static func isShell(_ name: String) -> Bool { shellNames.contains(baseName(name)) }

    /// The shell on the focused tab of `terminalPID` (see the type doc for the rule).
    public static func focusedShell(in table: [ShellProcessRecord], terminalPID: Int32, ttyHint: String?,
                                    ttyActivity: (String) -> Date?) -> ShellProcessRecord? {
        var children: [Int32: [ShellProcessRecord]] = [:]
        for p in table where p.pid != p.ppid { children[p.ppid, default: []].append(p) }
        // Descendants with depth (bounded walk; a pid cycle cannot loop).
        var shells: [(ShellProcessRecord, Int)] = []
        var queue: [(Int32, Int)] = [(terminalPID, 0)]
        var seen: Set<Int32> = [terminalPID]
        while !queue.isEmpty, seen.count < 4096 {
            let (pid, depth) = queue.removeFirst()
            for c in children[pid] ?? [] where seen.insert(c.pid).inserted {
                if c.tty != nil, isShell(c.name) { shells.append((c, depth + 1)) }
                queue.append((c.pid, depth + 1))
            }
        }
        guard !shells.isEmpty else { return nil }
        let ttys = Set(shells.compactMap(\.0.tty))
        let tty: String
        if let hint = ttyHint.map(normalizeTTY), ttys.contains(hint) {
            tty = hint
        } else if ttys.count == 1, let only = ttys.first {
            tty = only
        } else {
            // Most recent input wins; no activity data for any of them → ambiguous, no guess.
            let dated = ttys.compactMap { t in ttyActivity(t).map { (t, $0) } }
            guard let best = dated.max(by: { $0.1 < $1.1 }) else { return nil }
            let tied = dated.filter { $0.1 == best.1 }
            guard tied.count == 1 else { return nil }
            tty = best.0
        }
        let onTTY = shells.filter { $0.0.tty == tty }
        if let atPrompt = onTTY.filter({ $0.0.pgid == $0.0.tpgid }).max(by: { $0.1 < $1.1 }) { return atPrompt.0 }
        return onTTY.max(by: { $0.1 < $1.1 })?.0
    }

    static func normalizeTTY(_ t: String) -> String { t.hasPrefix("/dev/") ? t : "/dev/" + t }

    /// Alias names in rc-file text (`alias gs='git status'`, `alias -g X=…`, fish `alias gs 'git status'`).
    public static func aliasNames(inRC text: String) -> Set<String> {
        var out: Set<String> = []
        for raw in text.split(whereSeparator: \.isNewline) {
            var tokens = raw.trimmingCharacters(in: .whitespaces).split(separator: " ", omittingEmptySubsequences: true)
            guard tokens.first == "alias" else { continue }
            tokens.removeFirst()
            while let t = tokens.first, t.hasPrefix("-") { tokens.removeFirst() }
            guard let t = tokens.first else { continue }
            let name = t.split(separator: "=", maxSplits: 1).first.map(String.init) ?? ""
            if !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || "_.-:".contains($0) }) { out.insert(name) }
        }
        return out
    }
}

// MARK: - Live sources

extension ShellContextProvider.Sources {
    public static var live: Self {
        Self(processes: LiveProcessTable.all,
             currentDirectory: LiveProcessTable.currentDirectory,
             listFolder: { path in
                 let url = URL(fileURLWithPath: path, isDirectory: true)
                 guard let items = try? FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return nil }
                 return items.prefix(ShellContextProvider.maxEntries).map {
                     ShellContext.Entry(name: $0.lastPathComponent,
                                        isDirectory: (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true)
                 }.sorted { $0.name < $1.name }
             },
             ttyActivity: { tty in
                 var st = stat()
                 guard stat(tty, &st) == 0 else { return nil }
                 return Date(timeIntervalSince1970: TimeInterval(st.st_atimespec.tv_sec)
                             + TimeInterval(st.st_atimespec.tv_nsec) / 1e9)
             },
             pathCommands: { LivePathCommands.scan() },
             aliases: {
                 let home = NSHomeDirectory()
                 var out: Set<String> = []
                 for f in [".zshrc", ".bashrc", ".bash_profile", ".bash_aliases", ".zsh_aliases", ".aliases",
                           ".config/fish/config.fish"] {
                     let path = (home as NSString).appendingPathComponent(f)
                     guard let data = FileManager.default.contents(atPath: path), data.count < 512_000,
                           let text = String(data: data, encoding: .utf8) else { continue }
                     out.formUnion(ShellContextProvider.aliasNames(inRC: text))
                 }
                 return out
             })
    }
}

enum LivePathCommands {
    static func scan(path: String? = ProcessInfo.processInfo.environment["PATH"]) -> Set<String> {
        let home = NSHomeDirectory()
        var dirs = (path ?? "").split(separator: ":").map(String.init)
        dirs += ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/usr/local/bin", "/opt/homebrew/bin",
                 "/opt/homebrew/sbin", home + "/.local/bin", home + "/.cargo/bin", home + "/bin"]
        var seen: Set<String> = []
        var out: Set<String> = []
        let fm = FileManager.default
        for d in dirs where seen.insert(d).inserted {
            guard let names = try? fm.contentsOfDirectory(atPath: d) else { continue }
            for n in names.prefix(5000) where !n.hasPrefix(".") { out.insert(n) }
        }
        return out
    }
}

enum LiveProcessTable {
    static func all() -> [ShellProcessRecord] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let n = pids.withUnsafeMutableBufferPointer {
            proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
        }
        guard n > 0 else { return [] }
        var out: [ShellProcessRecord] = []
        out.reserveCapacity(Int(n))
        for pid in pids.prefix(Int(n)) where pid > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue }
            let name = withUnsafeBytes(of: info.pbi_comm) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            var tty: String?
            if info.e_tdev != UInt32.max, info.e_tdev != 0, let dn = devname(dev_t(bitPattern: info.e_tdev), S_IFCHR) {
                tty = "/dev/" + String(cString: dn)
            }
            out.append(ShellProcessRecord(pid: pid, ppid: Int32(info.pbi_ppid), name: name, tty: tty,
                                          pgid: Int32(info.pbi_pgid), tpgid: Int32(info.e_tpgid)))
        }
        return out
    }

    static func currentDirectory(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }
}
