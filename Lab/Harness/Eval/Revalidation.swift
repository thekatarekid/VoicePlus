import Foundation

/// V5 V4 — re-measure the provisional (rule 0.4) decisions on the V1 public-set harness:
/// preview backend (R1.5), mic-quality bounds (F1 / K6), segment-class WER (R5.4), and
/// `qwenRefinement` (D7) when its weights are on disk. Input: a (noisy) public manifest plus the
/// hypothesis files the real-model runner wrote (`hyp-<model>.json`). Output: one JSON + one
/// Markdown summary in `Lab/results/`, which `DECISIONS.md` quotes.
public struct Revalidation: Sendable {
    public struct ConditionRow: Codable, Equatable, Sendable {
        public var condition: String
        public var n: Int
        public var finalWER: Double?
        public var previewEOUWER: Double?
        public var previewPollingWER: Double?
        /// Analyzer verdict counts at this condition (good / poor / bad / none).
        public var verdicts: [String: Int]
        /// Median of the analyzer's own SNR estimate (dB).
        public var analyzerSNRMedian: Double?
    }
    public struct PreviewRow: Codable, Equatable, Sendable {
        public var model: String
        public var wer: Double
        public var firstWordP50Ms: Double
        public var firstWordP95Ms: Double
        public var neverProducedWord: Int
        public var cpuSecondsPerAudioSecond: Double?
    }
    public struct ClassRow: Codable, Equatable, Sendable {
        public var segmentClass: String
        public var n: Int
        public var wer: Double
    }
    public struct Result: Codable, Equatable, Sendable {
        public var set: String
        public var date: String
        public var hardware: String
        public var conditions: [ConditionRow]
        public var preview: [PreviewRow]
        /// Segment-class WER of the final recognizer on the clean items only.
        public var segmentClasses: [ClassRow]
        /// Bounds the analyzer would need so that conditions where final WER ≥ 2× clean are `poor`.
        public var micQualityFinding: String
        public var notes: [String]
    }

    public var paths: EvalPaths
    public var hardware: String
    public init(paths: EvalPaths = EvalPaths(), hardware: String = LabRunner.hardwareDescription()) {
        self.paths = paths; self.hardware = hardware
    }

    static func pooledWER(_ rows: [(EvalItem, EvalOutput)]) -> Double {
        var e = 0, w = 0
        for (item, out) in rows {
            let r = EvalMetrics.wer(reference: item.reference, hypothesis: out.text ?? "", mode: .normalized)
            e += r.errors; w += r.referenceWords
        }
        return w == 0 ? 0 : 100 * Double(e) / Double(w)
    }

    static func median(_ v: [Double]) -> Double? { v.isEmpty ? nil : Percentile.value(v, p: 50) }

    /// Condition key for an item: `clean`, or `<noise>@<snr>` (e.g. `babble@snr-5`).
    static func condition(_ item: EvalItem) -> String {
        let snr = item.tags.first { $0.hasPrefix("snr-") } ?? "snr-clean"
        if snr == "snr-clean" { return "clean" }
        let noise = item.tags.first { $0.hasPrefix("noise-") }.map { String($0.dropFirst("noise-".count)) } ?? "noise"
        return "\(noise)@\(snr)"
    }

