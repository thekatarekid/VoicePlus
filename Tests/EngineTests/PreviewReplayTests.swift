import Foundation
import Testing
import Shared
@testable import Engine

/// R1.5 — the preview decision, measured on the real-room corpus.
///
/// Feeds every `*-raw.wav` in `Fixtures/real-room/builtin` to each preview candidate in **100 ms
/// chunks**, the way `RealEngine` feeds live capture, and records the final preview string and the
/// time to the first word. Then prints candidate × (WER, first-word p50, CPU time).
///
///     eval "$(Scripts/bootstrap-toolchain.sh)"
///     swift test --scratch-path .build-r15 --filter previewCandidateComparison
///
/// Skips when the model weights or the (git-ignored) WAVs are absent — there is no synthetic
/// substitute for either, and a made-up number is worse than no number.
@Suite("Preview candidates (real models)", .serialized)
struct PreviewReplayTests {

    /// What one file's replay through one candidate produced.
    struct Trace {
        var text = ""                    // final cumulative preview string
        var firstWordMs: Double?         // after speech onset; nil when no word ever appeared
        var cpuSeconds = 0.0             // process CPU consumed by this file's replay
        var wallSeconds = 0.0
        var audioSeconds = 0.0
    }

    /// Process CPU time (user + system, all threads) — the honest cost of a candidate, since the
    /// recognizers push work onto other threads and the ANE and a single-thread clock would miss it.
    static func processCPUSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    /// Speech onset in seconds: the first of three consecutive 20 ms frames more than 12 dB above
    /// the quietest tenth of the file. First-word latency is measured from here, because that is
    /// when the user started talking and began waiting for the pill to say something.
    static func speechOnsetSeconds(_ samples: [Float]) -> Double {
        let frame = 320                                  // 20 ms at 16 kHz
        guard samples.count > frame * 5 else { return 0 }
        var levels: [Double] = []
        var index = 0
        while index + frame <= samples.count {
            let slice = Array(samples[index ..< index + frame])
            levels.append(Double(UtteranceRecorder.rmsDBFS(slice)))
            index += frame
        }
        let floorLevel = levels.sorted()[max(0, levels.count / 10)]
        let threshold = floorLevel + 12
        var run = 0
        for (i, level) in levels.enumerated() where level.isFinite {
            run = level > threshold ? run + 1 : 0
            if run == 3 { return Double(i - 2) * Double(frame) / 16_000 }
        }
        return 0
    }

    /// The EOU candidate, or `nil` when its weights are not on disk. One instance for the whole
    /// corpus (the model loads once); `replay` resets it per utterance, as `RealEngine` does.
    static func eouPreview(_ manager: ModelManager) async -> PreviewRecognizer? {
        guard await manager.isPresent(.parakeetEOU160),
              let eou = try? await manager.load(.parakeetEOU160).eouManager else { return nil }
        return EOUPreviewRecognizer(manager: eou)
    }

    /// Feeds `samples` to `preview` in 100 ms chunks and times the first word.
    ///
    /// In production the chunk covering audio time *T* arrives at wall clock *T*, so the first word
    /// reaches the pill at `T + compute(chunk)`; the replay runs faster than real time, so latency is
    /// reconstructed as (audio time of the chunk that produced the first word − speech onset) plus
    /// that chunk's own compute time. That is exactly the delay the user sees whenever the
    /// recognizer keeps up with the audio, which both candidates do here.
    static func replay(_ samples: [Float], through preview: PreviewRecognizer,
                       chunkSeconds: Double = 0.1) async throws -> Trace {
        await preview.reset()
        let chunk = Int(chunkSeconds * 16_000)
        let onset = speechOnsetSeconds(samples)
        var trace = Trace()
        trace.audioSeconds = Double(samples.count) / 16_000
        let cpu0 = processCPUSeconds(), wall0 = Date()

        var offset = 0
        while offset < samples.count {
            let end = min(offset + chunk, samples.count)
            let t0 = Date()
            let text = try await preview.feed(Array(samples[offset ..< end]))
            let compute = Date().timeIntervalSince(t0)
            if trace.firstWordMs == nil, !text.trimmingCharacters(in: .whitespaces).isEmpty {
                let audioTime = Double(end) / 16_000
                trace.firstWordMs = max(0, audioTime - onset + compute) * 1000
            }
            if !text.isEmpty { trace.text = text }
            offset = end
        }
        trace.wallSeconds = Date().timeIntervalSince(wall0)
        trace.cpuSeconds = processCPUSeconds() - cpu0
        return trace
    }

    /// One candidate's totals over the corpus.
    struct Candidate {
        let name: String
        var counts = RealRoomCorpus.WERCounts()
        var formattedCounts = RealRoomCorpus.WERCounts()
        var firstWordMs: [Double] = []
        var cpuSeconds = 0.0
        var audioSeconds = 0.0
        var missingFirstWord = 0

        var cpuPerAudioSecond: Double { audioSeconds == 0 ? 0 : cpuSeconds / audioSeconds }
    }

