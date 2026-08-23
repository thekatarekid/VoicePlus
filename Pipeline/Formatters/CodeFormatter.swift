import Foundation
import Shared

/// P1.7 T4 — code-register formatter. Deterministic spoken-code transforms:
/// casing commands (`camel case user id` → `userId`), spoken symbols (`open paren`, `equals`,
/// `arrow`, `dot`), paths (`slash users slash foo` → `/users/foo`), math/numbers, common
/// identifiers (`json` → `JSON`), filler removal and self-correction ("five no ten").
/// No sentence punctuation or capitalization is added.
///
/// Confidence contract (Bet 9): spans with `confidence < 0.5` are frozen — emitted verbatim,
/// flagged `needsRepair`, never consumed by a transform. Removed words are never dropped: their
/// audioRange is merged into the neighbouring output span (merged spans carry the minimum
/// confidence of their parts and the union of their alternates).
public struct CodeFormatter: PipelineStage {
    public let id: StageID = .formatterCode

    public init() {}

    public func process(_ spans: [TranscriptSpan], context: StageContext) async throws -> [TranscriptSpan] {
        Self.formatSpans(spans, stage: id)
    }

    /// Synchronous core of `process`.
    public static func formatSpans(_ spans: [TranscriptSpan], stage: StageID = .formatterCode) -> [TranscriptSpan] {
        guard !spans.isEmpty else { return [] }
        var words = CodeWords.tokenize(spans)
        CodeWords.removeFillers(&words)
        CodeWords.resolveSelfCorrections(&words)
        CodeWords.mergeNumbers(&words)
        let pieces = CodePieces.build(from: words)
        return CodePieces.rebuild(pieces, from: spans, stage: stage)
    }

    /// Convenience for golden tests and the Lab: formats plain text as a single-utterance
    /// of one fully-confident span per word.
    public static func format(_ text: String) -> String {
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        let spans = words.enumerated().map { i, w in
            TranscriptSpan(text: w, confidence: 1, audioRange: Double(i)...Double(i + 1), provenance: [.asr])
        }
        return render(formatSpans(spans))
    }