    public func run(manifest: EvalManifest, hyps: [String: ReplayBackend.File], date: String) -> Result {
        func joined(_ model: String) -> [(EvalItem, EvalOutput)] {
            guard let f = hyps[model] else { return [] }
            return manifest.items.compactMap { i in f.items[i.id].map { (i, $0) } }
        }
        let final = joined("parakeet-tdt-v3"), eou = joined("preview-eou"), polling = joined("preview-polling"), mic = joined("micquality")
        let order = Dictionary(manifest.items.enumerated().map { (Self.condition($0.element), $0.offset) }, uniquingKeysWith: min)
        let conditions = Set(manifest.items.map(Self.condition)).sorted { a, b in
            func key(_ c: String) -> (String, Double) {
                guard c != "clean", let at = c.firstIndex(of: "@") else { return ("", -1_000) }
                return (String(c[..<at]), -(Double(c[c.index(at, offsetBy: 5)...]) ?? 0))
            }
            let ka = key(a), kb = key(b)
            return ka != kb ? (ka.0, ka.1) < (kb.0, kb.1) : order[a, default: 0] < order[b, default: 0]
        }
        var rows: [ConditionRow] = []
        for c in conditions {
            let f = final.filter { Self.condition($0.0) == c }, e = eou.filter { Self.condition($0.0) == c }
            let p = polling.filter { Self.condition($0.0) == c }, m = mic.filter { Self.condition($0.0) == c }
            var verdicts: [String: Int] = [:]
            for (_, o) in m { verdicts[o.label ?? "none", default: 0] += 1 }
            rows.append(ConditionRow(condition: c, n: manifest.items.filter { Self.condition($0) == c }.count,
                                     finalWER: f.isEmpty ? nil : Self.pooledWER(f), previewEOUWER: e.isEmpty ? nil : Self.pooledWER(e),
                                     previewPollingWER: p.isEmpty ? nil : Self.pooledWER(p), verdicts: verdicts,
                                     analyzerSNRMedian: Self.median(m.compactMap { $0.1.metrics?["snrDB"] })))
        }

        var preview: [PreviewRow] = []
        for (model, rowsP) in [("preview-eou", eou), ("preview-polling", polling)] where !rowsP.isEmpty {
            let lat = rowsP.compactMap { $0.1.latencyMs }
            let cpu = rowsP.compactMap { $0.1.metrics?["cpuSeconds"] }.reduce(0, +)
            let secs = rowsP.compactMap { $0.1.audioSeconds }.reduce(0, +)
            preview.append(PreviewRow(model: model, wer: Self.pooledWER(rowsP), firstWordP50Ms: Percentile.value(lat, p: 50),
                                      firstWordP95Ms: Percentile.value(lat, p: 95), neverProducedWord: rowsP.count - lat.count,
                                      cpuSecondsPerAudioSecond: secs > 0 ? cpu / secs : nil))
        }
        if !final.isEmpty {
            preview.append(PreviewRow(model: "parakeet-tdt-v3 (final, reference)", wer: Self.pooledWER(final),
                                      firstWordP50Ms: 0, firstWordP95Ms: 0, neverProducedWord: 0, cpuSecondsPerAudioSecond: nil))
        }

        let classifier = SegmentClassifier()
        let cleanFinal = final.filter { Self.condition($0.0) == "clean" }
        var classes: [ClassRow] = []
        for sc in SegmentClass.reportingOrder {
            let inClass = cleanFinal.filter { classifier.classify(reference: $0.0.reference, seconds: $0.1.audioSeconds).contains(sc) }
            if !inClass.isEmpty { classes.append(ClassRow(segmentClass: sc.label, n: inClass.count, wer: Self.pooledWER(inClass))) }
        }

        var finding = "no final / mic-quality hypotheses"
        if let clean = rows.first(where: { $0.condition == "clean" })?.finalWER, !mic.isEmpty {
            let degraded = rows.filter { $0.condition != "clean" && ($0.finalWER ?? 0) >= max(2 * clean, clean + 2) }
            let fine = rows.filter { $0.condition != "clean" && ($0.finalWER ?? 0) < max(2 * clean, clean + 2) }
            let flagged = degraded.map { Double(($0.verdicts["poor"] ?? 0) + ($0.verdicts["bad"] ?? 0)) / Double(max(1, $0.verdicts.values.reduce(0, +))) }
            let falseAlarm = fine.map { Double(($0.verdicts["poor"] ?? 0) + ($0.verdicts["bad"] ?? 0)) / Double(max(1, $0.verdicts.values.reduce(0, +))) }
            let degradedSNR = degraded.compactMap(\.analyzerSNRMedian), fineSNR = fine.compactMap(\.analyzerSNRMedian)
            finding = String(format: "WER ≥ 2× clean (%.2f%%) in %d/%d noisy conditions; current bounds flag %.0f%% of those utterances poor/bad and %.0f%% of the conditions that stay near clean. Analyzer SNR median: degraded max %@ dB, near-clean min %@ dB.",
                             clean, degraded.count, rows.count - 1,
                             100 * (flagged.isEmpty ? 0 : flagged.reduce(0, +) / Double(flagged.count)),
                             100 * (falseAlarm.isEmpty ? 0 : falseAlarm.reduce(0, +) / Double(falseAlarm.count)),
                             degradedSNR.max().map { String(format: "%.1f", $0) } ?? "–", fineSNR.min().map { String(format: "%.1f", $0) } ?? "–")
        }
        var notes = ["SNR = whole-utterance power ratio of the V3 mix (Kaldi convention); the analyzer estimates p90 speech frames over p10 floor, so its dB read higher."]
        if hyps["qwen3-refinement"] == nil {
            notes.append("qwenRefinement not re-measured: Qwen3-ASR 0.6B int8 weights (1.2 GB) are not on disk and the disk budget forbids the download → T1.")
        }
        return Result(set: manifest.set, date: date, hardware: hardware, conditions: rows, preview: preview,
                      segmentClasses: classes, micQualityFinding: finding, notes: notes)
    }

