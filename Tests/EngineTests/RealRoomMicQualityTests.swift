import Foundation
import Testing
@testable import Engine
@testable import Shared

/// V4 Wave 1 gate "0 mic warnings on the quiet-room corpus" (build doc §4): every `*-raw.wav` of
/// `Fixtures/real-room/builtin` (one quiet-room pass of the script on the built-in microphone) goes
/// through the real `AudioPipeline` — `FixtureCaptureSource` at 16 kHz, the energy VAD, and
/// MicQualityAnalyzer v2 inside `process()` — exactly as `MicQualityFixtureTests` drives the
/// synthetic fixtures. Any verdict but `.good` (poor, bad or low level) is a mic warning the pill
/// would have shown on a recording the owner made in a quiet room.
///
/// Each recording is replayed three times — 50 ms blocks, 10 ms blocks, the whole take in one block —
/// and the three verdicts and measurements must be identical: the ring hands the worker whatever it
/// holds when the pump wakes, so a busy machine sees the big blocks.
///
/// The WAVs are git-ignored (the owner's voice): without them the test prints SKIPPED and passes,
/// as `RecordingReplayTests` does.
///
/// **History.** Measured 2026-09-19 at 50fa1c8: 18 of 20 good, lines 02 and 14 "bad + low level", and
/// the same two read 26.1 / 24.5 dB in a serial run but 7.9 / 8.3 dB in a parallel one. Every
/// recording dips 10–20 dB below the room for 30–45 ms right after capture starts; the energy VAD took
/// that dip as its floor for 4 s, the −52 dBFS room then sat 13 dB above it, and a segment opened at
/// 0.01–0.15 s on 18 of the 20. Lines 02 and 14 wait ~1.1 s before the first word, so their "first
/// second of speech" was room (peak −40.5 / −43.8 dBFS < −40: low level). Separately the analyzer took
/// its verdict at the end of whatever block carried the second of speech, with a running-minimum floor
/// over that block's last 4 s — the whole file's, when the pump handed it over at once. Fixed by the
/// VAD's floor hold (`EnergyVAD.floorHold`) and by feeding the analyzer one VAD frame at a time with
/// its verdict taken at the exact frame (`MicQualityDeterminismTests`). After: 20 of 20 good.
@Suite("V4 gate — quiet-room corpus mic quality", .serialized)
struct RealRoomMicQualityTests {
    /// Every `.micQuality` the real pipeline publishes for `audio`, start to stop, and what the last was
    /// computed from; replayed in `block`-second blocks (nil: the whole take in one).
    static func pipelineVerdicts(_ audio: [Float], block: TimeInterval? = 0.05) async throws -> (verdicts: [MicQuality], measurement: MicQualityAnalyzer.Measurement?) {
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

    @Test(.timeLimit(.minutes(10)))
    func quietRoomCorpusRaisesNoMicWarning() async throws {
        let pass = "builtin"
        guard let root = RealRoomCorpus.root() else {
            print("SKIPPED: Fixtures/ not found."); return
        }
        let raws = RealRoomCorpus.rawRecordings(in: root.appendingPathComponent(pass, isDirectory: true))
        guard !raws.isEmpty else {
            print("SKIPPED: no recordings in Fixtures/real-room/\(pass) (the WAVs are git-ignored)."); return
        }

        var warnings: [String] = []
        var unstable: [String] = []
        var graded = 0
        var rows: [String] = []
        for (i, url) in raws.enumerated() {
            let audio = try SampleAudioSource.load16k(url: url)
            let stamp = UtteranceRecorder.stamp(of: url)
            let (verdicts, measurement) = try await Self.pipelineVerdicts(audio)
            for block in [0.01, nil] as [TimeInterval?] {
                let other = try await Self.pipelineVerdicts(audio, block: block)
                if other.verdicts != verdicts || other.measurement != measurement {
                    unstable.append("\(stamp), \(block.map { "\($0) s blocks" } ?? "one block"): \(other.verdicts) vs \(verdicts)")
                }
            }
            if verdicts.isEmpty {
                rows.append(String(format: "%02d  %@  no verdict (VAD heard < 1 s of speech)", i + 1, stamp))
                continue
            }
            graded += 1
            for q in verdicts {
                let m = measurement
                rows.append(String(format: "%02d  %@  %@  snr %5.1f dB  clip %.4f  low %@  floor %6.1f (%@)  signal %6.1f  peak %6.1f dBFS",
                                   i + 1, stamp, q.verdict.rawValue, q.snr, q.clipping, q.lowLevel ? "yes" : "no",
                                   m?.floorDBFS ?? .nan, m.map { "\($0.floorSource)" } ?? "-",
                                   m?.signalDBFS ?? .nan, m?.speechPeakDBFS ?? .nan))
                if q.verdict != .good || q.lowLevel {
                    warnings.append("\(stamp): \(q.verdict.rawValue)\(q.lowLevel ? " + low level" : "") at \(q.snr) dB")
                }
            }
        }
        print("\n── real-room/\(pass) · mic quality (AudioPipeline + EnergyVAD + MicQualityAnalyzer v2) ──")
        rows.forEach { print($0) }
        print("TOTAL  \(raws.count) files, \(graded) graded, \(warnings.count) mic warning(s), \(unstable.count) block-size difference(s)")
        #expect(graded > 0, "the analyzer graded none of the quiet-room recordings")
        #expect(warnings.isEmpty, "V4 gate: 0 mic warnings on the quiet-room corpus:\n\(warnings.joined(separator: "\n"))")
        #expect(unstable.isEmpty, "the verdict depends on how the audio was blocked:\n\(unstable.joined(separator: "\n"))")
    }
}
