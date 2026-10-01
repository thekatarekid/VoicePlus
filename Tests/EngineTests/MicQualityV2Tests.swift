import Foundation
import Testing
@testable import Engine
@testable import Shared

// F1 (V4.18) — MicQualityAnalyzer v2: noise floor from the pre-speech window, signal from the first
// second of VAD speech, one verdict, a pause is never graded.

// MARK: synthetic signals

/// Deterministic white noise with the given RMS.
private func noise(_ seconds: Double, dbfs: Float, seed: UInt64 = 0x5eed) -> [Float] {
    var state = seed
    let amplitude = Float(pow(10, Double(dbfs) / 20)) * Float(3).squareRoot()   // uniform: rms = a/√3
    return (0..<Int(seconds * 16_000)).map { _ in
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let unit = Float(state >> 40) / Float(1 << 24)
        return (unit * 2 - 1) * amplitude
    }
}

/// A 200 Hz sine — exactly two cycles per 10 ms frame, so every frame has the same RMS.
private func tone(_ seconds: Double, dbfs: Float) -> [Float] {
    let amplitude = Float(pow(10, Double(dbfs) / 20)) * Float(2).squareRoot()      // sine: rms = a/√2
    return (0..<Int(seconds * 16_000)).map { amplitude * sin(2 * .pi * 200 * Float($0) / 16_000) }
}

private func samples(_ seconds: Double) -> Int { Int(seconds * 16_000) }

// MARK: drivers

/// Drives an analyzer the way `AudioPipeline.process` does: one VAD frame at a time, the analyzer
/// fed each frame just before the VAD hears it and handed every event, the real tail before the
/// VAD's zero-padded last frame, `flush()` at stop.
///
/// `vadHears` (sample-aligned with `audio`) is what the VAD is given instead of `audio`: the clean
/// source of a noisy fixture makes it an oracle VAD, one that hears the speech through the noise.
private func replay(_ audio: [Float], vadHears: [Float]? = nil, vad: any VADProtocol = EnergyVAD()) async throws -> (analyzer: MicQualityAnalyzer, verdicts: [MicQuality]) {
    let heard = vadHears ?? audio
    let analyzer = MicQualityAnalyzer()
    await vad.reset()
    var verdicts: [MicQuality] = []
    var i = 0
    while i < audio.count {
        let end = min(i + vad.frameSize, audio.count)
        if let q = analyzer.feed(Array(audio[i..<end])) { verdicts.append(q) }
        var frame = Array(heard[i..<min(end, heard.count)])
        frame.append(contentsOf: [Float](repeating: 0, count: vad.frameSize - frame.count))
        if let event = try await vad.process(frame: frame).event { analyzer.note(event) }
        i = end
    }
    if let q = analyzer.flush() { verdicts.append(q) }
    return (analyzer, verdicts)
}

/// Every `.micQuality` the real pipeline publishes for `audio`, start to stop.
private func pipelineVerdicts(_ audio: [Float]) async throws -> (verdicts: [MicQuality], last: MicQuality?) {
    let source = FixtureCaptureSource(wav: WAVFile(sampleRate: 16_000, samples: audio))
    let pipeline = AudioPipeline(source: source, vad: EnergyVAD())
    let stream = pipeline.events()
    let collector = Task { () -> [MicQuality] in
        var out: [MicQuality] = []
        for await e in stream {
            if case .micQuality(let q) = e { out.append(q) }
            if case .stopped = e { break }
        }
        return out
    }
    try await pipeline.start()
    await pipeline.stop()
    return (await collector.value, pipeline.lastMicQuality)
}