    /// Joins span texts for display: single spaces, none around newlines.
    public static func render(_ spans: [TranscriptSpan]) -> String {
        var out = ""
        for text in spans.map(\.text) where !text.isEmpty {
            if !out.isEmpty, !out.hasSuffix("\n"), !text.hasPrefix("\n") { out += " " }
            out += text
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Word layer

/// A word with the input span range it came from. `frozen` words come from low-confidence spans.
struct CodeWord {
    var text: String
    var lo: Int
    var hi: Int
    var frozen: Bool
    var deleted = false
    var key: String { text.lowercased() }
}

enum CodeWords {
    static let trailingPunctuation: Set<Character> = [".", ",", "!", "?", ";", ":"]

    static func tokenize(_ spans: [TranscriptSpan]) -> [CodeWord] {
        var out: [CodeWord] = []
        for (i, span) in spans.enumerated() {
            if span.isLowConfidence {
                out.append(CodeWord(text: span.text, lo: i, hi: i, frozen: true))
                continue
            }
            for piece in span.text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }) {
                var core = String(piece)
                while let last = core.last, trailingPunctuation.contains(last), core.count > 1 {
                    core.removeLast()
                }
                if out.isEmpty, let first = core.first, first.isUppercase,
                   core.dropFirst().allSatisfy({ $0.isLowercase }) {
                    core = core.lowercased() // code has no sentence capitalization
                }
                out.append(CodeWord(text: core, lo: i, hi: i, frozen: false))
            }
        }
        return out
    }

    static func removeFillers(_ words: inout [CodeWord]) {
        for i in words.indices where !words[i].frozen && CodeVocabulary.fillers.contains(words[i].key) {
            words[i].deleted = true
        }
    }

    /// "X no Y" / "X I mean Y" / "X sorry Y" → Y replaces the matching-length phrase before the marker.
    /// "scratch that" deletes everything before it.
    static func resolveSelfCorrections(_ words: inout [CodeWord]) {
        let markers: [[String]] = [["i", "mean"], ["scratch", "that"], ["no"], ["sorry"], ["rather"]]
        var i = 0
        while i < words.count {
            guard !words[i].deleted, !words[i].frozen else { i += 1; continue }
            let active = words.indices.filter { !words[$0].deleted }
            guard let pos = active.firstIndex(of: i) else { i += 1; continue }
            var matched: [String]?
            for marker in markers where pos + marker.count <= active.count {
                let keys = (0..<marker.count).map { words[active[pos + $0]].key }
                if keys == marker, !(0..<marker.count).contains(where: { words[active[pos + $0]].frozen }) {
                    matched = marker
                    break
                }
            }
            guard let marker = matched, pos > 0 else { i += 1; continue }
            if marker == ["scratch", "that"] {
                for k in 0..<pos where !words[active[k]].frozen { words[active[k]].deleted = true }
                for k in 0..<marker.count { words[active[pos + k]].deleted = true }
                i += 1
                continue
            }
            let replStart = pos + marker.count
            guard replStart < active.count, !words[active[replStart]].frozen else { i += 1; continue }
            if marker == ["no"], CodeVocabulary.noNotCorrection.contains(words[active[pos - 1]].key) { i += 1; continue }
            // Reparandum length: largest n whose first word matches the replacement's first word, else 1.
            var n = 1
            for candidate in stride(from: 3, through: 2, by: -1) where pos - candidate >= 0 {
                if words[active[pos - candidate]].key == words[active[replStart]].key { n = candidate; break }
            }
            let removed = (pos - n..<pos).map { active[$0] }
            guard !removed.contains(where: { words[$0].frozen }) else { i += 1; continue }
            for k in removed { words[k].deleted = true }
            for k in 0..<marker.count { words[active[pos + k]].deleted = true }
            i += 1
        }
    }

    /// Runs of number words become digits, merged into one word covering all source spans.
    static func mergeNumbers(_ words: inout [CodeWord]) {
        var out: [CodeWord] = []
        var run: [CodeWord] = []
        func flush() {
            guard !run.isEmpty else { return }
            if let value = CodeVocabulary.parseNumber(run.map(\.key)) {
                var merged = run[0]
                merged.text = String(value)
                merged.hi = run[run.count - 1].hi
                out.append(merged)
            } else {
                out.append(contentsOf: run)
            }
            run.removeAll()
        }
        for word in words {
            if !word.frozen, !word.deleted, CodeVocabulary.isNumberWord(word.key) {
                run.append(word)
            } else if word.deleted, !run.isEmpty {
                out.append(word) // deletions are transparent to number runs
            } else {
                flush()
                out.append(word)
            }
        }
        flush()
        words = out
    }
}

// MARK: - Piece layer

/// An output fragment with glue rules; consecutive pieces are joined with "" or " ".
struct CodePiece {
    enum Kind { case word, symbol, frozen, deleted, space }
    var text: String
    var lo: Int
    var hi: Int
    var kind: Kind
    var glueBefore = false
    var glueAfter = false
}

enum CodePieces {
    typealias V = CodeVocabulary

