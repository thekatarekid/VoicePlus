import Foundation
import Shared

// MARK: - Context Writer · per-change guard (plan §1 transcribe column, §4.6)
//
// Transcribe mode writes what the user said. So every region the model changed must be one of:
//
// | change                                   | verdict                                             |
// |------------------------------------------|-----------------------------------------------------|
// | case, punctuation, hyphen/apostrophe,    | formatting — allowed on any word                    |
// | joins/splits ("web site" → "website"),   |                                                     |
// | numbers ("twenty five" → "25", "4B")     |                                                     |
// | filler / stutter removed                 | allowed                                             |
// | self-correction collapsed                | allowed when the retained words follow the cue      |
// | ("X, no, Y" / "X I mean Y" → "Y")        |                                                     |
// | a word swapped for another               | allowed only on an **uncertain** word, and only     |
// |                                          | when it sounds alike (installed Double Metaphone +  |
// |                                          | spelling gate), is in that word's alternates, or is |
// |                                          | a packet vocabulary / screen term whose spoken form |
// |                                          | matches the heard words                             |
// | new content words                        | reverted                                            |
// | content words dropped                    | reverted                                            |
//
// Failing regions revert individually; the rest lands (`partiallyReverted(n)`). An answer or a
// preamble instead of a transcript, an empty output, a runaway (> 2× the words with little
// overlap) or an output most of whose words had to be reverted rejects the whole output. Screen text and vocabulary are evidence for spelling only —
// never instructions, and never a reason to insert what was not said.

public struct WriterGuard: Sendable {
    public typealias PhoneticEncoder = ContextRepairStage.PhoneticEncoder

    /// One heard word (a span's text split on whitespace), carrying the span's evidence.
    public struct HeardToken: Sendable, Equatable {
        public var text: String
        public var confidence: Float
        public var alternates: [String]
        public var needsRepair: Bool
        /// Index of the span it came from.
        public var span: Int

        public init(text: String, confidence: Float, alternates: [String] = [], needsRepair: Bool = false, span: Int = 0) {
            self.text = text
            self.confidence = confidence
            self.alternates = alternates
            self.needsRepair = needsRepair
            self.span = span
        }

        /// Bet 9: a word below the threshold, or one an earlier stage flagged, may be corrected.
        public var isUncertain: Bool { confidence < TranscriptSpan.lowConfidenceThreshold || needsRepair }
        var key: String { WriterGuard.key(text) }
    }

    public enum Rejection: String, Sendable, CaseIterable, Equatable {
        case empty
        case assistantPreamble
        case runaway
        /// The reverted model words outnumber the heard words and make up most of the output: not
        /// a transcript with a few slips but a different text (an answer sharing a word or two).
        case mostlyReverted
        case everyChangeReverted
    }

    /// Why one region was put back (diagnostics; codes only).
    public enum RevertReason: String, Sendable, Equatable, Error {
        case insertion
        case deletion
        case substitution
        case confidentChanged
    }

    /// One changed region: the heard tokens it covers and the model's words for them.
    public struct Region: Sendable, Equatable {
        public var heard: Range<Int>
        public var output: [String]
        public var reverted: RevertReason?
    }

    public struct Accepted: Sendable, Equatable {
        /// The text each heard token lands as ("" when dropped or merged into a neighbour).
        public var perToken: [String]
        public var regions: [Region]
        public var revertedCount: Int
        /// `perToken` rendered: non-empty entries joined by one space.
        public var text: String { perToken.filter { !$0.isEmpty }.joined(separator: " ") }
    }

    public enum Verdict: Sendable, Equatable {
        case accepted(Accepted)
        case rejected(Rejection)

        public var accepted: Accepted? { if case .accepted(let a) = self { return a } else { return nil } }
        public var rejection: Rejection? { if case .rejected(let r) = self { return r } else { return nil } }
    }

    /// Runaway rule: more than this × the heard word count, with overlap below `runawayOverlap`.
    public var runawayRatio: Double
    public var runawayOverlap: Double
    private let encoderOverride: PhoneticEncoder?

    public init(phonetic: PhoneticEncoder? = nil, runawayRatio: Double = 2, runawayOverlap: Double = 0.5) {
        self.encoderOverride = phonetic
        self.runawayRatio = runawayRatio
        self.runawayOverlap = runawayOverlap
    }

