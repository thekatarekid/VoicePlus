import Foundation

/// V5 V1/V2 — `lab eval`, `lab fetch`, `lab datasets`.
///
///     lab eval --set librispeech-test-clean --stage asr --model parakeet-tdt-v3 [--raw] [--limit N]
///              [--tags a,b] [--hyp FILE] [--gate] [--no-write]
///
/// Prints the per-condition table, writes `Lab/results/<date>-<set>-<model>.json`, prints Δ vs
/// `Lab/results/baselines.json`; with `--gate` exits 1 when Δ > +0.3. `--hyp FILE` scores a
/// hypothesis file produced by a real-model run (`ReplayBackend`) instead of a registered backend.
enum PublicEvalCLI {
    static func execute(_ command: String, _ opts: [String: String], registry: LabRegistry, eval: PublicEval,
                        transport: any DatasetTransport) async throws -> LabCLI.Output {
        switch command {
        case "datasets":
            return LabCLI.Output(exitCode: 0, text: DatasetCatalog.listing(), reports: [])
        case "fetch":
            guard let set = opts["set"] else { throw LabError.badArguments("fetch needs --set <name>") }
            let m = try await DatasetFetcher(paths: eval.paths, transport: transport).fetch(set)
            return LabCLI.Output(exitCode: 0, text: "\(set): \(m.items.count) items → \(eval.paths.cacheDirectory.appendingPathComponent(set).path)", reports: [])
        default:
            break
        }
        guard let set = opts["set"] else { throw LabError.badArguments("eval needs --set <name>") }
        guard let modelID = opts["model"] else { throw LabError.badArguments("eval needs --model <id>") }
        guard let stage = EvalStage(rawValue: opts["stage"] ?? "asr") else {
            throw LabError.badArguments("bad --stage; one of \(EvalStage.allCases.map(\.rawValue))")
        }
        let backend: any EvalBackend
        if let hyp = opts["hyp"] {
            var file = try ReplayBackend(url: URL(fileURLWithPath: hyp)).file
            file.model = modelID
            backend = ReplayBackend(file: file)
        } else if let make = registry.evalBackends[modelID] {
            backend = try make()
        } else {
            throw LabError.badArguments("unknown model '\(modelID)'; known: \(registry.evalBackends.keys.sorted()) (or pass --hyp FILE)")
        }
        let manifest = try eval.paths.loadManifest(set: set)
        let options = PublicEval.Options(stage: stage, mode: opts["raw"] == "true" ? .raw : .normalized,
                                         limit: opts["limit"].flatMap(Int.init), tags: LabCLI.list(opts["tags"]))
        let report = try await eval.run(manifest: manifest, backend: backend, options: options, baselines: Baselines.load(paths: eval.paths))
        var text = PublicEval.table(report)
        if opts["no-write"] != "true" { text += "\nwrote \(try eval.write(report).path)" }
        let gateFailed = opts["gate"] == "true" && report.baseline?.gatePassed == false
        if opts["gate"] == "true", report.baseline == nil { text += "\ngate: no baseline for (\(modelID), \(set)) — not gated" }
        return LabCLI.Output(exitCode: gateFailed ? 1 : 0, text: text, reports: [], eval: report)
    }
}