    static func build(from allWords: [CodeWord]) -> [CodePiece] {
        var pieces: [CodePiece] = []
        let words = allWords.filter { !$0.deleted }
        // Deletions stay in the stream so their ranges are preserved, in original order.
        let stream = allWords
        var lastStyle: V.CaseStyle?
        var inFlag = false
        let unspacedEquals = words.first?.key == "export"
        var i = 0

        func key(_ j: Int) -> String? {
            guard j < stream.count else { return nil }
            let w = stream[j]
            return (w.frozen || w.deleted) ? nil : w.key
        }
        func isPlainWord(_ j: Int) -> Bool {
            guard let k = key(j) else { return false }
            if V.stopWords.contains(k) || symbolMatch(at: j) != nil || caseMatch(at: j) != nil
                || wordCaseMatch(at: j) != nil || k == "space" || k == "array" { return false }
            return true
        }
        func matchPhrase<T>(_ table: [([String], T)], at j: Int) -> ([String], T)? {
            for (phrase, value) in table where phrase.count <= stream.count - j {
                if (0..<phrase.count).allSatisfy({ key(j + $0) == phrase[$0] }) { return (phrase, value) }
            }
            return nil
        }
        func symbolMatch(at j: Int) -> V.Symbol? {
            var best: V.Symbol?
            for symbol in V.symbols where symbol.words.count <= stream.count - j {
                if (0..<symbol.words.count).allSatisfy({ key(j + $0) == symbol.words[$0] }),
                   best == nil || symbol.words.count > best!.words.count { best = symbol }
            }
            return best
        }
        func caseMatch(at j: Int) -> ([String], V.CaseStyle)? { matchPhrase(V.caseCommands, at: j) }
        func wordCaseMatch(at j: Int) -> ([String], V.WordCase)? { matchPhrase(V.wordCaseCommands, at: j) }
        func identifierMatch(at j: Int) -> ([String], String)? { matchPhrase(V.identifiers, at: j) }

        /// Collects plain words starting at `j` (kebab: "dash" acts as separator) for a case group.
        func collectGroup(from j: Int, style: V.CaseStyle?, max: Int) -> (texts: [String], end: Int) {
            var texts: [String] = []
            var k = j
            while k < stream.count, texts.count < max {
                if stream[k].deleted { k += 1; continue }
                if style == .kebab, key(k) == "dash", k + 1 < stream.count, key(k + 1) != nil {
                    texts.append(stream[k + 1].text)
                    k += 2
                    continue
                }
                if let idf = identifierMatch(at: k) {
                    texts.append(idf.1)
                    k += idf.0.count
                    continue
                }
                guard isPlainWord(k) else { break }
                texts.append(stream[k].text)
                k += 1
            }
            return (texts, k)
        }

        while i < stream.count {
            let w = stream[i]
            if w.deleted {
                pieces.append(CodePiece(text: "", lo: w.lo, hi: w.hi, kind: .deleted))
                i += 1
                continue
            }
            if w.frozen {
                pieces.append(CodePiece(text: w.text, lo: w.lo, hi: w.hi, kind: .frozen))
                inFlag = false
                i += 1
                continue
            }
            let k = w.key
            let prev = pieces.last(where: { $0.kind != .deleted })

            // Explicit "space" forces a separator.
            if k == "space" {
                pieces.append(CodePiece(text: "", lo: w.lo, hi: w.hi, kind: .space))
                inFlag = false
                i += 1
                continue
            }

            // Case commands: camel/snake/kebab/pascal/constant over the following group.
            if let (phrase, style) = caseMatch(at: i) {
                let group = collectGroup(from: i + phrase.count, style: style, max: 6)
                inFlag = false
                if group.texts.isEmpty {
                    pieces.append(CodePiece(text: "", lo: w.lo, hi: stream[i + phrase.count - 1].hi, kind: .deleted))
                    i += phrase.count
                } else {
                    lastStyle = style
                    pieces.append(CodePiece(text: V.apply(style, to: group.texts), lo: w.lo, hi: stream[group.end - 1].hi, kind: .word))
                    i = group.end
                }
                continue
            }

            // all caps / lowercase / capital over the next word.
            if let (phrase, wordCase) = wordCaseMatch(at: i), key(i + phrase.count) != nil {
                let target = stream[i + phrase.count]
                let text: String
                switch wordCase {
                case .upper: text = target.text.uppercased()
                case .lower: text = target.text.lowercased()
                case .capital: text = target.text.prefix(1).uppercased() + target.text.dropFirst()
                }
                pieces.append(CodePiece(text: text, lo: w.lo, hi: target.hi, kind: .word))
                inFlag = false
                i += phrase.count + 1
                continue
            }

            // "array of X Y" → [XY]
            if k == "array", key(i + 1) == "of" {
                let group = collectGroup(from: i + 2, style: .pascal, max: 3)
                if !group.texts.isEmpty {
                    pieces.append(CodePiece(text: "[" + V.apply(.pascal, to: group.texts) + "]", lo: w.lo, hi: stream[group.end - 1].hi, kind: .word))
                    inFlag = false
                    i = group.end
                    continue
                }
            }

            // Spoken symbols.
            if let symbol = symbolMatch(at: i) {
                let hi = stream[i + symbol.words.count - 1].hi
                var piece = CodePiece(text: symbol.text, lo: w.lo, hi: hi, kind: .symbol,
                                      glueBefore: symbol.glueBefore, glueAfter: symbol.glueAfter)
                let nextKey = key(i + symbol.words.count)
                let prevIsPath = prev.map { $0.text.contains("/") || $0.text.contains("~") || $0.text.contains("$") } ?? false
                switch symbol.words {
                case ["dash"], ["hyphen"]:
                    let nextIsWord = nextKey.map { $0.count > 1 && isPlainWord(i + 1) } ?? false
                    piece.glueBefore = prev?.text == "-" || (prev?.kind == .word && nextIsWord)
                    piece.glueAfter = true
                    inFlag = !nextIsWord
                case ["slash"]:
                    piece.glueBefore = prev != nil && prev?.kind != .space
                        && !(prev?.kind == .word && V.pathPreceders.contains(prev!.text.lowercased()))
                    piece.glueAfter = true
                    inFlag = false
                case ["colon"]:
                    piece.glueBefore = true
                    piece.glueAfter = prevIsPath || nextKey == "dollar" || nextKey == "slash" || nextKey == "tilde"
                    inFlag = false
                case ["equals"]:
                    piece.glueBefore = unspacedEquals
                    piece.glueAfter = unspacedEquals
                    inFlag = false
                default:
                    inFlag = false
                }
                pieces.append(piece)
                i += symbol.words.count
                continue
            }
            // Canonical identifiers.
            if let (phrase, canonical) = identifierMatch(at: i) {
                pieces.append(CodePiece(text: canonical, lo: w.lo, hi: stream[i + phrase.count - 1].hi, kind: .word))
                inFlag = false
                i += phrase.count
                continue
            }

            // Multi-word run right after a "." takes the sticky style (default camel).
            if prev?.text == ".", prev?.kind == .symbol, isPlainWord(i) {
                let group = collectGroup(from: i, style: nil, max: 4)
                if group.texts.count >= 2 {
                    pieces.append(CodePiece(text: V.apply(lastStyle ?? .camel, to: group.texts), lo: w.lo, hi: stream[group.end - 1].hi, kind: .word))
                    inFlag = false
                    i = group.end
                    continue
                }
            }

            // Plain word. Single letters chain onto a flag: "dash r n" → -rn.
            var piece = CodePiece(text: w.text, lo: w.lo, hi: w.hi, kind: .word)
            if inFlag, w.text.count == 1, w.text.first!.isLetter {
                piece.glueBefore = true
            } else {
                inFlag = false
            }
            pieces.append(piece)
            i += 1
        }
        return pieces
    }

