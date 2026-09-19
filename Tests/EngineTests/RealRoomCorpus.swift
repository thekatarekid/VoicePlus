import Foundation
import Shared
@testable import Engine

/// The real-room corpus (`Fixtures/real-room/`) and the per-file scorer R1.4 and R1.5 share.
///
/// The corpus is one pass of `Fixtures/real-room/script.md` per microphone, recorded by
/// `UtteranceRecorder`. Each utterance is `<stamp>-raw.wav`, `<stamp>-processed.wav` and
/// `<stamp>.json`. The WAVs are git-ignored (the owner's voice); the script and the manifests are
/// committed, so a checkout without the audio must skip rather than fail.
///
/// **Matching:** recordings are matched to script lines by timestamp order. The recorder's stamps
/// are `yyyy-MM-dd-HHmmss-SSS`, which sorts chronologically as a string, and the script is read once
/// top to bottom, so the *n*-th recording is line *n*. There is no other link between the two — a
/// skipped or re-read line shifts everything after it, which is why `scriptLines` and the file list
/// must be the same length before any scoring is trusted.
enum RealRoomCorpus {

    /// One utterance: the raw capture, the processed copy and the script line it should say.
    struct Item {
        let index: Int          // 1-based, matches the script numbering
        let stamp: String
        let raw: URL
        let processed: URL?
        let reference: String
    }

    /// V4 Wave 1 gate "digits class WER < 0.20" (build doc §4): the script lines that contain digits —
    /// 04 "11:45", 05 "2,340 … 2,430", 11 "14 … 400050". Line 08 says its numbers as words ("two",
    /// "one") and is not in the class. The gate is scored on the landed (formatted) text by
    /// `Tests/AppTests/RealRoomDigitsClassTests.swift`; `scoreRealRoomCorpus` prints the same class on
    /// the model's own text, before formatting, for comparison.
    static let digitLines: Set<Int> = [4, 5, 11]

    static func root() -> URL? {
        AppPaths.fixturesDirectory()?.appendingPathComponent("real-room", isDirectory: true)
    }

    /// The twenty reference sentences, in script order, without their `NN  ` numbering.
    static func scriptLines(at url: URL? = root()?.appendingPathComponent("script.md")) -> [String] {
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var lines: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // "01  The quick brown fox…" — two leading digits, then the sentence.
            guard line.count > 4, line.prefix(2).allSatisfy(\.isNumber) else { continue }
            let body = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            if !body.isEmpty { lines.append(body) }
        }
        return lines
    }

    /// `*-raw.wav` in chronological (= filename) order.
    static func rawRecordings(in pass: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: pass, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasSuffix("-raw.wav") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Zips one microphone pass against the script. Empty when the audio is not in the checkout;
    /// `nil` when the counts disagree, because then no pairing is trustworthy.
    static func items(pass name: String = "builtin") -> [Item]? {
        guard let root = root() else { return [] }
        let dir = root.appendingPathComponent(name, isDirectory: true)
        let raws = rawRecordings(in: dir)
        guard !raws.isEmpty else { return [] }
        let lines = scriptLines()
        guard raws.count == lines.count else { return nil }
        return zip(raws.indices, raws).map { i, raw in
            let stamp = UtteranceRecorder.stamp(of: raw)
            let processed = dir.appendingPathComponent("\(stamp)-processed.wav")
            return Item(index: i + 1, stamp: stamp, raw: raw,
                        processed: FileManager.default.fileExists(atPath: processed.path) ? processed : nil,
                        reference: lines[i])
        }
    }

    // MARK: Scoring

    /// One scored hypothesis. `wer` is errors / reference words over normalised words
    /// (lowercased, punctuation stripped) — see `wordErrorRate` and `werCounts`.
    struct Score {
        let index: Int
        let stamp: String
        let reference: String
        let hypothesis: String
        let counts: WERCounts
        var wer: Double { counts.wer }
    }

    struct WERCounts {
        var substitutions = 0
        var deletions = 0
        var insertions = 0
        var referenceWords = 0
        var errors: Int { substitutions + deletions + insertions }
        var wer: Double {
            if referenceWords == 0 { return errors == 0 ? 0 : 1 }
            return Double(errors) / Double(referenceWords)
        }
        static func + (a: WERCounts, b: WERCounts) -> WERCounts {
            WERCounts(substitutions: a.substitutions + b.substitutions,
                      deletions: a.deletions + b.deletions,
                      insertions: a.insertions + b.insertions,
                      referenceWords: a.referenceWords + b.referenceWords)
        }
    }

    /// Levenshtein over normalised words, with a backtrace so substitutions, deletions and
    /// insertions are reported separately (a corpus total is the sum of the per-file counts,
    /// which is not the mean of the per-file rates).
    static func werCounts(reference: String, hypothesis: String) -> WERCounts {
        let r = normalizedWords(reference), h = normalizedWords(hypothesis)
        let n = r.count, m = h.count
        var d = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { d[i][0] = i }
        for j in 0...m { d[0][j] = j }
        if n > 0, m > 0 {
            for i in 1...n {
                for j in 1...m {
                    let cost = r[i - 1] == h[j - 1] ? 0 : 1
                    d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                }
            }
        }
        var i = n, j = m, counts = WERCounts(referenceWords: n)
        while i > 0 || j > 0 {
            if i > 0, j > 0, d[i][j] == d[i - 1][j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1) {
                if r[i - 1] != h[j - 1] { counts.substitutions += 1 }
                i -= 1; j -= 1
            } else if i > 0, d[i][j] == d[i - 1][j] + 1 {
                counts.deletions += 1; i -= 1
            } else {
                counts.insertions += 1; j -= 1
            }
        }
        return counts
    }

    /// Lowercase, drop everything that is not a letter, a digit or an inner apostrophe. Digit
    /// grouping goes too ("2,340" → "2340") so a comma is not scored as a word error.
    static func normalizedWords(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        let chars = Array(text.lowercased())
        for (idx, ch) in chars.enumerated() {
            if ch.isLetter || ch.isNumber || ch == "'" {
                current.append(ch)
            } else if ch == "," && idx > 0 && chars[idx - 1].isNumber
                        && idx + 1 < chars.count && chars[idx + 1].isNumber {
                continue                              // digit grouping: "2,340" is one word "2340"
            } else if !current.isEmpty {
                out.append(current.trimmingCharacters(in: CharacterSet(charactersIn: "'")))
                current = ""
            }
        }
        if !current.isEmpty { out.append(current.trimmingCharacters(in: CharacterSet(charactersIn: "'"))) }
        return out.filter { !$0.isEmpty }
    }

    /// `substitutions/deletions/insertions` in a fixed width, for table rows.
    static func errorBreakdown(_ c: WERCounts) -> String {
        String(format: "%2ds %2dd %2di", c.substitutions, c.deletions, c.insertions)
    }
}
