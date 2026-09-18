import Foundation

/// G0.1 — identity of one turn: one press-to-outcome cycle (Build doc V4 §2). Hold = one turn;
/// latch = one turn per segment.
///
/// Every stale async callback (engine final, dwell timer, readback) checks the turn ID before
/// acting, and the commit guard keys on it so a turn inserts at most once (design §12).
/// Encoded as a bare UUID string so logs and persisted rows stay readable.
public struct TurnID: Codable, Sendable, Hashable, CustomStringConvertible {
    public var rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    /// Short, log-friendly form: `1A2B3C4D`.
    public var description: String { String(rawValue.uuidString.prefix(8)) }
}
