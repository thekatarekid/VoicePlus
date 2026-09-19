import Foundation
import Testing
@testable import Engine
@testable import Shared

// F1 fix (2026-09-19). The quiet-room gate failed 2 / 20 and the same recordings read 26 dB in a
// serial run but 8 dB in a parallel one. Two causes, one suite each:
// * the energy VAD took the built-in microphone's start-up dip for the room's floor, so the room sat
//   13 dB above it and was graded as the first second of speech ("bad + low level");
// * the analyzer took its verdict — and ended its running-minimum floor — at the end of whatever block
//   the ring handed over, so a busy machine that delivered the file in one block measured a different
//   floor from the same samples.

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

/// A 200 Hz sine: every 10 ms frame has the same RMS.
private func tone(_ seconds: Double, dbfs: Float) -> [Float] {
    let amplitude = Float(pow(10, Double(dbfs) / 20)) * Float(2).squareRoot()      // sine: rms = a/√2
    return (0..<Int(seconds * 16_000)).map { amplitude * sin(2 * .pi * 200 * Float($0) / 16_000) }
}

/// A −52 dBFS room as the built-in microphone delivers it at key-down: 40 ms at −72 dBFS from 25 ms
/// (every `Fixtures/real-room/builtin` recording dips 10–20 dB below the room for 30–45 ms right
/// after capture starts).
private func roomAfterStartUpDip(_ seconds: Double) -> [Float] {
    var audio = noise(seconds, dbfs: -52)
    for (k, s) in noise(0.04, dbfs: -72, seed: 7).enumerated() where 400 + k < audio.count { audio[400 + k] = s }
    return audio
}

/// `clean_01_samantha.wav` in the same −52 dBFS room, then `tail` seconds of that room.
private func speechInTheRoom(tail: Double = 0) throws -> [Float] {
    let clean = try WAVFile.read(url: try #require(AudioFixtures.url("clean", "clean_01_samantha.wav"))).samples
    let room = noise(Double(clean.count) / 16_000, dbfs: -52, seed: 11)
    return zip(clean, room).map { $0 + $1 } + noise(tail, dbfs: -52, seed: 13)
}

// MARK: the energy VAD's floor

@Suite("F1 fix — a start-up transient is not the room's floor")
struct EnergyVADStartUpDipTests {
    /// Lines 02 and 14 of the quiet-room corpus: ~1.1 s of room, then the first word. The dip at key-down
    /// used to become the floor, and the VAD opened a segment at 0.01–0.03 s that the room held open.
    @Test func theRoomAfterAStartUpDipIsNotSpeech() async throws {
        let room = try await EnergyVAD().segments(in: roomAfterStartUpDip(3))
        #expect(room.isEmpty, "the room alone read as speech: \(room)")

        let audio = roomAfterStartUpDip(1.2) + (try speechInTheRoom())
        let spans = try await EnergyVAD().segments(in: audio)
        let first = try #require(spans.first, "the words were not heard")
        #expect(first.lowerBound > 1.0 && first.lowerBound < 1.25, "first segment \(first), first word at 1.2 s")
    }

    /// The hold is a length, not a level: a 100 ms pause is a floor, a 40 ms dip is not.
    @Test func aPauseSetsTheFloorADipDoesNot() async throws {
        for (quiet, heard) in [(0.1, true), (0.04, false)] {
            let audio = noise(1, dbfs: -40) + noise(quiet, dbfs: -65, seed: 3) + tone(0.3, dbfs: -45) + noise(0.6, dbfs: -65, seed: 5)
            let spans = try await EnergyVAD().segments(in: audio)
            // −45 dBFS is 5 dB under the −40 room, 20 dB over the −65 pause: speech only against the pause.
            #expect(spans.contains { $0.lowerBound > 0.95 && $0.lowerBound < 1.2 } == heard,
                    "\(Int(quiet * 1000)) ms at −65 dBFS: \(spans)")
        }
    }
}

// MARK: the analyzer's verdict

@Suite("F1 fix — the mic-quality verdict is a function of the samples")
struct MicQualityDeterminismTests {
    enum Step {
        case audio([Float])
        case event(VADEvent)
    }

    /// Runs `script` feeding every audio step in `chunk`-sample calls (`Int.max`: the whole step in one).
    static func run(_ script: [Step], chunk: Int) -> (verdicts: [MicQuality], measurement: MicQualityAnalyzer.Measurement?) {
        let a = MicQualityAnalyzer()
        var verdicts: [MicQuality] = []
        for step in script {
            switch step {
            case .event(let e): a.note(e)
            case .audio(let samples):
                var i = 0
                while i < samples.count {
                    let end = samples.count - i > chunk ? i + chunk : samples.count
                    if let q = a.feed(Array(samples[i..<end])) { verdicts.append(q) }
                    i = end
                }
            }
        }
        if let q = a.flush() { verdicts.append(q) }
        return (verdicts, a.measurement)
    }

    static let chunks = [1, 37, 160, 320, 800, 4_096, 48_000, Int.max]

    static func words(_ count: Int) -> [Float] {
        (0..<count).flatMap { _ in tone(0.8, dbfs: -25) + noise(0.2, dbfs: -52, seed: 17) }
    }

