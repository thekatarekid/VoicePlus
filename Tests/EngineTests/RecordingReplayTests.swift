import Foundation
import Testing
import Shared
@testable import Engine

/// Replays the audio saved by `UtteranceRecorder` back through the real recognizer.
///
/// This is the other half of the diagnostic: the recorder captures a dictation that came out wrong,
/// and this reads it back and says what the model actually heard. No fixture manifest to author, no
/// suite to register — point it at the folder and run it.
///
///     swift test --scratch-path .build-capture --filter replaySavedRecordings
///
/// By default it replays everything in `~/Library/Application Support/VoicePlus/Recordings`. Two
/// environment variables narrow it:
///
///     VOICEPLUS_REPLAY=/path/to/one-raw.wav          replay a single file (or another folder)
///     VOICEPLUS_REPLAY_TEXT="the quick brown fox…"   also score WER against what was really said
///
/// It prints, for each recording: the manifest (device, transport, rate, capture graph), the level
/// of the audio, the transcript of the *raw* capture and of the *processed* copy, and — with a
/// reference — the WER of each. Raw and processed disagreeing indicts the acoustic chain; both
/// being wrong on audio that sounds fine indicts the model or the microphone itself.
///
/// Skips quietly when nothing has been recorded, so it is safe to leave in the suite.
@Suite("Recording replay (real model)", .serialized)
struct RecordingReplayTests {

