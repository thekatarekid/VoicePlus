import Foundation
import Testing
@testable import Engine
@testable import Shared

// V5 K6 — the analyzer's floors (pre-speech p10 over ≥ 200 ms, else the running 4 s minimum) never
// see the first 100 ms after start: the built-in mic's 30–45 ms start-up dip is never graded as the room.

private func noise(_ seconds: Double, dbfs: Float, seed: UInt64 = 0xC0FFEE) -> [Float] {
    var state = seed
    let amplitude = Float(pow(10, Double(dbfs) / 20)) * Float(3).squareRoot()
    return (0..<Int(seconds * 16_000)).map { _ in
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let unit = Float(state >> 40) / Float(1 << 24)
        return (unit * 2 - 1) * amplitude
    }
}

private func tone(_ seconds: Double, dbfs: Float) -> [Float] {
    let amplitude = Float(pow(10, Double(dbfs) / 20)) * Float(2).squareRoot()
    return (0..<Int(seconds * 16_000)).map { amplitude * sin(2 * .pi * 200 * Float($0) / 16_000) }
}

/// Room at −52 dBFS with the built-in mic's start-up dip: 10 ms of room, then `dip` seconds at
/// −72 dBFS (20 dB under the room), then room until `total`.
private func roomWithStartupDip(total: Double, dip: Double = 0.04) -> [Float] {
    noise(0.01, dbfs: -52) + noise(dip, dbfs: -72, seed: 7) + noise(total - 0.01 - dip, dbfs: -52, seed: 9)
}

@Suite struct MicQualityFloorHoldTests {
    @Test func startupDipIsNotThePreSpeechFloor() throws {
        let a = MicQualityAnalyzer()
        a.feed(roomWithStartupDip(total: 0.35))
        a.note(.speechStart(at: 0.35))
        let q = try #require(a.feed(tone(1.1, dbfs: -22)))
        let m = try #require(a.measurement)
        #expect(m.floorSource == .preSpeech)
        #expect(abs(m.floorDBFS + 52) < 2, "floor is the room, not the −72 dip; got \(m.floorDBFS)")
        #expect(abs(q.snr - 30) < 2.5, "≈ 30 dB, not ≈ 50 dB; got \(q.snr)")
    }

    @Test func startupDipIsNotTheRunningMinimum() throws {
        // Pre-speech window under 200 ms → running minimum; the dip must not be it either.
        let a = MicQualityAnalyzer()
        a.feed(roomWithStartupDip(total: 0.15))
        a.note(.speechStart(at: 0.15))
        let q = try #require(a.feed(tone(1.1, dbfs: -22)))
        let m = try #require(a.measurement)
        #expect(m.floorSource == .runningMinimum)
        #expect(abs(m.floorDBFS + 52) < 2, "got \(m.floorDBFS)")
        #expect(q.snr < 33)
    }

    @Test func dipAtTheVeryFirstFramesIsNotAFloor() throws {
        // Dip from sample 0 (no room before it): those frames have inside the start-up hold.
        let a = MicQualityAnalyzer()
        a.feed(noise(0.04, dbfs: -75, seed: 3) + noise(0.26, dbfs: -52))
        a.note(.speechStart(at: 0.3))
        _ = try #require(a.feed(tone(1.1, dbfs: -22)))
        #expect(abs((a.measurement?.floorDBFS ?? 0) + 52) < 2)
    }

    @Test func eightyMillisecondDipIsNotAFloor() throws {
        let a = MicQualityAnalyzer()
        a.feed(roomWithStartupDip(total: 0.4, dip: 0.08))
        a.note(.speechStart(at: 0.4))
        _ = try #require(a.feed(tone(1.1, dbfs: -22)))
        #expect(abs((a.measurement?.floorDBFS ?? 0) + 52) < 2)
    }

    @Test func shortGapsBetweenWordsStillSetTheRunningFloor() throws {
        // No level hold: a 30 ms gap between words is still the quietest audio heard.
        let a = MicQualityAnalyzer()
        a.feed(noise(0.12, dbfs: -30))
        a.note(.speechStart(at: 0.12))
        var words: [Float] = []
        for _ in 0..<6 { words += tone(0.2, dbfs: -20) + noise(0.03, dbfs: -50, seed: 21) }
        _ = try #require(a.feed(words))
        let m = try #require(a.measurement)
        #expect(m.floorSource == .runningMinimum)
        #expect(m.floorDBFS < -49 && m.floorDBFS > -54, "got \(m.floorDBFS)")
    }

    @Test func aLongerC1WarmupWins() throws {
        let a = MicQualityAnalyzer()
        a.warmup = 0.3
        a.feed(noise(0.3, dbfs: -75, seed: 3) + noise(0.25, dbfs: -52))
        a.note(.speechStart(at: 0.55))
        _ = try #require(a.feed(tone(1.1, dbfs: -22)))
        #expect(a.measurement?.floorSource == .preSpeech)
        #expect(abs((a.measurement?.floorDBFS ?? 0) + 52) < 2)
    }

    @Test func holdCoversTheWorstStartupDipSeen() {
        #expect(MicQualityAnalyzer.startupHold >= 0.08 && MicQualityAnalyzer.startupHold < MicQualityAnalyzer.minimumPreSpeech)
    }
}