    // MARK: Installed encoder (process-wide, set once by the app; falls back to the repair stage's)

    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var encoder: PhoneticEncoder?
    }
    private static let box = Box()

    public static func install(phonetic: PhoneticEncoder?) {
        box.lock.lock(); box.encoder = phonetic; box.lock.unlock()
    }

    static var installedEncoder: PhoneticEncoder? {
        box.lock.lock(); defer { box.lock.unlock() }
        return box.encoder ?? ContextRepairStage.installedEncoder
    }

    var phonetic: PhoneticEncoder? { encoderOverride ?? Self.installedEncoder }

    // MARK: Check

    /// - Parameters:
    ///   - heard: the words as the pipeline holds them, in order, with their spans' evidence.
    ///   - output: what the model returned (markers and surrounding whitespace are stripped).
    ///   - vocabulary: the packet's vocabulary matches (written form + spoken form + heard words).
    ///   - screenTerms: the packet's ranked screen terms (spelling evidence only).
    public func check(heard: [HeardToken], output rawOutput: String,
                      vocabulary: [ContextPacket.VocabularyMatch] = [], screenTerms: [String] = []) -> Verdict {
        let output = CleanupGuard.unmark(rawOutput).trimmingCharacters(in: .whitespacesAndNewlines)
        let input = heard.map(\.text).joined(separator: " ")
        guard !output.isEmpty else { return .rejected(.empty) }
        if CleanupGuard.hasPreamble(input: input, output: output) { return .rejected(.assistantPreamble) }
        let outTokens = WordDiff.tokens(output).filter { $0 != "\n" }
        if Double(outTokens.count) > runawayRatio * Double(max(heard.count, 1)),
           CleanupGuard.overlap(input, output) < runawayOverlap {
            return .rejected(.runaway)
        }

        let evidence = WriterGuardEvidence(phonetic: phonetic, vocabulary: vocabulary, screenTerms: screenTerms)
        let ops = Self.align(heard.map(\.key), outTokens.map(Self.key))
        var perToken = heard.map(\.text)
        var regions: [Region] = []
        var reverted = 0

        // Walk the ops: equal tokens take the model's spelling (formatting); runs of delete/insert
        // form regions that `explain` must justify token by token.
        var pendingHeard: [Int] = [], pendingOut: [String] = []
        var lastAssigned: Int?
        var prefix = ""
        func flush(followedByRetained: Bool) {
            guard !pendingHeard.isEmpty || !pendingOut.isEmpty else { return }
            let next = lastAssigned.map { $0 + 1 } ?? 0
            let range = pendingHeard.isEmpty ? next..<next : pendingHeard.first!..<(pendingHeard.last! + 1)
            var region = Region(heard: range, output: pendingOut, reverted: nil)
            let result = Self.explain(region: pendingHeard, output: pendingOut, heard: heard, evidence: evidence,
                                      followedByRetained: followedByRetained)
            switch result {
            case .success(let assigned):
                for (i, t) in assigned.perToken { perToken[i] = t }
                if let p = assigned.prefix {
                    // Punctuation the model put before anything it kept: attach to the neighbour.
                    if let la = lastAssigned { perToken[la] += p } else { prefix += p }
                }
                if let la = assigned.lastAssigned { lastAssigned = la }
            case .failure(let reason):
                region.reverted = reason
                reverted += 1
                // Heard tokens keep their text; the model's words for them are dropped.
            }
            regions.append(region)
            pendingHeard = []; pendingOut = []
        }
        for op in ops {
            switch op {
            case .equal(let hi, let oj):
                flush(followedByRetained: true)
                perToken[hi] = prefix + outTokens[oj]
                prefix = ""
                lastAssigned = hi
            case .delete(let hi): pendingHeard.append(hi)
            case .insert(let oj): pendingOut.append(outTokens[oj])
            }
        }
        flush(followedByRetained: false)
        if !prefix.isEmpty, let first = perToken.indices.first(where: { !perToken[$0].isEmpty }) {
            perToken[first] = prefix + perToken[first]
        }

        let accepted = Accepted(perToken: perToken, regions: regions, revertedCount: reverted)
        if reverted > 0 {
            if accepted.text == input { return .rejected(.everyChangeReverted) }
            let dropped = regions.filter { $0.reverted != nil }.reduce(0) { $0 + $1.output.count }
            if dropped > heard.count, dropped * 2 > outTokens.count { return .rejected(.mostlyReverted) }
        }
        return .accepted(accepted)
    }

    // MARK: Regions

    struct Assignment {
        var perToken: [Int: String] = [:]
        var prefix: String?
        var lastAssigned: Int?
    }

    /// Justifies one changed region. Every model word must be explained by heard words at or after
    /// the cursor (formatting, number, vocabulary / screen / alternate / sound-alike evidence);
    /// heard words skipped on the way must be fillers, stutters or a collapsed self-correction.
    static func explain(region idx: [Int], output: [String], heard: [HeardToken], evidence: WriterGuardEvidence,
                        followedByRetained: Bool) -> Result<Assignment, RevertReason> {
        var out = Assignment()
        var h = 0, j = 0
        var pendingPrefix = ""
        while j < output.count {
            let o = output[j]
            if key(o).isEmpty {
                // Punctuation on its own ("—", "…"): formatting, hangs off the previous word.
                if let la = out.lastAssigned { out.perToken[la, default: heard[la].text] += " " + o }
                else { pendingPrefix += o + " " }
                j += 1
                continue
            }
            var found = false
            var skip = 0
            while !found, h + skip < idx.count {
                let s = h + skip
                defer { skip += 1 }
                if skip > 0, !deletable(Array(idx[h..<s]), heard: heard, retainedAfter: true) { continue }
                guard let m = evidence.explain(heard: heard, at: idx, from: s, output: output, at: j) else { continue }
                for x in h..<s { out.perToken[idx[x]] = "" }
                out.perToken[idx[s]] = pendingPrefix + output[j..<(j + m.outputCount)].joined(separator: " ")
                for x in (s + 1)..<(s + m.heardCount) { out.perToken[idx[x]] = "" }
                pendingPrefix = ""
                out.lastAssigned = idx[s]
                h = s + m.heardCount
                j += m.outputCount
                found = true
            }
            if !found {
                if h >= idx.count { return .failure(.insertion) }
                return .failure(heard[idx[h]].isUncertain ? .substitution : .confidentChanged)
            }
        }
        if h < idx.count {
            guard deletable(Array(idx[h...]), heard: heard, retainedAfter: followedByRetained) else { return .failure(.deletion) }
            for x in h..<idx.count { out.perToken[idx[x]] = "" }
        }
        if !pendingPrefix.isEmpty { out.prefix = pendingPrefix }
        return .success(out)
    }

    /// A dropped run is fine when every word is a filler or a stutter, or when it ends with a
    /// self-correction cue and the words after the cue are retained nearby ("X, no, Y" → "Y").
    static func deletable(_ run: [Int], heard: [HeardToken], retainedAfter: Bool) -> Bool {
        guard !run.isEmpty else { return true }
        if run.allSatisfy({ isFiller(heard, $0) || isStutter(heard, $0) }) { return true }
        guard retainedAfter else { return false }
        let keys = run.map { heard[$0].key }
        for cue in correctionCues where keys.count >= cue.count {
            guard let at = lastIndex(of: cue, in: keys) else { continue }
            // Words after the cue inside the run must each be found among the neighbours that
            // stayed ("the red or rather the blue" → "the blue" keeps one "the").
            let tail = Array(keys[(at + cue.count)...])
            let lo = max(0, run.first! - 4), hi = min(heard.count - 1, run.last! + 4)
            let kept = Set((lo...hi).filter { !run.contains($0) }.map { heard[$0].key })
            if tail.allSatisfy({ kept.contains($0) }) { return true }
        }
        return false
    }

    static let fillers: Set<String> = ["um", "uh", "er", "ah", "erm", "hmm", "mm", "mhm", "uhm", "hm", "umm", "uhh"]
    static let correctionCues: [[String]] = [
        ["no", "wait"], ["wait", "no"], ["i", "mean"], ["scratch", "that"], ["strike", "that"], ["or", "rather"],
        ["make", "that"], ["no"], ["wait"], ["rather"], ["sorry"], ["correction"],
    ]

    static func isFiller(_ heard: [HeardToken], _ i: Int) -> Bool { fillers.contains(heard[i].key) }

    /// A repeated word (either copy may be the one dropped), or a fragment the next word
    /// completes ("pol polish").
    static func isStutter(_ heard: [HeardToken], _ i: Int) -> Bool {
        let a = heard[i].key
        guard !a.isEmpty else { return false }
        if i > 0, heard[i - 1].key == a { return true }
        guard i + 1 < heard.count else { return false }
        let b = heard[i + 1].key
        return a == b || (a.count >= 2 && b.count > a.count && b.hasPrefix(a))
    }

    static func lastIndex(of cue: [String], in keys: [String]) -> Int? {
        guard keys.count >= cue.count else { return nil }
        for start in stride(from: keys.count - cue.count, through: 0, by: -1)
        where Array(keys[start..<(start + cue.count)]) == cue { return start }
        return nil
    }

    /// Comparison key: letters and digits only, lowercased ("Friday," → "friday", "e-mail" → "email").
    static func key(_ token: String) -> String {
        String(token.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    // MARK: Alignment

    enum Op: Equatable { case equal(Int, Int), delete(Int), insert(Int) }

    /// LCS alignment over keys; beyond the table bound everything is one region.
    static func align(_ a: [String], _ b: [String]) -> [Op] {
        guard a.count * b.count <= 250_000 else {
            return a.indices.map { .delete($0) } + b.indices.map { .insert($0) }
        }
        var lcs = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var ops: [Op] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] { ops.append(.equal(i, j)); i += 1; j += 1 }
            else if lcs[i + 1][j] >= lcs[i][j + 1] { ops.append(.delete(i)); i += 1 }
            else { ops.append(.insert(j)); j += 1 }
        }
        while i < a.count { ops.append(.delete(i)); i += 1 }
        while j < b.count { ops.append(.insert(j)); j += 1 }
        return ops
    }
}