private func wav(_ suite: String, _ name: String) throws -> [Float] {
    try WAVFile.read(url: try #require(AudioFixtures.url(suite, name))).samples
}

// MARK: the analyzer, with scripted VAD events

@Suite struct MicQualityAnalyzerV2Tests {
    @Test func publishesOnceAfterOneSecondOfSpeech() throws {
        let a = MicQualityAnalyzer()
        #expect(a.feed(noise(0.5, dbfs: -60)) == nil)
        a.note(.speechStart(at: 0.5))
        #expect(a.feed(tone(0.9, dbfs: -20)) == nil, "0.9 s of speech is not yet a second")
        let q = try #require(a.feed(tone(0.1, dbfs: -20)), "the verdict is due once 1 s of speech exists")
        #expect(q.verdict == .good && !q.lowLevel)
        #expect(abs(q.snr - 40) < 1.5, "tone at −20 over a −60 floor, got \(q.snr)")
        let m = try #require(a.measurement)
        #expect(m.floorSource == .preSpeech)
        #expect(abs(m.speechSeconds - 1) < 1e-9)
        #expect(a.feed(tone(2, dbfs: -20)) == nil, "published once")
        a.note(.speechEnd(at: 3))
        #expect(a.flush() == nil, "flush never publishes a second verdict")
        #expect(a.result == q)
    }

    @Test func aPauseIsNeverGraded() {
        for pause in [noise(5, dbfs: -60), [Float](repeating: 0, count: samples(5)), noise(5, dbfs: -20)] {
            let a = MicQualityAnalyzer()
            var i = 0
            while i < pause.count { #expect(a.feed(Array(pause[i..<min(i + 800, pause.count)])) == nil); i += 800 }
            #expect(a.flush() == nil, "no speech, no verdict")
            #expect(a.result == nil && a.measurement == nil)
        }
    }

    /// v1 graded 300 ms of the pause after its 1.5 s deadline: "Mic level is very low".
    @Test func aLongPauseBeforeSpeechIsTheFloorNotAVerdict() throws {
        let a = MicQualityAnalyzer()
        #expect(a.feed(noise(1.5, dbfs: -70)) == nil)
        a.note(.speechStart(at: 1.5))
        let q = try #require(a.feed(tone(1.2, dbfs: -20)))
        #expect(!q.lowLevel)
        #expect(q.verdict == .good)
        #expect(abs(q.snr - 50) < 1.5)
        #expect(a.measurement?.floorSource == .preSpeech)
    }

    @Test func lowLevelOnlyWhenSpeechPeaksBelowMinus40() throws {
        // Sine peak = rms + 3 dB. Quiet room, quiet speech: peak −45 dBFS → low level.
        let quiet = MicQualityAnalyzer()
        quiet.feed(noise(0.5, dbfs: -85))
        quiet.note(.speechStart(at: 0.5))
        let q = try #require(quiet.feed(tone(1, dbfs: -48)))
        #expect(q.lowLevel && q.verdict == .bad)
        #expect(abs((quiet.measurement?.speechPeakDBFS ?? 0) + 45) < 0.5)
        // Same room, speech peaking at −35 dBFS: not low, and the SNR is fine.
        let fine = MicQualityAnalyzer()
        fine.feed(noise(0.5, dbfs: -85))
        fine.note(.speechStart(at: 0.5))
        let f = try #require(fine.feed(tone(1, dbfs: -38)))
        #expect(!f.lowLevel && f.verdict == .good)
    }

    @Test func aShortPreSpeechWindowFallsBackToTheRunningMinimum() throws {
        let a = MicQualityAnalyzer()
        #expect(a.feed(noise(0.1, dbfs: -30)) == nil)        // 100 ms: too short to be the floor
        a.note(.speechStart(at: 0.1))
        var speech: [Float] = []
        for _ in 0..<6 { speech += tone(0.2, dbfs: -20) + noise(0.05, dbfs: -50) }   // words and gaps
        let q = try #require(a.feed(speech))
        let m = try #require(a.measurement)
        #expect(m.floorSource == .runningMinimum)
        // The quietest 10 ms gap frame of −50 dBFS white noise sits a dB or two below −50.
        #expect(m.floorDBFS < -50 && m.floorDBFS > -54, "floor \(m.floorDBFS)")
        #expect(q.snr > 29 && q.snr < 34, "snr \(q.snr)")
        #expect(q.verdict == .good)
    }

    /// Words from the first sample: the energy VAD learns its floor from them and reports onset late,
    /// so its "pre-speech" window is speech. Its p10 sits far above the quietest frames heard.
    @Test func aPreSpeechWindowThatHeldSpeechIsNotTheFloor() throws {
        let a = MicQualityAnalyzer()
        var words: [Float] = []
        for _ in 0..<5 { words += tone(0.19, dbfs: -20) + noise(0.01, dbfs: -70) }   // 1 s, 5 % gaps (K6: the first 100 ms is never a floor)
        a.feed(Array(words.prefix(samples(0.5))))
        a.note(.speechStart(at: 0.5))                        // the VAD caught up half a second late
        let q = try #require(a.feed(Array(words.suffix(samples(0.5))) + tone(0.5, dbfs: -20) + noise(0.05, dbfs: -70) + tone(0.1, dbfs: -20)))
        let m = try #require(a.measurement)
        #expect(m.floorSource == .missedOnset)
        #expect(m.floorDBFS < -70 && m.floorDBFS > -74, "floor \(m.floorDBFS)")
        #expect(q.verdict == .good && q.snr > 45, "snr \(q.snr)")
    }

    /// A loud room also puts speech-level frames in the window, but its quiet tenth is the room itself:
    /// that is a floor, not a missed onset.
    @Test func aLoudRoomIsNotAMissedOnset() throws {
        let a = MicQualityAnalyzer()
        a.feed(noise(0.5, dbfs: -25))
        a.note(.speechStart(at: 0.5))
        var speech: [Float] = []
        for _ in 0..<5 { speech += tone(0.2, dbfs: -20) + noise(0.05, dbfs: -25, seed: 99) }
        let q = try #require(a.feed(speech))
        #expect(a.measurement?.floorSource == .preSpeech)
        #expect(q.snr > 4 && q.snr < 7, "snr \(q.snr)")
        #expect(q.verdict != .good)
    }

    @Test func digitalSilenceIsNotANoiseFloor() throws {
        // Zero buffers at key-down, then a noisy room: the zeros must not hide the room.
        let a = MicQualityAnalyzer()
        a.feed([Float](repeating: 0, count: samples(0.2)) + noise(0.4, dbfs: -28))
        a.note(.speechStart(at: 0.6))
        let q = try #require(a.feed(tone(1, dbfs: -20)))
        #expect(a.measurement?.floorSource == .preSpeech)
        #expect(q.snr < 10 && q.snr > 7, "snr \(q.snr)")
        #expect(q.verdict == .poor)
        // A window of nothing but digital silence (a virtual device): the floor is the digital floor.
        let b = MicQualityAnalyzer()
        b.feed([Float](repeating: 0, count: samples(0.5)))
        b.note(.speechStart(at: 0.5))
        let d = try #require(b.feed(tone(1, dbfs: -20)))
        #expect(b.measurement?.floorSource == .digitalSilence)
        #expect(d.verdict == .good && abs(d.snr - 80) < 1)
    }

    @Test func thePauseBetweenSegmentsIsNotSpeech() throws {
        let a = MicQualityAnalyzer()
        a.feed(noise(0.5, dbfs: -60))
        a.note(.speechStart(at: 0.5))
        #expect(a.feed(tone(0.5, dbfs: -20)) == nil)          // 0.5 s of speech
        #expect(a.feed(noise(0.4, dbfs: -60)) == nil)         // the VAD's hangover
        a.note(.speechEnd(at: 1.0))
        #expect(a.feed(noise(0.6, dbfs: -60)) == nil, "a full second of audio since onset, but only 0.5 s of it speech")
        #expect(a.feed(tone(0.1, dbfs: -20)) == nil)
        a.note(.speechStart(at: 2.0))
        #expect(a.feed(tone(0.39, dbfs: -20)) == nil)         // 0.5 + 0.49 s
        let q = try #require(a.feed(tone(0.01, dbfs: -20)))
        #expect(q.verdict == .good && abs(q.snr - 40) < 1.5)
    }

    @Test func flushGradesTheSpeechOfAShortUtterance() throws {
        let a = MicQualityAnalyzer()
        a.feed(noise(0.5, dbfs: -60))
        a.note(.speechStart(at: 0.5))
        a.feed(tone(0.4, dbfs: -20))
        a.feed(noise(0.4, dbfs: -60))
        a.note(.speechEnd(at: 0.9))
        let q = try #require(a.flush(), "speech was heard: flush grades it")
        #expect(q.verdict == .good)
        #expect(abs((a.measurement?.speechSeconds ?? 0) - 0.4) < 0.011)
        // A segment still open at key-up is graded too.
        let open = MicQualityAnalyzer()
        open.feed(noise(0.3, dbfs: -60))
        open.note(.speechStart(at: 0.3))
        open.feed(tone(0.25, dbfs: -20))
        #expect(open.flush()?.verdict == .good)
    }

    @Test func clippingIsMeasuredOverSpeech() throws {
        let a = MicQualityAnalyzer()
        a.feed(noise(0.5, dbfs: -50))
        a.note(.speechStart(at: 0.5))
        let hot = tone(1, dbfs: 0).map { max(-0.99, min(0.99, $0)) }   // ~ +3 dB over full scale, clipped
        let q = try #require(a.feed(hot))
        #expect(q.clipping > MicQualityAnalyzer.badClipping)
        #expect(q.verdict == .bad && !q.lowLevel)
    }

    @Test func verdictThresholds() {
        let v = MicQualityAnalyzer.verdict
        #expect(v(30, 0, false) == .good)
        #expect(v(10, 0, false) == .good)
        #expect(v(9.9, 0, false) == .poor)
        #expect(v(5, 0, false) == .poor)
        #expect(v(4.9, 0, false) == .bad)
        #expect(v(30, 0, true) == .bad)
        #expect(v(30, 0.003, false) == .poor)
        #expect(v(30, 0.03, false) == .bad)
    }

    @Test func resetStartsANewCapture() throws {
        let a = MicQualityAnalyzer()
        a.feed(noise(0.5, dbfs: -60))
        a.note(.speechStart(at: 0.5))
        _ = try #require(a.feed(tone(1, dbfs: -20)))
        a.reset()
        #expect(a.result == nil && a.measurement == nil)
        #expect(a.feed(noise(0.5, dbfs: -30)) == nil)
        a.note(.speechStart(at: 0.5))
        let q = try #require(a.feed(tone(1, dbfs: -20)))
        #expect(abs(q.snr - 10) < 1.5, "the new capture's floor, not the old one: \(q.snr)")
    }
}

// MARK: fixtures, through the energy VAD and the real pipeline

@Suite struct MicQualityFixtureTests {
    @Test func cleanSpeechIsGood() async throws {
        let files = AudioFixtures.list("clean")
        #expect(files.count == 12)
        for url in files {
            let audio = try WAVFile.read(url: url).samples
            // As recorded (the first word at the first sample), and after 0.5 s of a quiet room.
            for input in [audio, noise(0.5, dbfs: -70) + audio] {
                let (_, verdicts) = try await replay(input)
                #expect(verdicts.count == 1, "\(url.lastPathComponent)")
                let q = try #require(verdicts.first)
                // As recorded there is no room audio at all: the floor is the word's own quietest
                // frames after the K6 start-up hold (≥ 15 dB); after a room it is the room (≥ 20 dB).
                #expect(q.snr >= (input.count == audio.count ? 15 : 20), "\(url.lastPathComponent): \(q.snr) dB")
                #expect(q.verdict == .good && !q.lowLevel, "\(url.lastPathComponent)")
            }
        }
    }

    /// 0 dB white noise under the same speech. The energy VAD cannot find speech at 0 dB SNR (no
    /// verdict, which is honest), so the VAD hears the clean source while the analyzer measures the mix
    /// — what a VAD that works in noise (Silero) gives the live path. As recorded, the files start on
    /// the first word; "after 0.5 s of room" puts the fixture's own noise before it (key-down in a
    /// noisy room), which takes the pre-speech path.
    @Test func noisySpeechIsBelowTenDB() async throws {
        let noisy = AudioFixtures.list("noisy").filter { $0.lastPathComponent.contains("snr00db_white") }
        #expect(noisy.count == 8)
        for url in noisy {
            let name = url.lastPathComponent
            let audio = try WAVFile.read(url: url).samples
            let clean = try wav("clean", name.replacingOccurrences(of: "_snr00db_white", with: ""))
            let lead = Array(zip(audio, clean).map { $0 - $1 }.suffix(samples(0.5)))   // the fixture is clean + noise
            let runs = [("as recorded", audio, clean),
                        ("after 0.5 s of room", lead + audio, [Float](repeating: 0, count: lead.count) + clean)]
            for (label, input, heard) in runs {
                let (analyzer, verdicts) = try await replay(input, vadHears: heard)
                #expect(verdicts.count == 1, "\(name) \(label)")
                let q = try #require(verdicts.first, "\(name) \(label): no verdict")
                #expect(q.snr < 10, "\(name) \(label): \(q.snr) dB")
                #expect(q.verdict != .good, "\(name) \(label)")
                #expect(!q.lowLevel, "\(name) \(label)")
                if label != "as recorded" { #expect(analyzer.measurement?.floorSource == .preSpeech, "\(name)") }
            }
        }
    }

    /// The same speech measured three ways, with the room before it: 0 dB white < 10 dB pink < clean.
    @Test func measuredSNRFollowsTheNoise() async throws {
        for url in AudioFixtures.list("noisy").filter({ $0.lastPathComponent.contains("snr00db_white") }) {
            let clean = try wav("clean", url.lastPathComponent.replacingOccurrences(of: "_snr00db_white", with: ""))
            let silence = [Float](repeating: 0, count: samples(0.5))
            /// `mix` after 0.5 s of `room` (default: the mix's own noise, `mix − clean`).
            func measured(_ mix: [Float], room: [Float]? = nil) async throws -> Float {
                let lead = room ?? Array(zip(mix, clean).map { $0 - $1 }.suffix(samples(0.5)))
                let (_, verdicts) = try await replay(lead + mix, vadHears: silence + clean)
                return try #require(verdicts.first).snr
            }
            let white = try await measured(try WAVFile.read(url: url).samples)
            let pink = try await measured(try wav("noisy", url.lastPathComponent.replacingOccurrences(of: "snr00db_white", with: "snr10db_pink")))
            let dry = try await measured(clean, room: noise(0.5, dbfs: -70))
            #expect(white < pink && pink < dry, "\(url.lastPathComponent): \(white) / \(pink) / \(dry)")
            #expect(pink > 10, "10 dB pink (power SNR) reads above the poor bound: \(pink)")
        }
    }

    @Test func silenceGetsNoVerdict() async throws {
        let files = AudioFixtures.list("silence")
        #expect(files.count == 2)
        for url in files {
            let audio = try WAVFile.read(url: url).samples
            let (_, verdicts) = try await replay(audio)
            #expect(verdicts.isEmpty, "\(url.lastPathComponent)")
            let piped = try await pipelineVerdicts(audio)
            #expect(piped.verdicts.isEmpty && piped.last == nil, "\(url.lastPathComponent): the pipeline graded silence")
        }
    }

    /// The v1 bug end to end: 1.5 s of pause, then speech, through `AudioPipeline` and `EnergyVAD`.
    @Test func pauseThenSpeechThroughThePipelineIsNotLowLevel() async throws {
        let audio = noise(1.5, dbfs: -60) + (try wav("clean", "clean_01_samantha.wav"))
        let piped = try await pipelineVerdicts(audio)
        #expect(piped.verdicts.count == 1)
        let q = try #require(piped.verdicts.first)
        #expect(!q.lowLevel)
        #expect(q.verdict == .good)
        #expect(q.snr > 35 && q.snr < 55, "\(q.snr)")
        #expect(piped.last == q)
        let (analyzer, _) = try await replay(audio)
        #expect(analyzer.measurement?.floorSource == .preSpeech)
    }

    /// Speech under a −55 dBFS pink floor with a real pre-speech window (0.7–1.3 s).
    @Test func roomFloorFixturesUseThePreSpeechWindow() async throws {
        for name in ["vad_04_3segs_floor.wav", "vad_05_4segs_floor.wav", "vad_06_5segs_floor.wav"] {
            let (analyzer, verdicts) = try await replay(try wav("vad", name))
            #expect(verdicts.count == 1, "\(name)")
            let m = try #require(analyzer.measurement, "\(name)")
            #expect(m.floorSource == .preSpeech, "\(name)")
            #expect(m.floorDBFS < -52 && m.floorDBFS > -58, "\(name): floor \(m.floorDBFS)")
            #expect(verdicts.first?.verdict == .good && (verdicts.first?.snr ?? 0) > 30, "\(name)")
        }
    }
}
