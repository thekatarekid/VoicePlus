import Foundation

/// G0.1 — where the insertion point is in the destination field (V4.2, Build doc V4 §2).
///
/// Three-valued on purpose. The V3 bug was a missing selection range read as "the caret is at the
/// end of the value", which made every dictation into a populated page start with a space and a
/// capital. The rule this type exists to carry:
///
/// - `known(before:after:)` — a caret range was read; `before`/`after` are the text either side of
///   it (bounded windows, not necessarily the whole value).
/// - `endOfField(before:)` — a caret range was read **and** it sits at the end of the value. Only a
///   reader that actually saw a range may produce this; never map a missing range here.
/// - `unknown` — no caret could be read. Consumers must not invent context: no leading space, no
///   capital, no period (V4.2, D3).
public enum CaretState: Equatable, Hashable, Sendable, CustomStringConvertible {
    case known(before: String, after: String)
    case endOfField(before: String)
    case unknown

    /// Text before the caret; `nil` when the caret is `unknown`. Optional so a caller cannot
    /// read "no caret" as "empty field" by accident.
    public var textBefore: String? {
        switch self {
        case .known(let before, _), .endOfField(let before): return before
        case .unknown: return nil
        }
    }

    /// Text after the caret; `""` at the end of the field, `nil` when the caret is `unknown`.
    public var textAfter: String? {
        switch self {
        case .known(_, let after): return after
        case .endOfField: return ""
        case .unknown: return nil
        }
    }

    /// True when a caret range was actually read (`known` or `endOfField`).
    public var hasCaret: Bool { self != .unknown }

    public var isUnknown: Bool { self == .unknown }

    public var isEndOfField: Bool {
        if case .endOfField = self { return true }
        return false
    }

    /// Stable discriminator; also what logs and persisted rows carry.
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case known, endOfField, unknown
    }

    public var kind: Kind {
        switch self {
        case .known: return .known
        case .endOfField: return .endOfField
        case .unknown: return .unknown
        }
    }

    /// Log-friendly and content-free: carries lengths, never the user's text.
    public var description: String {
        switch self {
        case .known(let before, let after): return "known(before: \(before.count), after: \(after.count))"
        case .endOfField(let before): return "endOfField(before: \(before.count))"
        case .unknown: return "unknown"
        }
    }
}

extension CaretState: Codable {
    private enum CodingKeys: String, CodingKey { case kind, before, after }

    /// `{"kind":"known","before":"…","after":"…"}` · `{"kind":"endOfField","before":"…"}` ·
    /// `{"kind":"unknown"}`. Missing text decodes as `""`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let before = try c.decodeIfPresent(String.self, forKey: .before) ?? ""
        switch try c.decode(Kind.self, forKey: .kind) {
        case .known:
            self = .known(before: before, after: try c.decodeIfPresent(String.self, forKey: .after) ?? "")
        case .endOfField:
            self = .endOfField(before: before)
        case .unknown:
            self = .unknown
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        switch self {
        case .known(let before, let after):
            try c.encode(before, forKey: .before)
            try c.encode(after, forKey: .after)
        case .endOfField(let before):
            try c.encode(before, forKey: .before)
        case .unknown:
            break
        }
    }
}
