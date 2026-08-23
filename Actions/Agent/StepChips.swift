import Foundation

/// "The plan is chips, not a log": current glows, done shrink, upcoming ghosted. Pure UI model fed by the backend.
public struct StepChip: Equatable, Sendable, Identifiable {
    public enum State: Equatable, Sendable { case done, current, upcoming, failed, cancelled, rolledBack }
    public let id: String
    public let title: String
    public var state: State
    public var scale: Double { switch state { case .done, .rolledBack: return 0.8; case .current: return 1.0; default: return 0.9 } }
    public var opacity: Double { switch state { case .upcoming: return 0.45; case .cancelled: return 0.3; default: return 1 } }
    public var glows: Bool { state == .current }
}

public struct StepChipsModel: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case idle, thinking, acting, awaitingConfirmation(String), halted, finished }
    public var phase: Phase = .idle
    public var chips: [StepChip] = []
    public init() {}
    /// Pill caption: deterministic actions are silent; the agent is legible.
    public var pillText: String {
        switch phase {
        case .idle: return ""; case .thinking: return "thinking…"; case .acting: return chips.first { $0.state == .current }?.title ?? "acting…"
        case .awaitingConfirmation(let t): return "confirm: \(t)"; case .halted: return "stopped"; case .finished: return "done"
        }
    }
    public mutating func load(_ plan: StepPlan) { chips = plan.steps.map { StepChip(id: $0.id, title: $0.title, state: .upcoming) }; phase = .acting }
    public mutating func set(_ id: String, _ s: StepChip.State) { if let i = chips.firstIndex(where: { $0.id == id }) { chips[i].state = s } }
    public mutating func cancelUpcoming() { for i in chips.indices where chips[i].state == .upcoming || chips[i].state == .current { chips[i].state = .cancelled } }
}
