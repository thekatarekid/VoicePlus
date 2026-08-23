import Foundation
import Shared

/// Writing system of a character / word. Combining marks and digits inherit from their neighbours.
public enum Script: String, Codable, Hashable, Sendable, CaseIterable {
    case latin, devanagari, other
    /// Punctuation, whitespace, digits, combining marks — takes the script of its word.
    case neutral

    public static func of(_ scalar: Unicode.Scalar) -> Script {
        switch scalar.value {
        case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x024F: return .latin
        case 0x0900...0x097F, 0xA8E0...0xA8FF:
            // Danda/double danda are punctuation; matras/nukta are marks → neutral.
            if scalar.value == 0x0964 || scalar.value == 0x0965 { return .neutral }
            return scalar.properties.generalCategory.isMark ? .neutral : .devanagari
        default:
            if scalar.properties.isAlphabetic { return .other }
            return .neutral
        }
    }

    /// Dominant script of a word (majority of non-neutral scalars; `.neutral` if none).
    public static func dominant(in text: String) -> Script {
        var counts: [Script: Int] = [:]
        for s in text.unicodeScalars {
            let sc = of(s)
            if sc != .neutral { counts[sc, default: 0] += 1 }
        }
        return counts.max { a, b in a.value < b.value }?.key ?? .neutral
    }
}

private extension Unicode.GeneralCategory {
    var isMark: Bool { self == .nonspacingMark || self == .spacingMark || self == .enclosingMark }
}

/// Spoken language inferred for a word or utterance (script-independent: romanized Hindi is Hindi).
public enum SpokenLanguage: String, Codable, Hashable, Sendable {
    case english, hindi
    /// Hindi + English mixed within one utterance ("Hinglish").
    case mixed
    case unknown
}

/// Contiguous run of spans in one script, ready for injection. The App hands `[ScriptSegment]`
/// to the Injection module (Engine cannot import Injection), which may pick a per-script input
/// source or simply type `text`.
public struct ScriptSegment: Codable, Equatable, Sendable {
    public var text: String
    public var script: Script
    public var language: SpokenLanguage
    public var audioRange: ClosedRange<TimeInterval>
    /// Indices into the merged utterance's span array.
    public var spanIndices: [Int]

    public init(text: String, script: Script, language: SpokenLanguage,
                audioRange: ClosedRange<TimeInterval>, spanIndices: [Int]) {
        self.text = text; self.script = script; self.language = language
        self.audioRange = audioRange; self.spanIndices = spanIndices
    }
}

/// Output of `ScriptAwareMerger`: one injectable string plus the per-script segments behind it.
public struct ScriptSegments: Codable, Equatable, Sendable {
    public var text: String
    public var segments: [ScriptSegment]
    public var spans: [TranscriptSpan]
    public var language: SpokenLanguage

    public var scripts: Set<Script> { Set(segments.map(\.script)) }
    public var isCodeSwitched: Bool { scripts.subtracting([.neutral]).count > 1 }
}