    @Test(.timeLimit(.minutes(60)))
    func previewCandidateComparison() async throws {
        guard let items = RealRoomCorpus.items() else {
            print("SKIPPED: builtin recordings and script.md have different counts."); return
        }
        guard !items.isEmpty else {
            print("SKIPPED: no recordings in Fixtures/real-room/builtin (the WAVs are git-ignored)."); return
        }
        let manager = ModelManager(maintenance: .skip)
        guard await manager.isPresent(.parakeetTDTv3) else {
            print("SKIPPED: parakeet-tdt-0.6b-v3 not on disk — no final model, so no polling candidate.")
            return
        }
        let final = try await RecognizerFactory.makeFinal(manager: manager)
        let eouPreview = await Self.eouPreview(manager)
        if eouPreview == nil {
            print("NOTE: parakeet-realtime-eou-120m not on disk — the EOU candidate is skipped, not estimated.")
        }

        var eou = Candidate(name: "A · EOU 120M stream (100 ms feed)")
        var polling = Candidate(name: "B · polling TDT v3 (1 s interval)")
        var finalPass = Candidate(name: "— final TDT v3 (reference, whole utterance)")

        for item in items {
            let samples = try SampleAudioSource.load16k(url: item.raw)
            let audio = Double(samples.count) / 16_000
            print("\n─── \(item.index): \(item.stamp) · \(String(format: "%.1fs", audio)) ───")
            print("  said:      \(item.reference)")

            func describe(_ trace: Trace) -> String {
                let wer = RealRoomCorpus.werCounts(reference: item.reference, hypothesis: trace.text).wer
                let first = trace.firstWordMs.map { String(format: "%.0f ms", $0) } ?? "never"
                return String(format: "[WER %.3f, first word %@]", wer, first as NSString)
            }
            if let eouPreview {
                let trace = try await Self.replay(samples, through: eouPreview)
                Self.accumulate(&eou, trace, reference: item.reference)
                print("  preview A: \(trace.text)  \(describe(trace))")
                print("  formatted: \(PreviewFormatter.format(trace.text))")
            }
            let pollingTrace = try await Self.replay(samples, through: PollingPreviewRecognizer(recognizer: final))
            Self.accumulate(&polling, pollingTrace, reference: item.reference)
            print("  preview B: \(pollingTrace.text)  \(describe(pollingTrace))")

            // The final pass on the same audio, so the table says how much of the gap is the preview.
            let cpu0 = Self.processCPUSeconds()
            let finalText = try await final.recognize(samples).joinedText
            finalPass.cpuSeconds += Self.processCPUSeconds() - cpu0
            finalPass.audioSeconds += audio
            finalPass.counts = finalPass.counts + RealRoomCorpus.werCounts(reference: item.reference, hypothesis: finalText)
            finalPass.formattedCounts = finalPass.counts     // the final pass already formats itself
            print("  final:     \(finalText)")
        }

        print("\n╭─ R1.5 preview candidates · Fixtures/real-room/builtin · \(items.count) utterances,"
              + " \(polling.counts.referenceWords) reference words")
        print("│ " + "candidate".padded(46) + "WER    WER+fmt  first word p50  p95        CPU s per audio s")
        for c in [eou, polling, finalPass] where !(c.name.hasPrefix("A") && eouPreview == nil) {
            func latency(_ p: Double) -> String {
                c.firstWordMs.isEmpty ? "-".padded(15) : String(format: "%.0f ms", Percentiles.p(c.firstWordMs, p)).padded(15)
            }
            print("│ " + c.name.padded(46)
                  + String(format: "%.3f  %.3f    ", c.counts.wer, c.formattedCounts.wer)
                  + latency(50) + latency(95)
                  + String(format: "%.2f", c.cpuPerAudioSecond))
        }
        print("╰─ preview budget (V3 §10.2): first words p50 ≤ 300 ms after speech onset")
        print("   utterances where a candidate never produced a word: A \(eou.missingFirstWord), B \(polling.missingFirstWord)")

        #expect(polling.counts.referenceWords > 0)
        #expect(polling.firstWordMs.count + polling.missingFirstWord == items.count)
    }

    static func accumulate(_ candidate: inout Candidate, _ trace: Trace, reference: String) {
        candidate.counts = candidate.counts + RealRoomCorpus.werCounts(reference: reference, hypothesis: trace.text)
        candidate.formattedCounts = candidate.formattedCounts
            + RealRoomCorpus.werCounts(reference: reference, hypothesis: PreviewFormatter.format(trace.text))
        if let ms = trace.firstWordMs { candidate.firstWordMs.append(ms) } else { candidate.missingFirstWord += 1 }
        candidate.cpuSeconds += trace.cpuSeconds
        candidate.audioSeconds += trace.audioSeconds
    }
}

extension String {
    /// Left-aligned column padding for the printed tables.
    func padded(_ width: Int) -> String {
        count >= width ? self + " " : self + String(repeating: " ", count: width - count)
    }
}

/// Nearest-rank percentile (the Lab has its own; `EngineTests` cannot import `Lab`).
enum Percentiles {
    static func p(_ values: [Double], _ percentile: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((percentile / 100 * Double(sorted.count)).rounded(.up))
        return sorted[max(0, min(sorted.count - 1, rank - 1))]
    }
}
