import Foundation
import Testing
@testable import Lab

/// V5 B4 — error pairs from V1 runs.
@Suite("B4 error pairs")
struct ErrorPairsTests {
    @Test func alignEdits() {
        let e = ErrorPairs.align(reference: ["the", "cat", "sat", "down"], hypothesis: ["a", "cat", "sat", "down", "now"])
        #expect(e == [WordEdit(op: .sub, ref: "the", hyp: "a"), WordEdit(op: .ins, ref: nil, hyp: "now")])
        #expect(ErrorPairs.align(reference: ["x", "y"], hypothesis: ["y"]) == [WordEdit(op: .del, ref: "x", hyp: nil)])
        #expect(ErrorPairs.align(reference: ["same"], hypothesis: ["same"]).isEmpty)
    }

    @Test func pairsFromReplayRunAndJSONL() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("b4-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let manifest = EvalManifest(set: "toy", audioRoot: "/", items: [
            EvalItem(id: "a", reference: "Mister Smith went home.", tags: ["snr-clean"]),
            EvalItem(id: "b", reference: "It rained on the harbour", tags: ["snr-5", "noise-babble"]),
        ])
        let replay = ReplayBackend(file: .init(model: "m1", set: "toy", items: [
            "a": EvalOutput(text: "mr smith went home"),           // normaliser: identical → no pair
            "b": EvalOutput(text: "it rained on the harper"),
        ]))
        let paths = EvalPaths(cacheDirectory: tmp, fixturesDirectory: nil, resultsDirectory: tmp)
        let report = try await PublicEval(paths: paths).run(manifest: manifest, backend: replay)
        let pairs = ErrorPairs.pairs(report: report, manifest: manifest)
        #expect(pairs.count == 1)
        let p = try #require(pairs.first)
        #expect(p.id == "b" && p.tags == ["snr-5", "noise-babble"] && p.model == "m1")
        #expect(p.edits == [WordEdit(op: .sub, ref: "harbor", hyp: "harper")])
        #expect(p.errors == 1 && p.referenceWords == 5)

        let url = try ErrorPairs.write(pairs, set: "toy", model: "m1", paths: paths)
        #expect(url.path.hasSuffix("error-pairs/toy.jsonl"))
        var other = p; other.model = "m2"
        try ErrorPairs.write([other], set: "toy", model: "m2", paths: paths)
        try ErrorPairs.write(pairs, set: "toy", model: "m1", paths: paths)   // replaces m1, keeps m2
        let back = try ErrorPairs.read(url)
        #expect(back.count == 2 && Set(back.map(\.model)) == ["m1", "m2"])
        #expect(ErrorPairs.topConfusions(back).first! == ("harbor→harper", 2))
    }

    @Test func cliPairs() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("b4cli-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let m = EvalManifest(set: "toy", audioRoot: "/", items: [EvalItem(id: "a", audio: "a.wav", reference: "red green blue")])
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("toy"), withIntermediateDirectories: true)
        try JSONEncoder().encode(m).write(to: tmp.appendingPathComponent("toy/manifest.json"))
        let hyp = tmp.appendingPathComponent("hyp.json")
        try JSONEncoder().encode(ReplayBackend.File(model: "x", set: "toy", items: ["a": EvalOutput(text: "red grin blue")])).write(to: hyp)
        let ev = PublicEval(paths: EvalPaths(cacheDirectory: tmp, fixturesDirectory: nil, resultsDirectory: tmp.appendingPathComponent("results")))
        let out = await LabCLI.main(["pairs", "--set", "toy", "--model", "parakeet-tdt-v3", "--hyp", hyp.path], eval: ev)
        #expect(out.exitCode == 0, "\(out.text)")
        #expect(out.text.contains("green→grin ×1"))
        let lines = try ErrorPairs.read(tmp.appendingPathComponent("results/error-pairs/toy.jsonl"))
        #expect(lines.count == 1 && lines[0].model == "parakeet-tdt-v3")
        // `pairs` does not write the dated report
        #expect(!FileManager.default.fileExists(atPath: tmp.appendingPathComponent("results/\(out.eval!.date)-toy-parakeet-tdt-v3.json").path))
    }
}

/// Opt-in: `VOICEPLUS_EVAL_PAIRS=<set>` writes `Lab/results/error-pairs/<set>.jsonl` from
/// `<cache>/<set>/hyp-parakeet-tdt-v3.json` (a V1 real-model run).
@Suite("B4 error pairs (opt-in)", .serialized)
struct ErrorPairsAcceptanceTests {
    @Test func pairsIfRequested() async throws {
        guard let set = ProcessInfo.processInfo.environment["VOICEPLUS_EVAL_PAIRS"], !set.isEmpty else { return }
        let hyp = EvalPaths().cacheDirectory.appendingPathComponent("\(set)/hyp-parakeet-tdt-v3.json").path
        let out = await LabCLI.main(["pairs", "--set", set, "--model", "parakeet-tdt-v3", "--hyp", hyp])
        print(out.text.split(separator: "\n").suffix(2).joined(separator: "\n"))
        #expect(out.exitCode == 0)
    }
}
