import Darwin
import Foundation

/// V5 V1 — metrics the public-set harness reports. WER reuses `WERScorer`'s Levenshtein on
/// Open-ASR-normalised words; everything else is here.
public enum EvalMetrics {
    /// Word errors on normalised text (corpus WER = Σerrors / Σreference words; callers aggregate).
    public static func wer(reference: String, hypothesis: String, mode: OpenASRNormalizer.Mode) -> WERResult {
        WERScorer.score(reference: OpenASRNormalizer.words(reference, mode: mode),
                        hypothesis: OpenASRNormalizer.words(hypothesis, mode: mode))
    }

    /// Character edit distance over the normalised string (spaces count as characters).
    public static func cer(reference: String, hypothesis: String, mode: OpenASRNormalizer.Mode) -> (errors: Int, chars: Int) {
        let r = Array(OpenASRNormalizer.normalize(reference, mode: mode)), h = Array(OpenASRNormalizer.normalize(hypothesis, mode: mode))
        return (levenshtein(r, h), r.count)
    }

    static func levenshtein<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count), cur = prev
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    /// Entity recall: each reference entity (normalised) must appear as a contiguous word run in the
    /// normalised hypothesis.
    public static func entityHits(entities: [String], hypothesis: String) -> Int {
        let h = " " + OpenASRNormalizer.normalize(hypothesis) + " "
        return entities.filter { e in
            let n = OpenASRNormalizer.normalize(e)
            return !n.isEmpty && h.contains(" \(n) ")
        }.count
    }

    // MARK: cleanup

    /// Cleanup verdict for one example (SpeakoFlow-style restraint / edit / damage):
    /// - *restraint* applies when the clean target equals the input (nothing to fix): kept = output unchanged.
    /// - *edit* applies when the target differs: fixed = output matches the target.
    /// - *damage* (every example): the output is further from the target than the input was.
    public struct CleanupVerdict: Equatable, Sendable {
        public var needsEdit: Bool
        public var restrained: Bool
        public var edited: Bool
        public var damaged: Bool
    }

    public static func cleanup(input: String, target: String, output: String) -> CleanupVerdict {
        let norm: (String) -> String = { OpenASRNormalizer.normalize($0, mode: .raw) }
        let i = norm(input), t = norm(target), o = norm(output)
        let needsEdit = i != t
        let before = wer(reference: target, hypothesis: input, mode: .raw).errors
        let after = wer(reference: target, hypothesis: output, mode: .raw).errors
        return CleanupVerdict(needsEdit: needsEdit, restrained: !needsEdit && o == i, edited: needsEdit && o == t,
                              damaged: after > before)
    }

    // MARK: diarization

    public struct DERResult: Equatable, Sendable {
        public var missed: Double
        public var falseAlarm: Double
        public var confusion: Double
        public var referenceSpeech: Double
        public var der: Double { referenceSpeech == 0 ? 0 : (missed + falseAlarm + confusion) / referenceSpeech }
    }

    /// Frame-based DER (10 ms frames, no collar, overlap scored) with a greedy one-to-one speaker
    /// mapping by overlap (equal to Hungarian on the 2–4-speaker sets we score; noted in results).
    public static func der(reference: [SpeakerTurn], hypothesis: [SpeakerTurn], frame: Double = 0.01) -> DERResult {
        let end = max(reference.map(\.end).max() ?? 0, hypothesis.map(\.end).max() ?? 0)
        let n = Int((end / frame).rounded(.up))
        func frames(_ turns: [SpeakerTurn]) -> [Set<String>] {
            var out = Array(repeating: Set<String>(), count: n)
            for t in turns {
                let a = max(0, Int((t.start / frame).rounded())), b = min(n, Int((t.end / frame).rounded()))
                if a < b { for f in a..<b { out[f].insert(t.speaker) } }
            }
            return out
        }
        let r = frames(reference), h = frames(hypothesis)
        var overlap: [String: [String: Int]] = [:]
        for f in 0..<n { for rs in r[f] { for hs in h[f] { overlap[rs, default: [:]][hs, default: 0] += 1 } } }
        var pairs = overlap.flatMap { rs, m in m.map { (rs, $0.key, $0.value) } }.sorted { ($0.2, $0.0, $0.1) > ($1.2, $1.0, $1.1) }
        var map: [String: String] = [:], used = Set<String>()
        while let p = pairs.first {
            pairs.removeFirst()
            if map[p.0] == nil, !used.contains(p.1) { map[p.0] = p.1; used.insert(p.1) }
        }
        var miss = 0, fa = 0, conf = 0, total = 0
        for f in 0..<n {
            let rc = r[f].count, hc = h[f].count
            total += rc
            miss += max(0, rc - hc)
            fa += max(0, hc - rc)
            let correct = r[f].filter { map[$0].map(h[f].contains) ?? false }.count
            conf += min(rc, hc) - correct
        }
        return DERResult(missed: Double(miss) * frame, falseAlarm: Double(fa) * frame, confusion: Double(conf) * frame,
                         referenceSpeech: Double(total) * frame)
    }

    // MARK: memory

    /// Peak resident set size of this process in bytes (`getrusage` — bytes on macOS).
    public static func peakRSSBytes() -> UInt64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return UInt64(max(0, usage.ru_maxrss))
    }
}
