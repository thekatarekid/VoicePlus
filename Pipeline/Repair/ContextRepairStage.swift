import Foundation
import Shared

/// H19 — the context repair stage, first after the gatekeeper (before any formatter).
///
/// It swaps a run of recognised words for a term the user can see near the caret, but only when:
/// - the run holds at least one **uncertain** word (low confidence or already flagged), and every
///   confident word in the run matches the term exactly — confident words are never changed;
/// - each changed word has evidence: the term's word is among the span's top-K recogniser
///   alternates, or it sounds alike (Double Metaphone, installed by the app) and is spelled close;
/// - the term is near the caret (`ContextRepairEvidence`, written per turn by the app from the H17
///   near-caret context). Screen text is vocabulary only, never instructions; a secure field
///   writes no evidence, so the stage is inert there.
///
/// A swap keeps the audio: the new span covers the replaced spans' audio range, keeps their lowest
/// confidence, their provenance (plus this stage), stays flagged `needsRepair` when any replaced
/// word was uncertain, and carries the heard text as a `.repair` alternate so it can be undone.
/// Anything ambiguous (two terms for one run) is left alone.
public struct ContextRepairStage: PipelineStage {
    public static let stageID: StageID = "repair.context"
    public var id: StageID { Self.stageID }

    /// Phonetic codes of one word (primary + secondary). The app installs Double Metaphone
    /// (`Engine/Repair/DoubleMetaphone`); with none installed only exact-alias / top-K / close-spelling
    /// evidence counts.
    public typealias PhoneticEncoder = @Sendable (String) -> [String]

    private let encoderOverride: PhoneticEncoder?
    public init(phonetic: PhoneticEncoder? = nil) { self.encoderOverride = phonetic }

    private var phonetic: PhoneticEncoder? { encoderOverride ?? Self.installedEncoder }

    public func process(_ spans: [TranscriptSpan], context: StageContext) async throws -> [TranscriptSpan] {
        guard let evidence = ContextRepairEvidence.read(from: context), !evidence.terms.isEmpty else {
            return spans.map { $0.touched(by: id) }
        }
        return Self.repair(spans, evidence: evidence, phonetic: phonetic, stage: id).spans
    }

