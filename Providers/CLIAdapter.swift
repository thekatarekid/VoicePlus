import Foundation
import Shared

/// T5. Paperclip-pattern CLI adapters (reimplemented in Swift, MIT-compatible): drive the
/// user's `claude` / `codex` binaries as prompt-in/text-out subprocesses. Their existing
/// subscription pays; no key, no data path we control.
public enum CLICopy {
    public static let usesExistingSubscription = "Uses your existing subscription"
}

public struct CLITool: Sendable, Equatable, Hashable {
    public var name: String
    /// Arguments that put the tool into non-interactive prompt-in/text-out mode. `{prompt}` is substituted.
    public var arguments: [String]
    public var promptOnStdin: Bool

    public init(name: String, arguments: [String], promptOnStdin: Bool) {
        self.name = name; self.arguments = arguments; self.promptOnStdin = promptOnStdin
    }

    public static let claude = CLITool(name: "claude", arguments: ["-p", "--output-format", "text"], promptOnStdin: true)
    public static let codex = CLITool(name: "codex", arguments: ["exec", "--skip-git-repo-check", "{prompt}"], promptOnStdin: false)
    public static let known: [CLITool] = [.claude, .codex]
}

public struct CLIDetector: Sendable {
    public var searchPaths: [String]
    public init(searchPaths: [String]? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.searchPaths = searchPaths ?? (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.npm-global/bin", "\(home)/.bun/bin", "\(home)/.cargo/bin"]
    }

    public func locate(_ tool: CLITool) -> URL? {
        for dir in searchPaths {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(tool.name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    public func detectAll(_ tools: [CLITool] = CLITool.known) -> [CLIAdapterProvider] {
        tools.compactMap { t in locate(t).map { CLIAdapterProvider(tool: t, binary: $0) } }
    }
}

public struct CLIAdapterProvider: TextGenerator {
    public let tool: CLITool
    public let binary: URL
    public var timeout: TimeInterval
    public var workingDirectory: URL

    public init(tool: CLITool, binary: URL, timeout: TimeInterval = 60, workingDirectory: URL? = nil) {
        self.tool = tool; self.binary = binary; self.timeout = timeout
        self.workingDirectory = workingDirectory ?? FileManager.default.temporaryDirectory.appendingPathComponent("voiceplus-cli", isDirectory: true)
    }

    public var id: ProviderID { ProviderID(rawValue: "cli.\(tool.name)") }
    public var displayName: String { "\(tool.name) CLI — \(CLICopy.usesExistingSubscription)" }
    public var capabilities: ProviderCapabilities { [.pipeline] }
    public var costClass: CostClass { .subscription }
    /// The CLI talks to its vendor's cloud; we log the call even though the bytes leave via the subprocess.
    public var privacyClass: PrivacyClass { .cloud }
    public func isAvailable() async -> Bool { FileManager.default.isExecutableFile(atPath: binary.path) }

    /// Minimal, sandboxed environment: no inherited secrets, scratch HOME-adjacent config kept
    /// (CLIs need their own auth files) but nothing else from the parent process.
    public static func sandboxedEnvironment() -> [String: String] {
        let env = ProcessInfo.processInfo.environment
        var out: [String: String] = ["PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin", "LANG": "en_US.UTF-8", "TERM": "dumb", "NO_COLOR": "1", "CI": "1"]
        for key in ["HOME", "USER", "TMPDIR", "SHELL"] { if let v = env[key] { out[key] = v } }
        return out
    }

    public func generate(prompt: String, system: String, stage: StageID) async throws -> (text: String, bytesOut: Int, bytesIn: Int, host: String) {
        let full = "\(system)\n\n\(prompt)"
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let text = try await run(input: full)
        return (text, full.utf8.count, text.utf8.count, "cli:\(tool.name)")
    }

    func run(input: String) async throws -> String {
        let process = Process()
        process.executableURL = binary
        process.arguments = tool.arguments.map { $0 == "{prompt}" ? input : $0 }
        process.environment = Self.sandboxedEnvironment()
        process.currentDirectoryURL = workingDirectory
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                    let collected = DataBox()
                    stdout.fileHandleForReading.readabilityHandler = { h in
                        let d = h.availableData
                        if d.isEmpty { h.readabilityHandler = nil } else { collected.append(d) }
                    }
                    process.terminationHandler = { p in
                        stdout.fileHandleForReading.readabilityHandler = nil
                        collected.append(stdout.fileHandleForReading.readDataToEndOfFile())
                        let out = String(decoding: collected.data, as: UTF8.self)
                        if p.terminationReason == .uncaughtSignal { cont.resume(throwing: ProviderError.timeout) }
                        else if p.terminationStatus != 0 {
                            let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile().prefix(500), as: UTF8.self)
                            cont.resume(throwing: ProviderError.unavailable("\(self.tool.name) exit \(p.terminationStatus): \(err)"))
                        } else { cont.resume(returning: out.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    }
                    do { try process.run() } catch { cont.resume(throwing: ProviderError.unavailable(error.localizedDescription)); return }
                    if tool.promptOnStdin { stdin.fileHandleForWriting.write(Data(input.utf8)) }
                    try? stdin.fileHandleForWriting.close()
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if process.isRunning { process.terminate() }
                throw ProviderError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

final class DataBox: @unchecked Sendable {
    private let lock = NSLock(); private(set) var data = Data()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
}