    static func wavs(in root: URL) -> [URL] {
        if root.pathExtension.lowercased() == "wav" { return [root] }
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "wav" }.sorted { $0.path < $1.path }
    }

    static func describeManifest(_ wav: URL) -> String? {
        let stamp = UtteranceRecorder.stamp(of: wav)
        let sidecar = wav.deletingLastPathComponent().appendingPathComponent("\(stamp).json")
        guard let data = try? Data(contentsOf: sidecar) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let m = try? decoder.decode(UtteranceRecorder.Manifest.self, from: data) else { return nil }
        return String(format: "device=%@ transport=%@ deviceRate=%.0f ch=%d | %.2fs | raw %.1f dBFS rms / %.1f peak"
                      + " | processed %.1f dBFS rms / %.1f peak | ns=%@@%.2f aec=%@ | graph: %@",
                      m.deviceName, m.transport, m.deviceSampleRate, m.inputChannels, m.seconds,
                      m.rawRMSdBFS, m.rawPeakdBFS, m.processedRMSdBFS, m.processedPeakdBFS,
                      m.noiseSuppression ? "on" : "off", Double(m.noiseSuppressionStrength), m.aec,
                      m.captureGraph ?? "-")
    }

    @Test(.timeLimit(.minutes(30)))
    func replaySavedRecordings() async throws {
        let env = ProcessInfo.processInfo.environment
        let root = env["VOICEPLUS_REPLAY"].map { URL(fileURLWithPath: $0) } ?? UtteranceRecorder.directory()
        let files = Self.wavs(in: root)
        guard !files.isEmpty else {
            print("""
                SKIPPED: nothing to replay in \(root.path).
                Turn on Settings › General › Microphone › "Save recordings of what I dictate",
                dictate the sentence that comes out wrong, then run this test again.
                """)
            return
        }
        let manager = ModelManager(maintenance: .skip)
        guard await manager.isPresent(.parakeetTDTv3) else {
            print("SKIPPED: parakeet-tdt-0.6b-v3 not on disk."); return
        }
        let final = try await RecognizerFactory.makeFinal(manager: manager)
        let reference = env["VOICEPLUS_REPLAY_TEXT"]

        for wav in files {
            let samples = try SampleAudioSource.load16k(url: wav)
            print("\n─── \(wav.lastPathComponent) ───")
            if let m = Self.describeManifest(wav) { print("  \(m)") }
            print(String(format: "  %.2fs, rms %.1f dBFS, peak %.1f dBFS",
                         Double(samples.count) / 16_000,
                         UtteranceRecorder.rmsDBFS(samples), UtteranceRecorder.peakDBFS(samples)))
            let hyp = try await final.recognize(samples).joinedText
            print("  heard: \(hyp)")
            if let reference {
                print(String(format: "  WER vs reference: %.3f", wordErrorRate(reference: reference, hypothesis: hyp)))
            }
        }
        print("\nReplayed \(files.count) file(s) from \(root.path).")
    }

    /// R1.5 · per-file scoring of the real-room corpus against `Fixtures/real-room/script.md`.
    ///
    /// Recordings are matched to script lines by timestamp order (`RealRoomCorpus`), normalised
    /// (lowercase, punctuation stripped, digit grouping removed) and scored word by word. Prints a
    /// WER row per file plus the corpus total — the total is errors/words over the whole corpus, not
    /// the mean of the rows, so one short sentence cannot dominate it.
    ///
    ///     eval "$(Scripts/bootstrap-toolchain.sh)"
    ///     swift test --scratch-path .build-r15 --filter scoreRealRoomCorpus
    ///
    /// `VOICEPLUS_CORPUS_PASS` picks another microphone pass (default `builtin`). Skips when the
    /// git-ignored WAVs are not in the checkout or the final model is not on disk.
    @Test(.timeLimit(.minutes(30)))
    func scoreRealRoomCorpus() async throws {
        let pass = ProcessInfo.processInfo.environment["VOICEPLUS_CORPUS_PASS"] ?? "builtin"
        guard let items = RealRoomCorpus.items(pass: pass) else {
            print("SKIPPED: \(pass) recordings and script.md have different counts — the timestamp-order pairing would be wrong.")
            return
        }
        guard !items.isEmpty else {
            print("SKIPPED: no recordings in Fixtures/real-room/\(pass) (the WAVs are git-ignored)."); return
        }
        let manager = ModelManager(maintenance: .skip)
        guard await manager.isPresent(.parakeetTDTv3) else {
            print("SKIPPED: parakeet-tdt-0.6b-v3 not on disk."); return
        }
        let final = try await RecognizerFactory.makeFinal(manager: manager)

        var rawTotal = RealRoomCorpus.WERCounts()
        var processedTotal = RealRoomCorpus.WERCounts()
        var rows: [String] = []
        for item in items {
            let raw = try SampleAudioSource.load16k(url: item.raw)
            let rawHyp = try await final.recognize(raw).joinedText
            let rawCounts = RealRoomCorpus.werCounts(reference: item.reference, hypothesis: rawHyp)
            rawTotal = rawTotal + rawCounts

            var processedCell = "     -"
            if let url = item.processed {
                let hyp = try await final.recognize(try SampleAudioSource.load16k(url: url)).joinedText
                let counts = RealRoomCorpus.werCounts(reference: item.reference, hypothesis: hyp)
                processedTotal = processedTotal + counts
                processedCell = String(format: "%6.3f", counts.wer)
            }
            rows.append(String(format: "%02d  %@  %6.3f  %@  %@", item.index, item.stamp,
                               rawCounts.wer, RealRoomCorpus.errorBreakdown(rawCounts), processedCell))
            print("\n─── \(item.index): \(item.stamp) ───")
            print("  said:  \(item.reference)")
            print("  heard: \(rawHyp)")
            print(String(format: "  WER %.3f (%@ of %d words)", rawCounts.wer,
                         RealRoomCorpus.errorBreakdown(rawCounts), rawCounts.referenceWords))
        }

        print("\n── real-room/\(pass) · final = \(final.name) ──")
        print("##  stamp                   rawWER  s/d/i        procWER")
        rows.forEach { print($0) }
        print(String(format: "TOTAL  %d files, %d words | raw WER %.3f (%@) | processed WER %.3f",
                     items.count, rawTotal.referenceWords, rawTotal.wer,
                     RealRoomCorpus.errorBreakdown(rawTotal), processedTotal.wer))
        #expect(rawTotal.referenceWords > 0)
    }
}
