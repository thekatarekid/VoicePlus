import Foundation
import Injection
import Shared
import Testing
@testable import VoicePlusApp

/// FX1 — the next freeze leaves a trace: a main thread gone for 2 s logs one fault naming the turn's
/// stage and destination; its return logs a notice. Driven beat by beat with a manual clock and a
/// main queue the test controls; one live check with the real timer.
@Suite("FX1 — main-thread stall watchdog")
struct MainThreadWatchdogTests {
    final class Rig: @unchecked Sendable {
        private let lock = NSLock()
        private var _now = Date(timeIntervalSince1970: 1_000)
        private var _pending: [() -> Void] = []
        private var _faults: [String] = []
        private var _notices: [String] = []
        /// false: the "main thread" holds pings until `drain()`.
        var responsive = false

        lazy var watchdog = MainThreadWatchdog(
            threshold: 2, interval: 0.5,
            pingMain: { [unowned self] work in
                if responsive { work() } else { lock.withLock { _pending.append(work) } }
            },
            fault: { [unowned self] in let m = $0; lock.withLock { _faults.append(m) } },
            notice: { [unowned self] in let m = $0; lock.withLock { _notices.append(m) } },
            now: { [unowned self] in lock.withLock { _now } })

        var faults: [String] { lock.withLock { _faults } }
        var notices: [String] { lock.withLock { _notices } }
        func advance(_ seconds: TimeInterval) { lock.withLock { _now = _now.addingTimeInterval(seconds) } }
        func drain() {
            let work = lock.withLock { () -> [() -> Void] in defer { _pending = [] }; return _pending }
            work.forEach { $0() }
        }
        /// `beats` watchdog ticks, `interval` apart.
        func beat(_ beats: Int = 1) {
            for _ in 0..<beats { watchdog.tick(); advance(watchdog.interval) }
        }
    }

    static let own = FocusSnapshot(pid: OwnProcess.pid, bundleID: "in.adityakatare.voiceplus", appName: "VoicePlus")

    @Test("a main thread gone 2 s: one fault with the turn's stage and destination")
    func stallReportsOnceWithBreadcrumb() {
        let rig = Rig()
        rig.watchdog.note(turn: "T7", stage: "inserting", destination: Self.own)
        rig.beat(4)   // ping at 0, unanswered for 1.5 s
        #expect(rig.faults.isEmpty, "under the threshold: nothing")
        rig.beat(1)   // 2.0 s
        #expect(rig.faults.count == 1)
        let fault = rig.faults.first ?? ""
        #expect(fault.contains("main thread stalled for 2.0 s"))
        #expect(fault.contains("turn T7 stage inserting"))
        #expect(fault.contains("in.adityakatare.voiceplus (VoicePlus, VoicePlus itself)"))
        rig.beat(20)
        #expect(rig.faults.count == 1, "one fault per stall, however long it lasts")

        rig.drain()   // the main thread answers, and keeps answering
        rig.responsive = true
        #expect(rig.notices.count == 1)
        #expect(rig.notices.first?.hasPrefix("main thread answered again after") == true)
        rig.beat(10)
        #expect(rig.faults.count == 1 && rig.notices.count == 1)
    }

    @Test("a responsive main thread never reports")
    func responsiveNeverReports() {
        let rig = Rig()
        rig.responsive = true
        rig.beat(100)
        #expect(rig.faults.isEmpty)
        #expect(rig.notices.isEmpty)
    }

    @Test("a stall with no turn in flight still says so")
    func stallWithoutBreadcrumb() {
        let rig = Rig()
        rig.beat(5)
        #expect(rig.faults == ["main thread stalled for 2.0 s — no turn has written yet"])
    }

    @Test("a second stall after recovery is reported again")
    func secondStallReportsAgain() {
        let rig = Rig()
        rig.beat(5)
        rig.drain()
        rig.beat(5)
        #expect(rig.faults.count == 2)
    }

    @Test("live: the real timer and the real main queue — a blocked main thread is reported")
    func liveTimerReportsABlockedMainThread() async {
        let faults = Faults()
        let watchdog = MainThreadWatchdog(threshold: 0.15, interval: 0.03, fault: { faults.add($0) }, notice: { _ in })
        watchdog.start()
        #expect(watchdog.isRunning)
        DispatchQueue.main.async { Thread.sleep(forTimeInterval: 0.45) }   // a short, real stall
        let deadline = Date().addingTimeInterval(3)
        while faults.count == 0, Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
        watchdog.stop()
        #expect(faults.count >= 1)
        #expect(!watchdog.isRunning)
    }

    final class Faults: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String] = []
        func add(_ message: String) { lock.withLock { list.append(message) } }
        var count: Int { lock.withLock { list.count } }
    }
}
