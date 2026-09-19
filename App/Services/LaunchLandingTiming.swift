import Darwin
import Foundation
import Shared

/// V4 Wave 1 gate "cold launch → first landing p95 < 2.5 s" (build doc §4, owner checklist §5 item 2):
/// the owner reads it from the `.info` timing log, beside "audio: key-down → first buffer N ms". One
/// line per process, on the first text that lands after launch:
///
///     timing: cold launch → first landing 1840 ms
///
/// "Launch" is the process start (`kinfo_proc.p_starttime`), so dyld, static init and the container
/// build all count; `applicationWillFinishLaunching` marks it, falling back to that moment when the
/// process start cannot be read. "Landing" is the first write that posted text (`UtteranceLander`,
/// the one place every hold, latch segment and guided landing is inserted), verified or not.
public final class LaunchLandingTiming: @unchecked Sendable {
    public static let shared = LaunchLandingTiming()

    private let lock = NSLock()
    private var launchedAt: Date?
    private var reported = false
    private let now: () -> Date
    private let emit: (String) -> Void

    public init(now: @escaping () -> Date = Date.init, emit: @escaping (String) -> Void = { Log.app.info($0) }) {
        self.now = now
        self.emit = emit
    }

    /// The launch mark, once set.
    public var launchDate: Date? { lock.withLock { launchedAt } }

    /// Records the launch once (the first call wins): `date`, else the process start, else now.
    public func markLaunch(at date: Date? = nil) {
        let start = date ?? Self.processStartDate() ?? now()
        lock.withLock { if launchedAt == nil { launchedAt = start } }
    }

    /// A write posted text. The first one after `markLaunch` logs the timing line and returns its
    /// milliseconds; every later landing (and one before any launch mark) logs nothing and returns nil.
    @discardableResult
    public func noteLanding() -> Double? {
        let at = now()
        let ms = lock.withLock { () -> Double? in
            guard !reported, let launchedAt else { return nil }
            reported = true
            return max(0, at.timeIntervalSince(launchedAt) * 1000)
        }
        if let ms { emit(Self.line(ms: ms)) }
        return ms
    }

    /// The log line the owner greps for.
    public static func line(ms: Double) -> String {
        "timing: cold launch → first landing \(String(format: "%.0f", ms)) ms"
    }

    /// When this process started, from the kernel (`sysctl kern.proc.pid`). nil when unreadable.
    public static func processStartDate(pid: pid_t = getpid()) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        guard start.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }
}
