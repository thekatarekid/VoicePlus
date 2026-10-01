import Foundation
import Shared

/// V5 E3 — the ITN an email or URL box needs: one compact, lowercase token.
///
/// "jo dot smith at example dot com" → `jo.smith@example.com`; "example dot com slash pricing" →
/// `example.com/pricing`. The spans are merged into one (the value is one word): confidence is
/// the lowest of them, the audio range spans all of them, provenance is the union — nothing is
/// dropped. A low-confidence span blocks the rewrite (`ConfidenceContract`): the words are left as
/// heard for the user to check, never compacted into an address that looks certain.
public enum FieldValueCompactor {
    public static let stageID: StageID = "formatter.fieldValue"

    static let symbols: [String: String] = [
        "dot": ".", "period": ".", "point": ".", "underscore": "_", "dash": "-", "hyphen": "-",
        "minus": "-", "slash": "/", "colon": ":", "plus": "+",
    ]

    public static func compact(_ spans: [TranscriptSpan], kind: FieldInputKind) -> [TranscriptSpan] {
        guard kind == .email || kind == .url, !spans.isEmpty,
              !spans.contains(where: \.isLowConfidence) else { return spans }
        let words = spans.flatMap { $0.text.split(whereSeparator: \.isWhitespace).map(String.init) }
        var out = ""
        var sawAt = false
        var index = 0
        while index < words.count {
            let raw = words[index]
            let word = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",;!?\"'"))
            let bare = word.hasSuffix(".") && index == words.count - 1 ? String(word.dropLast()) : word
            if kind == .email, bare == "at", !sawAt, !out.isEmpty {
                out += "@"; sawAt = true
            } else if bare == "forward", index + 1 < words.count, words[index + 1].lowercased().hasPrefix("slash") {
                out += "/"; index += 1
            } else if let symbol = symbols[bare], !out.isEmpty {
                out += symbol
            } else {
                if bare.contains("@") { sawAt = true }
                out += bare
            }
            index += 1
        }
        // Only an address-shaped result is written: otherwise the box is left as heard.
        let shaped = kind == .email ? (out.contains("@") && out.contains(".")) : out.contains(".")
        guard shaped, !out.contains(" ") else { return spans }
        let first = spans[0], last = spans[spans.count - 1]
        var provenance: [StageID] = []
        for span in spans { for stage in span.provenance where !provenance.contains(stage) { provenance.append(stage) } }
        provenance.append(stageID)
        let merged = TranscriptSpan(
            text: out,
            confidence: spans.map(\.confidence).min() ?? first.confidence,
            audioRange: min(first.audioRange.lowerBound, last.audioRange.lowerBound)...max(first.audioRange.upperBound, last.audioRange.upperBound),
            alternates: [],
            provenance: provenance,
            needsRepair: spans.contains(where: \.needsRepair),
            stability: first.stability,
            punctuationOrigin: first.punctuationOrigin)
        return [merged]
    }
}