    /// Builds output spans: pieces glued together become one merged span covering every input
    /// span they consumed; deletions/spaces attach to the neighbouring span.
    static func rebuild(_ pieces: [CodePiece], from spans: [TranscriptSpan], stage: StageID) -> [TranscriptSpan] {
        struct Acc { var text: String; var lo: Int; var hi: Int; var frozen: Bool; var glueAfter: Bool; var pendingSpace: Bool }
        var out: [TranscriptSpan] = []
        var acc: Acc?

        func flush() {
            guard let a = acc else { return }
            out.append(makeSpan(text: a.text, lo: a.lo, hi: a.hi, frozen: a.frozen, spans: spans, stage: stage))
            acc = nil
        }

        for piece in pieces {
            if piece.kind == .deleted || piece.kind == .space {
                if acc != nil {
                    acc!.hi = max(acc!.hi, piece.hi)
                    if piece.kind == .space { acc!.pendingSpace = true }
                } else {
                    acc = Acc(text: "", lo: piece.lo, hi: piece.hi, frozen: false, glueAfter: false, pendingSpace: piece.kind == .space)
                }
                continue
            }
            if var a = acc {
                let glued = !a.pendingSpace && (piece.glueBefore || a.glueAfter)
                let merge = a.text.isEmpty || glued || piece.lo <= a.hi
                if merge {
                    if !a.text.isEmpty { a.text += glued ? "" : " " }
                    a.text += piece.text
                    a.hi = max(a.hi, piece.hi)
                    a.frozen = a.frozen || piece.kind == .frozen
                    a.glueAfter = piece.glueAfter
                    a.pendingSpace = false
                    acc = a
                    continue
                }
                flush()
            }
            acc = Acc(text: piece.text, lo: piece.lo, hi: piece.hi, frozen: piece.kind == .frozen, glueAfter: piece.glueAfter, pendingSpace: false)
        }
        flush()
        return out
    }

    static func makeSpan(text: String, lo: Int, hi: Int, frozen: Bool, spans: [TranscriptSpan], stage: StageID) -> TranscriptSpan {
        if lo == hi {
            let source = spans[lo]
            if frozen { return source.flaggedForRepair(by: stage) }
            return text == source.text ? source.touched(by: stage) : source.rewritten(text, by: stage)
        }
        let parts = spans[lo...hi]
        return TranscriptSpan(
            text: text,
            confidence: parts.map(\.confidence).min() ?? 0,
            audioRange: parts.first!.audioRange.lowerBound...parts.last!.audioRange.upperBound,
            alternates: parts.flatMap(\.alternates),
            provenance: spans[lo].provenance + [stage],
            needsRepair: frozen || parts.contains(where: \.needsRepair)
        )
    }
}