    // MARK: - Installed encoder (process-wide, set once by the app)

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
        return box.encoder
    }

    // MARK: - Pure repair

    public struct Swap: Equatable, Sendable {
        public var heard: String
        public var written: String
        public var spanRange: Range<Int>
    }

    public struct Outcome: Sendable {
        public var spans: [TranscriptSpan]
        public var swaps: [Swap]
    }

    /// Most words a run may hold (a term of up to four spoken words).
    static let maxRun = 4
    /// Top-K recogniser alternates consulted per span.
    static let topK = 5

    public static func repair(_ spans: [TranscriptSpan], evidence: ContextRepairEvidence,
                              phonetic: PhoneticEncoder?, stage: StageID = stageID) -> Outcome {
        let words = spans.map { Word($0.text) }
        // Candidate matches: (range, term index, form) for every term form against every window.
        struct Match { var range: Range<Int>; var term: Int; var form: [String] }
        var matches: [Match] = []
        for (ti, term) in evidence.terms.enumerated() where term.distance <= evidence.maxDistance {
            for form in term.spokenForms() where (1...maxRun).contains(form.count) {
                guard spans.count >= form.count else { continue }
                for start in 0...(spans.count - form.count) {
                    let range = start..<(start + form.count)
                    if accepts(range, form: form, term: term, spans: spans, words: words, phonetic: phonetic) {
                        matches.append(Match(range: range, term: ti, form: form))
                    }
                }
            }
        }
        guard !matches.isEmpty else { return Outcome(spans: spans.map { $0.touched(by: stage) }, swaps: []) }

        // Ambiguity: a run claimed by two different written terms is left alone.
        func overlaps(_ a: Range<Int>, _ b: Range<Int>) -> Bool { a.overlaps(b) }
        var chosen: [Match] = []
        let ordered = matches.sorted {
            let (a, b) = (evidence.terms[$0.term], evidence.terms[$1.term])
            if a.distance != b.distance { return a.distance < b.distance }
            return $0.range.count > $1.range.count
        }
        var blocked: [Range<Int>] = []
        for m in ordered {
            let written = evidence.terms[m.term].text.lowercased()
            let rivals = matches.filter { overlaps($0.range, m.range) && evidence.terms[$0.term].text.lowercased() != written }
            if !rivals.isEmpty { blocked.append(m.range); continue }
            if blocked.contains(where: { overlaps($0, m.range) }) { continue }
            if chosen.contains(where: { overlaps($0.range, m.range) }) { continue }
            chosen.append(m)
        }
        guard !chosen.isEmpty else { return Outcome(spans: spans.map { $0.touched(by: stage) }, swaps: []) }

        var out: [TranscriptSpan] = []
        var swaps: [Swap] = []
        var i = 0
        let byStart = Dictionary(uniqueKeysWithValues: chosen.map { ($0.range.lowerBound, $0) })
        while i < spans.count {
            guard let m = byStart[i] else { out.append(spans[i].touched(by: stage)); i += 1; continue }
            let run = Array(spans[m.range])
            let term = evidence.terms[m.term]
            let merged = mergedSpan(run, written: term.text, stage: stage)
            swaps.append(Swap(heard: run.map(\.text).joined(separator: " "), written: merged.text, spanRange: m.range))
            out.append(merged)
            i = m.range.upperBound
        }
        return Outcome(spans: out, swaps: swaps)
    }

    static func accepts(_ range: Range<Int>, form: [String], term: ContextRepairEvidence.Term,
                        spans: [TranscriptSpan], words: [Word], phonetic: PhoneticEncoder?) -> Bool {
        let run = Array(spans[range])
        let heard = Array(words[range])
        // Words only: no empty, multi-word or provisional spans, no sentence break inside the run.
        guard heard.allSatisfy({ !$0.core.isEmpty && !$0.core.contains(" ") }),
              run.allSatisfy({ !$0.isProvisional }),
              heard.dropLast().allSatisfy({ !$0.endsSentence }) else { return false }
        guard run.contains(where: { $0.isLowConfidence || $0.needsRepair }) else { return false }
        let heardText = heard.map(\.key).joined(separator: " ")
        let formText = form.joined(separator: " ")
        // Already the written form: nothing to do.
        if heard.map(\.core).joined(separator: " ") == term.text { return false }
        if heardText == formText {
            // Exact heard alias of a written form that differs ("hold to talk" → "hold-to-talk").
            return form.count >= 2 && term.text.lowercased() != formText
        }
        var changed = 0, exact = 0
        for (k, w) in heard.enumerated() {
            let f = form[k]
            if w.key == f { exact += 1; continue }
            let span = run[k]
            // Confident words are never changed.
            guard span.isLowConfidence || span.needsRepair else { return false }
            guard wordEvidence(heard: w.key, form: f, span: span, single: form.count == 1,
                               kind: term.kind, phonetic: phonetic) else { return false }
            changed += 1
        }
        guard changed > 0 else { return false }
        switch term.kind {
        case .phrase:
            // A lowercase phrase off the screen: one word may change, the rest must anchor it.
            return changed == 1 && exact >= 1
        case .entity, .word:
            if form.count >= 2 { return exact >= 1 || changed <= 1 }
            return true
        }
    }

    /// Evidence that the uncertain `heard` word was really `form`.
    static func wordEvidence(heard: String, form: String, span: TranscriptSpan, single: Bool,
                             kind: ContextRepairEvidence.Term.Kind, phonetic: PhoneticEncoder?) -> Bool {
        // Top-K recogniser alternates.
        let alts = span.alternates.sorted { $0.score > $1.score }.prefix(topK)
        if alts.contains(where: { Word($0.text).key == form }) { return true }
        let spell = spelling(heard, form)
        guard let phonetic else { return !single && heard.count >= 4 && spell >= 0.8 }
        switch phoneticMatch(heard, form, phonetic) {
        case .strong:
            // One word alone is the false-swap risk ("out" → "OAuth"): it must also be spelled close.
            return single ? (spell >= 0.7 && abs(heard.count - form.count) <= 1) : spell >= 0.34
        case .near: return !single && spell >= 0.5
        case .none: return !single && heard.count >= 5 && spell >= 0.85
        }
    }

    enum Phonetic { case strong, near, none }

    static func phoneticMatch(_ a: String, _ b: String, _ encode: PhoneticEncoder) -> Phonetic {
        let ca = encode(a).filter { !$0.isEmpty }, cb = encode(b).filter { !$0.isEmpty }
        guard !ca.isEmpty, !cb.isEmpty else { return .none }
        if ca.contains(where: { cb.contains($0) }) { return .strong }
        // Near: equal, or one a one-sound-longer prefix of the other, once an initial breath / vowel
        // code is set aside ("whole" AL ~ "hold" HLT → L ~ LT).
        func core(_ c: String) -> String { c.count > 1 && (c.first == "A" || c.first == "H") ? String(c.dropFirst()) : c }
        for x in ca.map(core) { for y in cb.map(core) {
            let (s, l) = x.count <= y.count ? (x, y) : (y, x)
            if s == l || (!s.isEmpty && l.count - s.count == 1 && l.hasPrefix(s)) { return .near }
        } }
        return .none
    }

    /// 1 − normalised Levenshtein distance.
    static func spelling(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty || !y.isEmpty else { return 1 }
        var prev = Array(0...y.count)
        for i in 1...max(x.count, 1) where !x.isEmpty {
            var cur = [i] + Array(repeating: 0, count: y.count)
            for j in stride(from: 1, through: y.count, by: 1) {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        let d = x.isEmpty ? y.count : prev[y.count]
        return 1 - Double(d) / Double(max(x.count, y.count))
    }

    /// The run becomes one span: the term's written form with the run's outer punctuation, the
    /// run's audio, lowest confidence and provenance; the heard text kept as a `.repair` alternate.
    static func mergedSpan(_ run: [TranscriptSpan], written: String, stage: StageID) -> TranscriptSpan {
        let first = Word(run.first!.text), last = Word(run.last!.text)
        var text = written
        if let c = first.core.first, c.isUppercase, written == written.lowercased(), let w = written.first {
            text = String(w).uppercased() + written.dropFirst()
        }
        text = first.leading + text + last.trailing
        let heard = run.map(\.text).joined(separator: " ")
        var provenance = run.first!.provenance
        provenance.append(stage)
        var alternates = [Alternate(text: heard, score: 0, source: .repair)]
        alternates += run.count == 1 ? run[0].alternates.filter { Word($0.text).key != Word(written).key } : []
        return TranscriptSpan(
            text: text,
            confidence: run.map(\.confidence).min() ?? 0,
            audioRange: run.first!.audioRange.lowerBound...run.last!.audioRange.upperBound,
            alternates: alternates,
            provenance: provenance,
            needsRepair: run.contains { $0.needsRepair || $0.isLowConfidence },
            stability: run.map(\.stability).min() ?? .final,
            punctuationOrigin: run.last!.punctuationOrigin
        )
    }

    /// A span's word: leading / trailing punctuation split off; `key` is lowercased.
    struct Word {
        var leading: String, core: String, trailing: String
        var key: String { core.lowercased() }
        var endsSentence: Bool { trailing.contains { ".?!\n".contains($0) } }
        init(_ raw: String) {
            let t = raw.trimmingCharacters(in: .whitespaces)
            let isEdge: (Character) -> Bool = { !($0.isLetter || $0.isNumber) }
            let lead = t.prefix(while: isEdge)
            let rest = t.dropFirst(lead.count)
            let trail = String(rest.reversed().prefix(while: isEdge).reversed())
            leading = String(lead)
            core = String(rest.dropLast(trail.count))
            trailing = trail
        }
    }
}

/// H19 — the per-turn vocabulary the repair stage may use: near-caret terms (H17 `.screenNear`)
/// with their heard aliases and caret distance. Written into `StageContext.extra` by the app;
/// never persisted.
public struct ContextRepairEvidence: Codable, Equatable, Sendable {
    public static let extraKey = "context.repairTerms"

    public struct Term: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable {
            /// Entity-like (capitalised, camelCase, digits, `-`, `_`, `.`).
            case entity
            /// An uncommon plain word.
            case word
            /// A lowercase multi-word phrase near the caret.
            case phrase
        }
        public var text: String
        public var aliases: [String]
        /// UTF-16 units from the caret.
        public var distance: Int
        public var kind: Kind

        public init(text: String, aliases: [String] = [], distance: Int, kind: Kind) {
            self.text = text; self.aliases = aliases; self.distance = distance; self.kind = kind
        }

        /// Lowercased word lists the term may be heard as: its heard aliases, then the written
        /// form itself when it is plain words.
        func spokenForms() -> [[String]] {
            var out: [[String]] = []
            var seen = Set<String>()
            for s in aliases + [text] {
                let ws = s.split(whereSeparator: \.isWhitespace).map { ContextRepairStage.Word(String($0)).key }
                guard !ws.isEmpty, ws.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "'" } }),
                      seen.insert(ws.joined(separator: " ")).inserted else { continue }
                out.append(ws)
            }
            return out
        }
    }

    public var terms: [Term]
    /// Terms farther than this from the caret are ignored.
    public var maxDistance: Int

    public init(terms: [Term], maxDistance: Int = 400) {
        self.terms = Array(terms.prefix(64)); self.maxDistance = maxDistance
    }

    public static func read(from context: StageContext) -> ContextRepairEvidence? {
        guard let raw = context.extra[extraKey], let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ContextRepairEvidence.self, from: data)
    }

    public func write(into context: inout StageContext) {
        guard !terms.isEmpty, let data = try? JSONEncoder().encode(self), let s = String(data: data, encoding: .utf8) else { return }
        context.extra[Self.extraKey] = s
    }
}
