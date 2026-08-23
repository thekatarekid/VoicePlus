import Foundation

/// Identifies a pipeline stage. String-backed so new stages can be added without
/// touching `Shared/`; the known constants below are the ones Phase 1 ships with.
public struct StageID: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    // MARK: Known stages (Phase 1)

    public static let asr: StageID = "asr"
    public static let gatekeeper: StageID = "gatekeeper"
    public static let formatterEmail: StageID = "formatter.email"
    public static let formatterChat: StageID = "formatter.chat"
    public static let formatterCode: StageID = "formatter.code"
    public static let formatterProse: StageID = "formatter.prose"
    public static let formatterTerminal: StageID = "formatter.terminal"
    public static let style: StageID = "style"
    public static let biasing: StageID = "biasing"
    public static let repair: StageID = "repair"
    public static let injection: StageID = "injection"

    /// All stage IDs known at P1.0 freeze. Useful for lint/walk tests.
    public static let known: [StageID] = [
        .asr, .gatekeeper, .formatterEmail, .formatterChat, .formatterCode,
        .formatterProse, .formatterTerminal, .style, .biasing, .repair, .injection,
    ]
}
