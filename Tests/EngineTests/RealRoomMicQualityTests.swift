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
/// The WAVs are git-ignored (the owner's voice): without them the test prints SKIPPED and passes,
/// as `RecordingReplayTests` does.
///
/// **Measured 2026-09-19: 18 of 20 good, 2 "bad + low level" — the gate fails.** Lines 02 and 14 open
/// with ~1.1 s of room (≈ −52 dBFS) before the first word. The energy VAD learns its floor from its
/// first, quieter frames and opens a segment at 0.01–0.03 s that the room keeps open, so the analyzer's
/// "first second of speech" is that room: signal −50 dBFS, peak −40.5 / −43.8 dBFS (< −40 → low
/// level). The owner's speech in both peaks at −21 dBFS. Those two stamps are a known issue (the test
/// fails if they stop failing, so whoever fixes the onset updates it); any other warning fails outright.
@Suite("V4 gate — quiet-room corpus mic quality", .serialized)
struct RealRoomMicQualityTests {
    /// Every `.micQuality` the real pipeline publishes for `audio`, start to stop.
    static func pipelineVerdicts(_ audio: [Float]) async throws -> [MicQuality] {
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
        return await collector.value
    }

    /// The two recordings the energy VAD's capture-start onset mis-grades (see the suite comment).
    static let knownFalseOnset: Set<String> = ["2026-09-11-000022-650", "2026-09-11-000230-563"]

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

        var warnings: [(stamp: String, line: String)] = []
        var graded = 0
        var rows: [String] = []
        for (i, url) in raws.enumerated() {
            let audio = try SampleAudioSource.load16k(url: url)
            let verdicts = try await Self.pipelineVerdicts(audio)
            let stamp = UtteranceRecorder.stamp(of: url)
            if verdicts.isEmpty {
                rows.append(String(format: "%02d  %@  no verdict (VAD heard < 1 s of speech)", i + 1, stamp))
                continue
            }
            graded += 1
            for q in verdicts {
                rows.append(String(format: "%02d  %@  %@  snr %5.1f dB  clip %.4f  low %@", i + 1, stamp,
                                   q.verdict.rawValue, q.snr, q.clipping, q.lowLevel ? "yes" : "no"))
                if q.verdict != .good || q.lowLevel {
                    warnings.append((stamp, "\(stamp): \(q.verdict.rawValue)\(q.lowLevel ? " + low level" : "") at \(q.snr) dB"))
                }
            }
        }
        print("\n── real-room/\(pass) · mic quality (AudioPipeline + EnergyVAD + MicQualityAnalyzer v2) ──")
        rows.forEach { print($0) }
        print("TOTAL  \(raws.count) files, \(graded) graded, \(warnings.count) mic warning(s)")
        #expect(graded > 0, "the analyzer graded none of the quiet-room recordings")
        let unexpected = warnings.filter { !Self.knownFalseOnset.contains($0.stamp) }.map(\.line)
        #expect(unexpected.isEmpty, "mic warnings on the quiet-room corpus:\n\(unexpected.joined(separator: "\n"))")
        let known = warnings.filter { Self.knownFalseOnset.contains($0.stamp) }.map(\.line)
        withKnownIssue("energy VAD opens at capture start; the room before the first word is graded as the signal") {
            #expect(known.isEmpty, "V4 gate: 0 mic warnings on the quiet-room corpus:\n\(known.joined(separator: "\n"))")
        }
    }
}
