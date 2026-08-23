import Foundation
import Testing
import Shared
@testable import Engine

/// Word error rate (Levenshtein over lowercased, punctuation-stripped words).
func wordErrorRate(reference: String, hypothesis: String) -> Double {
    func words(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted).filter { !$0.isEmpty }
    }
    let r = words(reference), h = words(hypothesis)
    guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
    var prev = Array(0...h.count)
    for i in 1...r.count {
        var cur = [i] + [Int](repeating: 0, count: h.count)
        for j in stride(from: 1, through: h.count, by: 1) where h.count > 0 {
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1))
        }
        prev = cur
    }
    return Double(prev[h.count]) / Double(r.count)
}

struct FixtureEntry: Decodable { let file: String; let transcript: String }

/// Golden transcripts on Fixtures/audio/clean with the real Parakeet TDT v3 model.
/// Skipped unless the model is on disk (VoicePlus or FluidAudio cache); set
/// VOICEPLUS_LIVE_MODELS=1 to download (~500 MB) and run.
@Suite("Golden transcript (real model)", .serialized)
struct ASRGoldenTranscriptTests {
    @Test func wer() {
        #expect(wordErrorRate(reference: "Hey, just checking in.", hypothesis: "hey just checking in") == 0)
        #expect(abs(wordErrorRate(reference: "a b c d", hypothesis: "a x c") - 0.5) < 1e-9)
    }

    @Test(.timeLimit(.minutes(30)))
    func cleanSuiteWithParakeetTDTv3() async throws {
        let manager = ModelManager()
        let live = ProcessInfo.processInfo.environment["VOICEPLUS_LIVE_MODELS"] == "1"
        if await !manager.isPresent(.parakeetTDTv3) {
            guard live else {
                print("SKIPPED: parakeet-tdt-0.6b-v3 not on disk. Set VOICEPLUS_LIVE_MODELS=1 to download (~500 MB) and run the golden test.")
                return
            }
            try await manager.ensureAvailable(.parakeetTDTv3) { p in print("download \(Int(p.fraction * 100))%") }
        }
        let fixtures = try #require(AppPaths.fixturesDirectory()).appendingPathComponent("audio/clean")
        let entries = try JSONDecoder().decode([FixtureEntry].self, from: Data(contentsOf: fixtures.appendingPathComponent("manifest.json")))
        let final = try await RecognizerFactory.makeFinal(manager: manager)
        #expect(final.name == "fluidaudio.tdt.v3")

        var totalWER = 0.0
        var maxLatency = 0.0
        for e in entries {
            let samples = try SampleAudioSource.load16k(url: fixtures.appendingPathComponent(e.file))
            let t0 = Date()
            let spans = try await final.recognize(samples)
            let latency = Date().timeIntervalSince(t0)
            maxLatency = max(maxLatency, latency)
            let hyp = spans.joinedText
            let wer = wordErrorRate(reference: e.transcript, hypothesis: hyp)
            totalWER += wer
            print(String(format: "%@: WER %.3f  latency %.0f ms  conf %.2f  | %@", e.file, wer, latency * 1000, WordConfidence.utteranceConfidence(spans), hyp))
            #expect(!spans.isEmpty)
            #expect(spans.allSatisfy { $0.provenance == [.asr] && $0.audioRange.upperBound <= Double(samples.count) / 16_000 + 0.5 })
            #expect(wer <= 0.25, "WER too high for \(e.file): \(hyp)")
        }
        let mean = totalWER / Double(entries.count)
        print(String(format: "MEAN WER over %d clean fixtures: %.3f; max final-pass latency %.0f ms", entries.count, mean, maxLatency * 1000))
        #expect(mean <= 0.10)
    }
}
