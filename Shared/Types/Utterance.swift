import Foundation

/// One hotkey press-to-release (or one endpointed segment in ambient mode).
public struct Utterance: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// Detected target register (what kind of text field / app we are dictating into).
    public enum Register: String, Codable, CaseIterable, Sendable {
        case email, chat, code, prose, terminal, list, unknown
    }

    /// What the gatekeeper decided to do with this utterance.
    public enum Route: String, Codable, CaseIterable, Sendable {
        case dictate, repairCommand, transform, question, none
    }

    public var id: UUID
    public var spans: [TranscriptSpan]
    public var startedAt: Date
    public var endedAt: Date?
    public var register: Register
    public var route: Route

    public init(
        id: UUID = UUID(),
        spans: [TranscriptSpan] = [],
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        register: Register = .unknown,
        route: Route = .none
    ) {
        self.id = id
        self.spans = spans
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.register = register
        self.route = route
    }

    public var text: String { spans.joinedText }
    public var duration: TimeInterval? { endedAt.map { $0.timeIntervalSince(startedAt) } }
}
