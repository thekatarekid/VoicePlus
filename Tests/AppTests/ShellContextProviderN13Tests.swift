import Engine
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

// MARK: - N13 — focused shell via the process tree, one folder listed, only after the Settings OK

private func rec(_ pid: Int32, _ ppid: Int32, _ name: String, tty: String? = nil, pgid: Int32? = nil, tpgid: Int32 = 0) -> ShellProcessRecord {
    ShellProcessRecord(pid: pid, ppid: ppid, name: name, tty: tty, pgid: pgid ?? pid, tpgid: tpgid)
}

private final class Calls { var listed: [String] = []; var cwdReads = 0; var aliasReads = 0; var pathScans = 0 }

private func provider(_ table: [ShellProcessRecord], cwd: String? = "/Users/me/VoicePlusTest",
                      activity: [String: Date] = [:], enabled: Bool = true, prompted: Bool = true,
                      calls: Calls = Calls()) -> ShellContextProvider {
    let store = InMemorySettingsStore()
    store.set(enabled, for: ShellFolderSettings.enabledKey)
    store.set(prompted, for: ShellFolderSettings.promptedKey)
    let sources = ShellContextProvider.Sources(
        processes: { table },
        currentDirectory: { _ in calls.cwdReads += 1; return cwd },
        listFolder: { path in
            calls.listed.append(path)
            return [.init(name: "Documents", isDirectory: true), .init(name: "notes.txt", isDirectory: false)]
        },
        ttyActivity: { activity[$0] },
        pathCommands: { calls.pathScans += 1; return ["git", "ls"] },
        aliases: { calls.aliasReads += 1; return ["gs"] })
    return ShellContextProvider(sources: sources, settings: store)
}

@Suite("N13 shell context provider")
struct ShellContextProviderN13Tests {
    // Terminal.app (100) → login (200) → -zsh (300) on ttys004.
    let terminalTable = [
        rec(1, 0, "launchd"), rec(100, 1, "Terminal"), rec(200, 100, "login", tty: "/dev/ttys004"),
        rec(300, 200, "-zsh", tty: "/dev/ttys004", tpgid: 300),
        rec(999, 1, "zsh", tty: "/dev/ttys009", tpgid: 999), // another app's shell — never picked
    ]

    @Test func findsDescendantShellAndListsOneFolder() throws {
        let calls = Calls()
        let ctx = try #require(provider(terminalTable, calls: calls).context(terminalPID: 100))
        #expect(ctx.pid == 300)
        #expect(ctx.shellName == "zsh")
        #expect(ctx.tty == "/dev/ttys004")
        #expect(ctx.currentDirectory == "/Users/me/VoicePlusTest")
        #expect(ctx.entries.map(\.displayName) == ["Documents/", "notes.txt"])
        #expect(calls.listed == ["/Users/me/VoicePlusTest"])   // that one folder, not recursive
        #expect(ctx.knownCommands.isSuperset(of: ["git", "ls", "gs"]))
        #expect(ctx.allCommands.contains("cd"))
    }

    @Test func noListingWithoutPermission() throws {
        let calls = Calls()
        let ctx = try #require(provider(terminalTable, enabled: false, calls: calls).context(terminalPID: 100))
        #expect(ctx.pid == 300)                 // pty ownership still known (resolver evidence)
        #expect(ctx.currentDirectory == nil)
        #expect(ctx.entries.isEmpty)
        #expect(calls.listed.isEmpty && calls.cwdReads == 0 && calls.aliasReads == 0)
        #expect(ctx.knownCommands == ["git", "ls"])   // PATH commands need no permission
    }

    @Test func enabledButNeverPromptedFromSettingsDoesNotList() throws {
        let calls = Calls()
        let ctx = try #require(provider(terminalTable, enabled: true, prompted: false, calls: calls).context(terminalPID: 100))
        #expect(ctx.entries.isEmpty && calls.listed.isEmpty)
    }

    @Test func appWithoutShellGivesNil() {
        #expect(provider(terminalTable).context(terminalPID: 999_999) == nil)
    }

    @Test func vsCodeDeepTreeWorks() throws {
        let table = [rec(10, 1, "Electron"), rec(11, 10, "Code Helper"), rec(12, 11, "Code Helper (Plugin)"),
                     rec(13, 12, "/bin/zsh", tty: "/dev/ttys010", tpgid: 13)]
        let ctx = try #require(provider(table).context(terminalPID: 10))
        #expect(ctx.pid == 13 && ctx.shellName == "zsh")
    }

