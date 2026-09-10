import Foundation
import Testing
import Shared
@testable import Engine

/// R5.1 — the real Qwen3-ASR int8 CoreML weights against the real-room corpus.
///
/// This suite **never downloads anything** (the model is 1.2 GB) and never invents a
/// transcription. It skips, loudly and with a reason, when:
///   - the Mac is not macOS 15+ / arm64 (`RefinementAvailability`), or
///   - no complete weights directory is on disk, or
///   - `Fixtures/real-room/builtin/` has no WAVs (they are git-ignored: a fresh clone has none).
///
/// When it does run it transcribes one corpus utterance and prints its WER against
/// `Fixtures/real-room/script.md`. Set `VOICEPLUS_QWEN_WER=1` to run the whole 20-file corpus
/// (that is the R5.4 benchmark's data, printed here as a table).
@Suite("Qwen3 refinement (real weights)", .serialized)
struct Qwen3RefinementWERTests {

    // MARK: Corpus

    /// `script.md` reference lines, keyed by their two-digit number.
    static func scriptLines() throws -> [String] {
        let url = try #require(AppPaths.fixturesDirectory())
            .appendingPathComponent("real-room/script.md")
        let text = try String(contentsOf: url, encoding: .utf8)
        var lines: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.count > 3, let first = line.first, first.isNumber,
                  let space = line.firstIndex(of: " ") else { continue }
            let number = line[line.startIndex..<space]
            guard number.count == 2, Int(number) != nil else { continue }
            lines.append(line[space...].trimmingCharacters(in: .whitespaces))
        }
        return lines
    }

    /// The corpus WAVs, in recording order — which is script order (`README.md`: each line read
    /// once, in sequence), so index *i* pairs with script line *i*.
    static func corpusFiles(suffix: String = "-processed.wav") throws -> (URL, [String]) {
        let dir = try #require(AppPaths.fixturesDirectory()).appendingPathComponent("real-room/builtin")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(suffix) }
            .sorted()
        return (dir, names)
    }

    /// Skip reason, or nil when the real thing can run. Printed verbatim so a skip is never
    /// mistaken for a pass.
    static func skipReason(store: Qwen3WeightsStore) throws -> String? {
        if let reason = RefinementAvailability.unavailableReason {
            return "SKIPPED: refinement is unavailable on this Mac — \(reason)."
        }
        guard let folder = store.locate() else {
            let searched = store.searchPaths.map(\.path).joined(separator: ", ")
            return """
                SKIPPED: the Qwen3-ASR 0.6B int8 weights (1.2 GB) are not on disk. Searched: \
                \(searched). Tests never download them; install the model and re-run.
                """
        }
        let mismatched = store.verify(at: folder)
        if !mismatched.isEmpty {
            return """
                SKIPPED: the weights at \(folder.path) do not match the recorded byte counts \
                (\(mismatched.count) file(s): \(mismatched.prefix(3).joined(separator: ", "))). \
                Re-download rather than trust them.
                """
        }
        let (_, names) = try corpusFiles()
        if names.isEmpty {
            return "SKIPPED: Fixtures/real-room/builtin/ has no WAVs (they are git-ignored)."
        }
        return nil
    }

    // MARK: Tests

    @Test(.timeLimit(.minutes(30)))
    func transcribesOneRealRoomUtterance() async throws {
        let store = Qwen3WeightsStore()
        if let reason = try Self.skipReason(store: store) { print(reason); return }
        guard #available(macOS 15, *) else { print("SKIPPED: macOS 15+ only."); return }

        let folder = try #require(store.locate())
        let (dir, names) = try Self.corpusFiles()
        let script = try Self.scriptLines()
        guard names.count == script.count else {
            print("""
                SKIPPED: \(names.count) corpus WAVs but \(script.count) script lines — the \
                file-to-line pairing would be a guess, and a guessed reference is a fabricated \
                measurement.
                """)
            return
        }

        let file = names[0]
        let reference = script[0]
        let samples = try SampleAudioSource.load16k(url: dir.appendingPathComponent(file))
        #expect(!samples.isEmpty)

        let session = Qwen3RefinementSession(store: store, language: .english)
        let loadStart = Date()
        try await session.prepare()
        let loadSeconds = Date().timeIntervalSince(loadStart)

        let start = Date()
        let spans = try await session.refine(samples: samples, context: "", deadline: .seconds(600))
        let elapsed = Date().timeIntervalSince(start)

        let span = try #require(spans.first, "the model returned no span for \(file)")
        let hypothesis = spans.map(\.text).joined(separator: " ")
        let wer = wordErrorRate(reference: reference, hypothesis: hypothesis)
        let seconds = Double(samples.count) / 16_000

        print("""
            [qwen3-refine] weights: \(folder.path)
            [qwen3-refine] \(file) (\(String(format: "%.2f", seconds))s audio, load \
            \(String(format: "%.1f", loadSeconds))s, transcribe \(String(format: "%.2f", elapsed))s)
            [qwen3-refine]   ref: \(reference)
            [qwen3-refine]   hyp: \(hypothesis)
            [qwen3-refine]   WER \(String(format: "%.3f", wer))
            """)

        // Span contract, on the real path and not just the mock.
        #expect(span.provenance == [.refineQwen3])
        #expect(span.audioRange.lowerBound == 0)
        #expect(abs(span.audioRange.upperBound - seconds) < 1e-6)
        #expect(!hypothesis.trimmingCharacters(in: .whitespaces).isEmpty)
        // Not an accuracy target — R5.4 sets those. This only says the pass produced a real
        // transcription of *this* line rather than noise or a different utterance.
        #expect(wer <= 0.5, "Qwen3 refinement of \(file) looks unrelated to the script line")
    }

    /// The whole corpus, for the R5.4 table. Opt-in: 20 inferences is minutes of ANE time.
    @Test(.timeLimit(.minutes(60)))
    func corpusWER() async throws {
        guard ProcessInfo.processInfo.environment["VOICEPLUS_QWEN_WER"] == "1" else {
            print("SKIPPED corpusWER: set VOICEPLUS_QWEN_WER=1 to run all 20 utterances.")
            return
        }
        let store = Qwen3WeightsStore()
        if let reason = try Self.skipReason(store: store) { print(reason); return }
        guard #available(macOS 15, *) else { print("SKIPPED: macOS 15+ only."); return }

        let (dir, names) = try Self.corpusFiles()
        let script = try Self.scriptLines()
        guard names.count == script.count else { print("SKIPPED corpusWER: corpus/script size mismatch."); return }

        let session = Qwen3RefinementSession(store: store, language: .english)
        try await session.prepare()

        var total = 0.0
        var worst = (wer: 0.0, file: "")
        for (index, file) in names.enumerated() {
            let samples = try SampleAudioSource.load16k(url: dir.appendingPathComponent(file))
            let start = Date()
            let spans = try await session.refine(samples: samples, context: "", deadline: .seconds(600))
            let elapsed = Date().timeIntervalSince(start)
            let hyp = spans.map(\.text).joined(separator: " ")
            let wer = wordErrorRate(reference: script[index], hypothesis: hyp)
            total += wer
            if wer > worst.wer { worst = (wer, file) }
            print(String(format: "[qwen3-corpus] %@: WER %.3f (%.2fs) | %@", file, wer, elapsed, hyp))
        }
        let mean = total / Double(names.count)
        print(String(format: "[qwen3-corpus] MEAN WER %.4f over %d utterances (worst %.3f on %@)",
                     mean, names.count, worst.wer, worst.file))
        #expect(mean <= 0.5, "the whole corpus came back unrelated to the script")
    }
}
