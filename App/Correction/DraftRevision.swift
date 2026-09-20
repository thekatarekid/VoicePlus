import Foundation
import Engine
import Shared

/// Rebase only unchanged UTF-16 runs. Changed words lose their uncertainty; retained words keep
/// their evidence and alternatives. Never put presentation annotations into the payload.
public enum DraftRevision {
    public static func mapping(_ original: MarkMapping, edited: String) -> MarkMapping {
        let before = Array(original.text.utf16), after = Array(edited.utf16)
        let changes = after.difference(from: before)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in changes {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        let oldIndices = before.indices.filter { !removed.contains($0) }
        let newIndices = after.indices.filter { !inserted.contains($0) }
        let positions = Dictionary(uniqueKeysWithValues: zip(oldIndices, newIndices))
        let marks = original.marks.compactMap { mark -> UncertainMark? in
            guard !mark.range.isEmpty, let start = positions[mark.range.lowerBound],
                  mark.range.enumerated().allSatisfy({ positions[$0.element] == start + $0.offset }) else { return nil }
            var mapped = mark
            mapped.range = start..<(start + mark.range.count)
            guard (edited as NSString).substring(with: NSRange(mapped.range)) == mark.text else { return nil }
            if mark.kind == .word {
                guard MarkWords.words(in: edited).contains(where: { $0.core == mapped.range }) else { return nil }
            }
            return mapped
        }
        return MarkMapping(text: edited, marks: marks, confidenceAvailable: original.confidenceAvailable)
    }

    public static func spans(for mapping: MarkMapping, source: [TranscriptSpan] = []) -> [TranscriptSpan] {
        let text = mapping.text as NSString
        var result: [TranscriptSpan] = [], cursor = 0
        func append(_ range: Range<Int>, mark: UncertainMark? = nil) {
            guard !range.isEmpty else { return }
            let evidence = mark?.sourceSpans.compactMap { source.indices.contains($0) ? source[$0] : nil }
                .first(where: { UncertaintyMarkMapper.carriesConfidence($0) })
            result.append(TranscriptSpan(text: text.substring(with: NSRange(range)), confidence: mark?.confidence ?? 1,
                                         audioRange: evidence?.audioRange ?? 0...0, alternates: mark?.alternatives.map { Alternate(text: $0, score: 0.5, source: .beam) } ?? [],
                                         provenance: [.asr], stability: .final))
        }
        for mark in mapping.marks.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            guard mark.range.lowerBound >= cursor, mark.range.upperBound <= text.length else { continue }
            append(cursor..<mark.range.lowerBound)
            append(mark.range, mark: mark)
            cursor = mark.range.upperBound
        }
        append(cursor..<text.length)
        return result
    }
    public static func indexing(_ mapping: MarkMapping, spans: [TranscriptSpan]) -> MarkMapping {
        var mapping = mapping
        var offset = 0
        for (index, span) in spans.enumerated() {
            let range = offset..<(offset + span.text.utf16.count)
            for mark in mapping.marks.indices where mapping.marks[mark].range == range {
                mapping.marks[mark].sourceSpans = [index]
            }
            offset = range.upperBound
        }
        return mapping
    }

}

/// Accepted lexical additions become manageable Dictionary entries, never global replacement rules.
/// A failed write leaves the correction intact and reports session-only retention to the notch.
public final class DraftVocabularyLearner {
    private let database: AppDatabase?
    public private(set) var sessionTerms: Set<String> = []
    public init(database: AppDatabase?) { self.database = database }

    public static func addedTerms(original: String, edited: String) -> [String] {
        let old = Set(MarkWords.words(in: original).compactMap { MarkWords.slice(original, $0.core)?.lowercased() })
        var seen = Set<String>()
        return MarkWords.words(in: edited).compactMap { MarkWords.slice(edited, $0.core) }.filter {
            let key = $0.lowercased()
            return $0.unicodeScalars.contains(where: CharacterSet.letters.contains)
                && !old.contains(key) && seen.insert(key).inserted
        }
    }

    @discardableResult
    public func learn(original: String, edited: String) -> Bool {
        let terms = Self.addedTerms(original: original, edited: edited)
        guard !terms.isEmpty else { return true }
        sessionTerms.formUnion(terms)
        guard let database else { return false }
        do {
            let existing = Set(try database.dictionaryTerms().map { $0.term.lowercased() })
            for term in terms where !existing.contains(term.lowercased()) {
                try database.save(DictionaryRecord(term: term))
            }
            return true
        } catch { return false }
    }
}