    @Test func multipleTabsPickHintThenMostRecentInput() throws {
        let table = [rec(100, 1, "iTerm2"), rec(301, 100, "zsh", tty: "/dev/ttys001", tpgid: 301),
                     rec(302, 100, "fish", tty: "/dev/ttys002", tpgid: 302)]
        let t0 = Date(timeIntervalSince1970: 1000)
        let act = ["/dev/ttys001": t0, "/dev/ttys002": t0.addingTimeInterval(5)]
        #expect(provider(table, activity: act).context(terminalPID: 100)?.pid == 302)
        #expect(provider(table, activity: act).context(terminalPID: 100, ttyHint: "ttys001")?.pid == 301)
        // No activity data → ambiguous → no guess.
        #expect(provider(table).context(terminalPID: 100) == nil)
        // Equal activity → ambiguous.
        #expect(provider(table, activity: ["/dev/ttys001": t0, "/dev/ttys002": t0]).context(terminalPID: 100) == nil)
    }

    @Test func nestedShellAtPromptWins() throws {
        // zsh → bash (user ran `bash`); bash owns the foreground group.
        let table = [rec(100, 1, "Terminal"), rec(300, 100, "zsh", tty: "/dev/ttys004", tpgid: 400),
                     rec(400, 300, "bash", tty: "/dev/ttys004", tpgid: 400)]
        #expect(provider(table).context(terminalPID: 100)?.pid == 400)
        // vim in the foreground of zsh: deepest shell on that tty.
        let vim = [rec(100, 1, "Terminal"), rec(300, 100, "zsh", tty: "/dev/ttys004", tpgid: 500),
                   rec(500, 300, "vim", tty: "/dev/ttys004", tpgid: 500)]
        #expect(provider(vim).context(terminalPID: 100)?.pid == 300)
    }

    @Test func pidCycleTerminates() {
        let table = [rec(100, 101, "a"), rec(101, 100, "b")]
        #expect(ShellContextProvider.focusedShell(in: table, terminalPID: 100, ttyHint: nil, ttyActivity: { _ in nil }) == nil)
    }

    @Test func pathCommandsAreCached() {
        let calls = Calls()
        let p = provider(terminalTable, calls: calls)
        let now = Date()
        _ = p.context(terminalPID: 100, now: now)
        _ = p.context(terminalPID: 100, now: now.addingTimeInterval(10))
        #expect(calls.pathScans == 1)
        _ = p.context(terminalPID: 100, now: now.addingTimeInterval(400))
        #expect(calls.pathScans == 2)
    }

    @Test func aliasParsing() {
        let rc = """
        alias gs='git status'
          alias -g L='| less'
        alias ll ls\\ -la
        # alias commented='x'
        export PATH=/x
        alias bad$name=x
        """
        #expect(ShellContextProvider.aliasNames(inRC: rc) == ["gs", "L", "ll"])
    }

    @Test func settingsPromptOnlyOnceAndOnlyFromSettings() {
        let store = InMemorySettingsStore()
        var prompts = 0
        #expect(!ShellFolderSettings.isEnabled(store))   // off by default
        ShellFolderSettings.setEnabled(true, store: store) { prompts += 1 }
        ShellFolderSettings.setEnabled(false, store: store) { prompts += 1 }
        ShellFolderSettings.setEnabled(true, store: store) { prompts += 1 }
        #expect(prompts == 1)
        #expect(ShellFolderSettings.isEnabled(store) && ShellFolderSettings.wasPrompted(store))
        #expect(ShellFolderSettings.protectedFolders(home: "/Users/me") ==
                ["/Users/me/Documents", "/Users/me/Desktop", "/Users/me/Downloads"])
    }

    @Test func candidatesFeedBoostLayers() throws {
        let ctx = try #require(provider(terminalTable).context(terminalPID: 100))
        let cands = ContextCandidates.shell(ctx)
        #expect(cands.contains { $0.text == "Documents" })
    }

    @Test func liveProcessTableFindsThisProcess() {
        // Read-only smoke test of the libproc reader against our own process.
        let me = getpid()
        let all = LiveProcessTable.all()
        #expect(all.contains { $0.pid == me })
        #expect(LiveProcessTable.currentDirectory(me) != nil)
    }
}
