import Foundation
import Injection
import Shared

/// FX1 — a main-thread stall leaves a trace.
///
/// The 1.11 onboarding freeze left nothing behind: Activity Monitor's force-quit writes no hang
/// report, and the injector's own lines were `info`/`debug`, which the unified log does not keep.
/// This pings the main queue from a background timer; when a ping has gone unanswered for
/// `threshold` (2 s) it logs **one** `.fault` naming what the turn was doing (the breadcrumb the
/// turn controller's write path leaves) and, when the main thread answers again, a `.notice` with
/// how long it was gone. Nothing else: no stack capture, no recovery attempt, no telemetry.
public final class MainThreadWatchdog: @unchecked Sendable {
    public static let shared = MainThreadWatchdog()

    /// Where the turn was when it last said so (turn controller, write path).
    public struct Breadcrumb: Equatable, Sendable {
        public var turn: String
        public var stage: String
        public var destination: String
        public var at: Date
    }

    public let threshold: TimeInterval
    public let interval: TimeInterval

    private let pingMain: (@escaping () -> Void) -> Void
    private let fault: (String) -> Void
    private let notice: (String) -> Void
    private let now: () -> Date
    private let queue = DispatchQueue(label: "in.adityakatare.voiceplus.main-thread-watchdog", qos: .utility)

    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var pingSentAt: Date?
    private var stallReported = false
    private var crumb: Breadcrumb?

    public init(threshold: TimeInterval = 2, interval: TimeInterval = 0.5,
                pingMain: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
                fault: @escaping (String) -> Void = { Log.app.fault($0) },
                notice: @escaping (String) -> Void = { Log.app.notice($0) },
                now: @escaping () -> Date = Date.init) {
        self.threshold = threshold
        self.interval = interval
        self.pingMain = pingMain
        self.fault = fault
        self.notice = notice
        self.now = now
    }

    // MARK: Running

    public var isRunning: Bool { lock.withLock { timer != nil } }

    public func start() {
        lock.withLock {
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(50))
            source.setEventHandler { [weak self] in self?.tick() }
            timer = source
            source.resume()
        }
    }

    public func stop() {
        let source = lock.withLock { () -> DispatchSourceTimer? in
            defer { timer = nil; pingSentAt = nil; stallReported = false }
            return timer
        }
        source?.cancel()
    }

    // MARK: Breadcrumbs

    /// The turn controller's write path: which turn, which stage, where it is writing.
    public static func note(turn: String, stage: String, destination: FocusSnapshot?) {
        shared.note(turn: turn, stage: stage, destination: destination)
    }

    public func note(turn: String, stage: String, destination: FocusSnapshot?) {
        let crumb = Breadcrumb(turn: turn, stage: stage, destination: Self.describe(destination), at: now())
        lock.withLock { self.crumb = crumb }
    }

    public var breadcrumb: Breadcrumb? { lock.withLock { crumb } }

    static func describe(_ focus: FocusSnapshot?) -> String {
        guard let focus else { return "unknown destination" }
        let own = OwnProcess.owns(focus) ? ", VoicePlus itself" : ""
        return focus.appName.isEmpty ? "\(focus.bundleID)\(own)" : "\(focus.bundleID) (\(focus.appName)\(own))"
    }

    // MARK: The check

    private enum Tick {
        case ping
        case stalled(TimeInterval, Breadcrumb?)
        case waiting
    }

    /// One watchdog beat (the timer calls it; tests call it directly). Sends a ping when none is
    /// outstanding; reports once when the outstanding one is `threshold` old.
    func tick() {
        let at = now()
        let beat = lock.withLock { () -> Tick in
            guard let sent = pingSentAt else {
                pingSentAt = at
                return .ping
            }
            let waited = at.timeIntervalSince(sent)
            guard waited >= threshold, !stallReported else { return .waiting }
            stallReported = true
            return .stalled(waited, crumb)
        }
        switch beat {
        case .ping: pingMain { [weak self] in self?.pong() }
        case .stalled(let waited, let crumb): fault(Self.stallMessage(waited: waited, crumb: crumb, at: at))
        case .waiting: break
        }
    }

    private func pong() {
        let at = now()
        let gone = lock.withLock { () -> TimeInterval? in
            defer { pingSentAt = nil; stallReported = false }
            guard stallReported, let sent = pingSentAt else { return nil }
            return at.timeIntervalSince(sent)
        }
        if let gone { notice("main thread answered again after \(String(format: "%.1f", gone)) s") }
    }

    static func stallMessage(waited: TimeInterval, crumb: Breadcrumb?, at: Date) -> String {
        let seconds = String(format: "%.1f", waited)
        guard let crumb else { return "main thread stalled for \(seconds) s — no turn has written yet" }
        let age = String(format: "%.1f", max(0, at.timeIntervalSince(crumb.at)))
        return "main thread stalled for \(seconds) s — turn \(crumb.turn) stage \(crumb.stage), destination \(crumb.destination) (noted \(age) s before)"
    }
}