    public static func markdown(_ r: Result) -> String {
        func f(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "–" }
        var l = ["# V4 re-validation — \(r.set) · \(r.date) · \(r.hardware)", "",
                 "| condition | n | final WER % | preview EOU WER % | preview polling WER % | analyzer good/poor/bad | analyzer SNR median dB |",
                 "|---|---|---|---|---|---|---|"]
        for c in r.conditions {
            l.append("| \(c.condition) | \(c.n) | \(f(c.finalWER)) | \(f(c.previewEOUWER)) | \(f(c.previewPollingWER)) | \(c.verdicts["good"] ?? 0)/\(c.verdicts["poor"] ?? 0)/\(c.verdicts["bad"] ?? 0)\((c.verdicts["none"] ?? 0) > 0 ? " (+\(c.verdicts["none"]!) none)" : "") | \(f(c.analyzerSNRMedian)) |")
        }
        l += ["", "| preview | WER % (all conditions) | first word p50 ms | p95 ms | never a word | CPU s / audio s |", "|---|---|---|---|---|---|"]
        for p in r.preview {
            l.append("| \(p.model) | \(f(p.wer)) | \(Int(p.firstWordP50Ms)) | \(Int(p.firstWordP95Ms)) | \(p.neverProducedWord) | \(f(p.cpuSecondsPerAudioSecond)) |")
        }
        l += ["", "| segment class (clean, final) | n | WER % |", "|---|---|---|"]
        for c in r.segmentClasses { l.append("| \(c.segmentClass) | \(c.n) | \(f(c.wer)) |") }
        l += ["", "mic quality: \(r.micQualityFinding)"]
        for n in r.notes { l.append("note: \(n)") }
        return l.joined(separator: "\n")
    }

    /// Writes `Lab/results/v4-revalidation-<set>.{json,md}`.
    @discardableResult
    public func write(_ r: Result) throws -> URL {
        try FileManager.default.createDirectory(at: paths.resultsDirectory, withIntermediateDirectories: true)
        let base = paths.resultsDirectory.appendingPathComponent("v4-revalidation-\(r.set)")
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(r).write(to: base.appendingPathExtension("json"))
        try Self.markdown(r).write(to: base.appendingPathExtension("md"), atomically: true, encoding: .utf8)
        return base.appendingPathExtension("md")
    }
}
