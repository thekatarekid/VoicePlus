import CoreGraphics
import Foundation
import Testing
@testable import VoicePlusApp

/// X2 — arming the active Option tap: no Accessibility yet (first launch, onboarding) is a wait,
/// not a failure (the one-time Claude notice is not spent); a refused tap with Accessibility tells
/// once. Event timestamps read in seconds whether macOS stamps nanoseconds or mach ticks.
@Suite("X2 — Option tap arming and event clock")
struct OptionTapArmingTests {
    private func service() -> HotkeyService {
        HotkeyService(defaults: UserDefaults(suiteName: "AppTests.optionTapArm.\(UUID())")!)
    }

    @Test("untrusted: waits for Accessibility, no fallback notice")
    func untrustedWaits() {
        let s = service()
        var told = 0
        s.onOptionTapUnavailable = { told += 1 }
        s.record(.untrusted)
        #expect(told == 0)
        #expect(s.awaitingAccessibilityForOptionTap)
        #expect(s.optionTapUnavailable)
        #expect(!s.tapFeeds)
    }

    @Test("refused with Accessibility: fallback notice fires, no longer waiting")
    func refusedTells() {
        let s = service()
        var told = 0
        s.onOptionTapUnavailable = { told += 1 }
        s.record(.untrusted)
        s.record(.refused)
        #expect(told == 1)
        #expect(!s.awaitingAccessibilityForOptionTap)
        #expect(s.optionTapUnavailable)
    }

    @Test("retry is a no-op unless waiting (a stopped service never installs a tap)")
    func retryNoop() {
        let s = service()
        s.retryOptionTapIfWaiting()
        #expect(s.optionTap == nil)
        #expect(!s.awaitingAccessibilityForOptionTap)
    }

    @Test("event clock: nanosecond stamps read as nanoseconds")
    func clockNanos() {
        let t = EventClock.seconds(eventTimestamp: 1_000_500_000_000, uptime: 1_000.6, timebase: (125, 3))
        #expect(abs(t - 1_000.5) < 0.000_001)
    }

    @Test("event clock: mach-tick stamps (Apple silicon 125/3) read as ticks, so 350 ms stays 350 ms")
    func clockTicks() {
        let ticks: (Double) -> UInt64 = { UInt64(($0 * 1_000_000_000 * 3 / 125).rounded()) }
        let a = EventClock.seconds(eventTimestamp: ticks(1_000.0), uptime: 1_000.05, timebase: (125, 3))
        let b = EventClock.seconds(eventTimestamp: ticks(1_000.35), uptime: 1_000.4, timebase: (125, 3))
        #expect(abs((b - a) - 0.35) < 0.000_01)
    }

    @Test("event clock: a zero stamp uses the arrival time")
    func clockZero() {
        #expect(EventClock.seconds(eventTimestamp: 0, uptime: 42) == 42)
    }

    @Test("event clock: a real CGEvent stamp lands near uptime")
    func clockRealEvent() throws {
        let e = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 58, keyDown: true))
        let up = ProcessInfo.processInfo.systemUptime
        #expect(abs(EventClock.seconds(eventTimestamp: e.timestamp, uptime: up) - up) < 5)
    }
}