    /// Same samples, same events at the same samples, any split into `feed` calls: one verdict, the same.
    @Test(arguments: [
        // Words from key-down (running minimum, with the start-up dip inside its 4 s): the second of
        // speech completes inside a 6 s block. The verdict used to be taken at that block's end, with a
        // floor from that block's last 4 s: fed in one call this read 27.6 dB, in 10 ms calls 47.6.
        ("running minimum", [.audio(roomAfterStartUpDip(0.1)), .event(.speechStart(at: 0.1)),
                             .audio(words(6)), .event(.speechEnd(at: 6.1)), .audio(noise(1, dbfs: -52))]),
        // A pre-speech floor; a `speechEnd` completes the second, so the verdict is due before any
        // later audio.
        ("pre-speech, closed segments", [.audio(noise(0.5, dbfs: -55)), .event(.speechStart(at: 0.5)),
                                         .audio(tone(0.6, dbfs: -20) + noise(0.45, dbfs: -55)), .event(.speechEnd(at: 1.1)),
                                         .audio(noise(0.05, dbfs: -55) + tone(0.6, dbfs: -20) + noise(0.45, dbfs: -55)),
                                         .event(.speechStart(at: 1.6)), .event(.speechEnd(at: 2.2)),
                                         .audio(noise(3, dbfs: -55))]),
        // Words the VAD missed at key-down (missed onset), a short utterance graded at stop.
        ("missed onset, flush", [.audio(tone(0.18, dbfs: -20) + noise(0.02, dbfs: -70) + tone(0.3, dbfs: -20)),
                                 .event(.speechStart(at: 0.3)), .audio(noise(0.5, dbfs: -60)), .event(.speechEnd(at: 0.5)),
                                 .audio(noise(4, dbfs: -60))]),
    ] as [(String, [Step])])
    func theAnalyzerIgnoresHowTheAudioWasSplit(_ name: String, _ script: [Step]) throws {
        let reference = Self.run(script, chunk: 160)
        #expect(reference.verdicts.count == 1, "\(name): \(reference.verdicts)")
        _ = try #require(reference.measurement, "\(name): no measurement")
        for chunk in Self.chunks {
            let run = Self.run(script, chunk: chunk)
            #expect(run.verdicts == reference.verdicts, "\(name), \(chunk)-sample feeds: \(run.verdicts) vs \(reference.verdicts)")
            #expect(run.measurement == reference.measurement, "\(name), \(chunk)-sample feeds")
        }
    }

    /// Every `.micQuality` the real pipeline publishes, and what the last was computed from, with the
    /// fixture replayed in `block`-second blocks (nil: the whole take in one block).
    static func pipeline(_ audio: [Float], block: TimeInterval?) async throws -> (verdicts: [MicQuality], measurement: MicQualityAnalyzer.Measurement?) {
        let wav = WAVFile(sampleRate: 16_000, samples: audio)
        let source = FixtureCaptureSource(wav: wav, blockDuration: block ?? wav.duration + 1)
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
        return (await collector.value, pipeline.lastMicMeasurement)
    }

    /// The ring hands the worker whatever it holds when the pump wakes: 50 ms blocks on an idle machine,
    /// the whole take on a busy one. The verdict must not notice.
    @Test func thePipelineVerdictIgnoresBlockSize() async throws {
        let inputs = [
            ("room, then words", roomAfterStartUpDip(1.2) + (try speechInTheRoom())),
            ("words from key-down, then 4 s of room", roomAfterStartUpDip(0.06) + (try speechInTheRoom(tail: 4))),
        ]
        for (name, audio) in inputs {
            let reference = try await Self.pipeline(audio, block: 0.05)
            #expect(reference.verdicts.count == 1, "\(name): \(reference.verdicts)")
            for block in [0.01, 0.37, 2.0, nil] as [TimeInterval?] {
                let run = try await Self.pipeline(audio, block: block)
                let label = block.map { "\($0) s blocks" } ?? "one block"
                #expect(run.verdicts == reference.verdicts, "\(name), \(label): \(run.verdicts) vs \(reference.verdicts)")
                #expect(run.measurement == reference.measurement, "\(name), \(label)")
            }
        }
    }

    /// The onset case end to end: the room before the first word is the floor, the words are the signal.
    @Test func theRoomBeforeTheFirstWordIsTheFloorNotTheSignal() async throws {
        let (verdicts, measurement) = try await Self.pipeline(roomAfterStartUpDip(1.2) + (try speechInTheRoom()), block: 0.05)
        #expect(verdicts.count == 1)
        let q = try #require(verdicts.first)
        let m = try #require(measurement)
        #expect(!q.lowLevel, "speech peak \(m.speechPeakDBFS) dBFS")
        #expect(q.verdict == .good, "\(q)")
        #expect(m.floorSource == .preSpeech)
        #expect(m.floorDBFS > -56 && m.floorDBFS < -50, "floor \(m.floorDBFS) dBFS: the −52 dBFS room, not the −72 dBFS dip")
        #expect(m.signalDBFS > -35, "signal \(m.signalDBFS) dBFS: the words, not the room")
        #expect(q.snr > 20, "snr \(q.snr)")
    }
}
