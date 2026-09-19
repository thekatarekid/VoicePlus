import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// V4 Wave 1 gate "cold launch → first landing p95 < 2.5 s" (build doc §4): one `.info` line per
/// process, on the first text that lands after launch, measured with an injected clock here.
@Suite("V4 gate — cold launch → first landing timing")
struct LaunchLandingTimingTests {
    final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var _lines: [String] = []
        func append(_ line: String) { lock.withLock { _lines.append(line) } }
        var lines: [String] { lock.withLock { _lines } }
    }

    final class Clock: @unchecked Sendable {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    @Test("exactly one line on the first landing after launch, none after")
    func oncePerProcess() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let clock = Clock(t0), out = Lines()
        let timing = LaunchLandingTiming(now: { clock.now }, emit: out.append)
        timing.markLaunch(at: t0)
        clock.now = t0.addingTimeInterval(1.84)
        #expect(abs((timing.noteLanding() ?? 0) - 1840) < 0.5)
        #expect(out.lines == ["timing: cold launch → first landing 1840 ms"])
        clock.now = t0.addingTimeInterval(9)
        #expect(timing.noteLanding() == nil)
        #expect(timing.noteLanding() == nil)
        #expect(out.lines.count == 1, "later landings log nothing")
    }

    @Test("no launch mark, no line; the first mark wins")
    func launchMark() {
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        let clock = Clock(t0), out = Lines()
        let timing = LaunchLandingTiming(now: { clock.now }, emit: out.append)
        #expect(timing.noteLanding() == nil && out.lines.isEmpty, "a landing before any launch mark says nothing")
        timing.markLaunch(at: t0)
        timing.markLaunch(at: t0.addingTimeInterval(5))
        #expect(timing.launchDate == t0)
        clock.now = t0.addingTimeInterval(2.4)
        #expect(abs((timing.noteLanding() ?? 0) - 2400) < 0.5)
        #expect(out.lines == [LaunchLandingTiming.line(ms: 2400)])
    }

    @Test("the launch mark defaults to this process's start, read from the kernel")
    func processStart() throws {
        let start = try #require(LaunchLandingTiming.processStartDate())
        #expect(start <= Date())
        #expect(Date().timeIntervalSince(start) < 7 * 24 * 3600)
        let timing = LaunchLandingTiming(emit: { _ in })
        timing.markLaunch()
        #expect(timing.launchDate == start)
    }

    @Test("through the lander: two turns land, one timing line")
    func throughTheLander() async throws {
        let t0 = Date()
        let out = Lines()
        let timing = LaunchLandingTiming(now: Date.init, emit: out.append)
        timing.markLaunch(at: t0.addingTimeInterval(-1))
        for text in ["hello there", "and again"] {
            let h = TurnControllerTests.Harness()
            h.lander.launchTiming = timing
            let id = try #require(await h.holdToPreview(TurnControllerTests.words(text)))
            h.controller.finalRendered(id)
            h.clock.advance(1)
            #expect(await h.wait { h.events.landed.count == 1 })
        }
        #expect(out.lines.count == 1)
        #expect(out.lines.first?.hasPrefix("timing: cold launch → first landing ") == true)
    }
}
