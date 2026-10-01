import Foundation

/// V5 B4 — hypothesis ↔ reference error pairs from V1 runs, for evaluation only (never training,
/// never shipped). One JSON line per utterance the model got wrong, with its condition tags and the
/// aligned word edits, in `Lab/results/error-pairs/<set>.jsonl`. Re-running a (set, model) replaces
/// that model's lines and keeps other models'.
public struct WordEdit: Codable, Equatable, Sendable {
    public enum Op: String, Codable, Sendable { case sub, del, ins }
    public var op: Op
    public var ref: String?
    public var hyp: String?
    public init(op: Op, ref: String?, hyp: String?) { self.op = op; self.ref = ref; self.hyp = hyp }
}

public struct ErrorPair: Codable, Equatable, Sendable {
    public var set: String
    public var model: String
    public var id: String
    public var tags: [String]
    public var reference: String
    public var hypothesis: String
    public var errors: Int
    public var referenceWords: Int
    public var edits: [WordEdit]
}

public enum ErrorPairs {
    /// Word edits on Open-ASR-normalised words (same normaliser as the report's WER).
    public static func align(reference: [String], hypothesis: [String]) -> [WordEdit] {
        let r = reference, h = hypothesis, n = r.count, m = h.count
        var d = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { d[i][0] = i }
        for j in 0...m { d[0][j] = j }
        if n > 0, m > 0 {
            for i in 1...n { for j in 1...m {
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1))
            } }
        }
        var edits: [WordEdit] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0, d[i][j] == d[i - 1][j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1) {
                if r[i - 1] != h[j - 1] { edits.append(WordEdit(op: .sub, ref: r[i - 1], hyp: h[j - 1])) }
                i -= 1; j -= 1
            } else if i > 0, d[i][j] == d[i - 1][j] + 1 {
                edits.append(WordEdit(op: .del, ref: r[i - 1], hyp: nil)); i -= 1
            } else {
                edits.append(WordEdit(op: .ins, ref: nil, hyp: h[j - 1])); j -= 1
            }
        }
        return edits.reversed()
    }

    /// Pairs for every item of an ASR report with at least one word error.
    public static func pairs(report: EvalReport, manifest: EvalManifest) -> [ErrorPair] {
        let refs = Dictionary(manifest.items.map { ($0.id, $0.reference) }, uniquingKeysWith: { a, _ in a })
        return report.items.compactMap { item in
            guard let ref = refs[item.id] else { return nil }
            let hyp = item.hypothesis ?? ""
            let rw = OpenASRNormalizer.words(ref, mode: report.normalizer), hw = OpenASRNormalizer.words(hyp, mode: report.normalizer)
            let edits = align(reference: rw, hypothesis: hw)
            guard !edits.isEmpty else { return nil }
            return ErrorPair(set: report.set, model: report.model, id: item.id, tags: item.tags, reference: ref, hypothesis: hyp,
                             errors: edits.count, referenceWords: rw.count, edits: edits)
        }
    }

    public static func url(set: String, paths: EvalPaths) -> URL {
        paths.resultsDirectory.appendingPathComponent("error-pairs/\(set).jsonl")
    }

    /// Writes `<results>/error-pairs/<set>.jsonl`, replacing lines from the same model.
    @discardableResult
    public static func write(_ pairs: [ErrorPair], set: String, model: String, paths: EvalPaths) throws -> URL {
        let url = url(set: set, paths: paths)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let kept = try read(url).filter { $0.model != model }
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let lines = try (kept + pairs.sorted { $0.id < $1.id }).map { String(decoding: try enc.encode($0), as: UTF8.self) }
        try (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    public static func read(_ url: URL) throws -> [ErrorPair] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let dec = JSONDecoder()
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { try dec.decode(ErrorPair.self, from: Data($0.utf8)) }
    }

    /// Most frequent substitutions (ref→hyp), for the summary line.
    public static func topConfusions(_ pairs: [ErrorPair], limit: Int = 10) -> [(String, Int)] {
        var c: [String: Int] = [:]
        for p in pairs { for e in p.edits {
            let key: String
            switch e.op {
            case .sub: key = "\(e.ref ?? "")→\(e.hyp ?? "")"
            case .del: key = "\(e.ref ?? "")→∅"
            case .ins: key = "∅→\(e.hyp ?? "")"
            }
            c[key, default: 0] += 1
        } }
        return c.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(limit).map { ($0.key, $0.value) }
    }
}
