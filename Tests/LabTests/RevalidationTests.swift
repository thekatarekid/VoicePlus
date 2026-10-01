import Foundation
import Testing
@testable import Lab

/// V5 V4 — re-validation tables from replayed hypotheses (synthetic here; real run is opt-in).
@Suite("V4 re-validation")
struct RevalidationTests {
    static let manifest = EvalManifest(set: "toy-noisy", audioRoot: "/", items: [
        EvalItem(id: "a", audio: "/a.wav", reference: "the quick brown fox jumps", tags: ["clean-read", "snr-clean"]),
        EvalItem(id: "a@babble-snr-10", audio: "x.wav", reference: "the quick brown fox jumps", tags: ["clean-read", "snr-10", "noise-babble"]),
        EvalItem(id: "a@babble-snr-0", audio: "y.wav", reference: "the quick brown fox jumps", tags: ["clean-read", "snr-0", "noise-babble"]),
    ])

    static func file(_ model: String, _ items: [String: EvalOutput]) -> ReplayBackend.File {
        .init(model: model, set: "toy-noisy", items: items)
    }

    static let hyps: [String: ReplayBackend.File] = [
        "parakeet-tdt-v3": file("parakeet-tdt-v3", [
            "a": EvalOutput(text: "the quick brown fox jumps", audioSeconds: 2),
            "a@babble-snr-10": EvalOutput(text: "the quick brown fox jumps", audioSeconds: 2),
            "a@babble-snr-0": EvalOutput(text: "a quick brow fox", audioSeconds: 2),
        ]),
        "preview-polling": file("preview-polling", [
            "a": EvalOutput(text: "the quick brown fox jumps", latencyMs: 800, audioSeconds: 2, metrics: ["cpuSeconds": 0.2]),
            "a@babble-snr-10": EvalOutput(text: "the quick brown fox", latencyMs: 900, audioSeconds: 2, metrics: ["cpuSeconds": 0.2]),
            "a@babble-snr-0": EvalOutput(text: "", latencyMs: nil, audioSeconds: 2, metrics: ["cpuSeconds": 0.2]),
        ]),
        "micquality": file("micquality", [
            "a": EvalOutput(label: "good", metrics: ["snrDB": 40]),
            "a@babble-snr-10": EvalOutput(label: "good", metrics: ["snrDB": 22]),
            "a@babble-snr-0": EvalOutput(label: "good", metrics: ["snrDB": 12]),
        ]),
    ]

    @Test func tablesAndFinding() {
        let r = Revalidation(hardware: "test").run(manifest: Self.manifest, hyps: Self.hyps, date: "2026-10-01")
        #expect(r.conditions.map(\.condition) == ["clean", "babble@snr-10", "babble@snr-0"])
        #expect(r.conditions[0].finalWER == 0)
        #expect(r.conditions[2].finalWER == 60)                     // sub, sub, del → 3/5
        #expect(r.conditions[1].previewPollingWER == 20)
        #expect(r.conditions[2].verdicts == ["good": 1])
        #expect(r.conditions[2].analyzerSNRMedian == 12)
        let polling = try! #require(r.preview.first { $0.model == "preview-polling" })
        #expect(polling.neverProducedWord == 1)
        #expect(polling.firstWordP50Ms == 800)
        #expect(abs(polling.cpuSecondsPerAudioSecond! - 0.1) < 1e-9)
        #expect(r.preview.contains { $0.model == "preview-eou" } == false)
        #expect(r.segmentClasses.contains { $0.segmentClass == "< 5 s" && $0.n == 1 })
        #expect(r.micQualityFinding.contains("1/2 noisy conditions"))
        #expect(r.micQualityFinding.contains("flag 0%"))
        #expect(r.notes.contains { $0.contains("qwenRefinement not re-measured") })
        let md = Revalidation.markdown(r)
        #expect(md.contains("| babble@snr-0 | 1 | 60.00 |"))
    }

    @Test func cliRevalidateWritesResults() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("v4-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dir = tmp.appendingPathComponent("toy-noisy")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(Self.manifest).write(to: dir.appendingPathComponent("manifest.json"))
        for (m, f) in Self.hyps { try JSONEncoder().encode(f).write(to: dir.appendingPathComponent("hyp-\(m).json")) }
        let ev = PublicEval(paths: EvalPaths(cacheDirectory: tmp, fixturesDirectory: nil, resultsDirectory: tmp.appendingPathComponent("results")),
                            hardware: "test")
        let out = await LabCLI.main(["revalidate", "--set", "toy-noisy"], eval: ev)
        #expect(out.exitCode == 0, "\(out.text)")
        #expect(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("results/v4-revalidation-toy-noisy.json").path))
        #expect(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("results/v4-revalidation-toy-noisy.md").path))
    }
}

/// Opt-in real run: `VOICEPLUS_EVAL_V4=librispeech-test-clean-noisy` after `EvalPublicSetTests` wrote
/// the hyp files → scores the final model per condition (+ `--pairs`, B4) and writes the V4 tables.
@Suite("V4 re-validation (opt-in)", .serialized)
struct RevalidationAcceptanceTests {
    @Test func revalidateIfRequested() async throws {
        guard let set = ProcessInfo.processInfo.environment["VOICEPLUS_EVAL_V4"], !set.isEmpty else { return }
        let hyp = EvalPaths().cacheDirectory.appendingPathComponent("\(set)/hyp-parakeet-tdt-v3.json").path
        let eval = await LabCLI.main(["eval", "--set", set, "--model", "parakeet-tdt-v3", "--hyp", hyp, "--pairs"])
        print(eval.text)
        #expect(eval.exitCode == 0)
        let out = await LabCLI.main(["revalidate", "--set", set])
        print(out.text)
        #expect(out.exitCode == 0)
    }
}
