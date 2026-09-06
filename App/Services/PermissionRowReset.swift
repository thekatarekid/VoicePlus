import Foundation
import Shared

/// What removing the app's own TCC entry for one service did.
public enum PermissionRowResetOutcome: Equatable, Sendable {
    /// The entry existed and is gone. The pane's list no longer contains VoicePlus, so the whole
    /// recovery collapses to "press + and switch it on".
    case removed
    /// There was no entry to remove. Also a good outcome — it means the same next step, and it rules
    /// out the stale-entry diagnosis rather than leaving it hanging.
    case noEntry
    case failed(String)

    /// Both non-failing outcomes leave the user in the same place: the list has no VoicePlus row.
    public var listIsNowEmptyOfUs: Bool {
        switch self {
        case .removed, .noEntry: return true
        case .failed: return false
        }
    }
}

public protocol PermissionRowResetting: AnyObject {
    func reset(_ permission: Permission) -> PermissionRowResetOutcome
}

/// Runs `tccutil reset <Service> <bundle id>` — the same command the recovery panel has always
/// offered for copy/paste, executed for the user instead of handed to them.
///
/// Why this is safe to run from the app: `tccutil reset <service> <bundle id>` is scoped to one
/// service of one bundle id, needs no admin rights (verified on macOS 26.6.2 — the call returns
/// straight from `/usr/bin/tccutil` with no authorization prompt), and cannot touch another app.
/// The caller gates it on the escalated recovery phase, where the service is *already* not granted,
/// so there is never a working grant to destroy.
public final class TCCUtilRowReset: PermissionRowResetting {
    public static let executable = "/usr/bin/tccutil"

    private let bundleIdentifier: String
    private let launcher: (String, [String]) -> (status: Int32, output: String)

    public init(bundleIdentifier: String = PermissionDiagnostics.bundleIdentifier,
                launcher: @escaping (String, [String]) -> (status: Int32, output: String) = TCCUtilRowReset.run) {
        self.bundleIdentifier = bundleIdentifier
        self.launcher = launcher
    }

    /// `Microphone` / `Accessibility` / `ListenEvent`, the names `tccutil` takes.
    public static func serviceName(for permission: Permission) -> String {
        switch permission {
        case .microphone: return "Microphone"
        case .accessibility: return "Accessibility"
        case .inputMonitoring: return "ListenEvent"
        }
    }

    public func reset(_ permission: Permission) -> PermissionRowResetOutcome {
        let arguments = ["reset", Self.serviceName(for: permission), bundleIdentifier]
        let result = launcher(Self.executable, arguments)
        let outcome = Self.interpret(status: result.status, output: result.output)
        Log.app.notice("tcc reset \(Self.serviceName(for: permission)) \(self.bundleIdentifier) → \(String(describing: outcome))")
        return outcome
    }

    /// Pure, so the three shapes `tccutil` actually produces are unit-testable without running it.
    public static func interpret(status: Int32, output: String) -> PermissionRowResetOutcome {
        if status == 0 { return .removed }
        // Exit 64 with this message is what a bundle id with no row for that service returns
        // (measured). It is not a failure — there is simply nothing to remove.
        if output.contains("No such bundle identifier") { return .noEntry }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(trimmed.isEmpty ? "tccutil exited \(status)" : trimmed)
    }

    public static func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, "could not run \(executable): \(error.localizedDescription)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

/// Records the request instead of running it.
public final class MockRowReset: PermissionRowResetting {
    public private(set) var resets: [Permission] = []
    public var outcome: PermissionRowResetOutcome = .removed
    public init(outcome: PermissionRowResetOutcome = .removed) { self.outcome = outcome }

    public func reset(_ permission: Permission) -> PermissionRowResetOutcome {
        resets.append(permission)
        return outcome
    }
}

public extension PermissionDiagnostics {
    /// Headless counterpart of the recovery panel's "Remove the old entry" button:
    /// `VoicePlus --reset-permission accessibility`. Same code path as the button, so a release can
    /// be verified against the tccd log without driving the UI — and so the button's claim that it
    /// needs no admin rights is checkable on the machine it ships to.
    static func parseResetCLI(_ arguments: [String]) -> Permission? {
        guard let i = arguments.firstIndex(of: "--reset-permission"), i + 1 < arguments.count else { return nil }
        return Permission(rawValue: arguments[i + 1])
    }

    /// Exit 0 when the entry is gone (removed, or never existed), 1 when tccutil refused.
    static func runResetCLI(_ permission: Permission,
                            reset: PermissionRowResetting = TCCUtilRowReset()) -> Int32 {
        let checker = SystemPermissionChecker()
        print("before: \(permission.rawValue)=\(checker.status(of: permission).rawValue)")
        let outcome = reset.reset(permission)
        print("reset: \(permission.rawValue) → \(String(describing: outcome))")
        print("after: \(permission.rawValue)=\(checker.status(of: permission).rawValue)")
        return outcome.listIsNowEmptyOfUs ? 0 : 1
    }
}
