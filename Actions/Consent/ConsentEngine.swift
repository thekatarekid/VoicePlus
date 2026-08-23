import Foundation

/// Model of the 5-second undo toast. `ring(at:)` is the remaining fraction for the draining ring.
public struct UndoToastModel: Sendable, Equatable {
    public static let duration: TimeInterval = 5
    public let actionID: String
    public let title: String
    public let startedAt: TimeInterval
    public var undone = false
    public var expired = false
    public init(actionID: String, title: String, startedAt: TimeInterval) {
        self.actionID = actionID; self.title = title; self.startedAt = startedAt
    }
    public func ring(at now: TimeInterval) -> Double {
        min(1, max(0, 1 - (now - startedAt) / Self.duration))
    }
    public func isOpen(at now: TimeInterval) -> Bool { !undone && !expired && now - startedAt < Self.duration }
}

/// Slide-out card for an irreversible action. Confirmed only by spoken "confirm" or a click.
public struct ConfirmationCard: Sendable, Equatable {
    public enum State: Sendable, Equatable { case pending, confirmed, cancelled }
    public let actionID: String
    public let title: String
    public let detail: String
    public var state: State = .pending
    public init(actionID: String, title: String, detail: String = "") {
        self.actionID = actionID; self.title = title; self.detail = detail
    }
    /// Spoken confirmation grammar — exact intent words only; "confirm the meeting" does not count.
    public static func isSpokenConfirm(_ utterance: String) -> Bool {
        let w = utterance.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctionationSafe))
        return ["confirm", "yes confirm", "confirmed", "do it"].contains(w)
    }
    public static func isSpokenCancel(_ utterance: String) -> Bool {
        let w = utterance.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctionationSafe))
        return ["cancel", "no", "stop", "abort", "never mind"].contains(w)
    }
}

extension CharacterSet { static let punctionationSafe = CharacterSet.punctuationCharacters }

/// Registry of compensating actions keyed by action id: "undo" for semi-reversible actions
/// (e.g. delete the Slack message just sent). Connectors register theirs at startup.
public final class CompensatingActionRegistry: @unchecked Sendable {
    public typealias Compensator = @Sendable (ConsentRequest, ExecutionReceipt) async throws -> Void
    private var table: [String: Compensator] = [:]
    private let lock = NSLock()
    public init() {}
    public func register(_ id: String, _ c: @escaping Compensator) { lock.lock(); table[id] = c; lock.unlock() }
    public func compensator(for id: String) -> Compensator? { lock.lock(); defer { lock.unlock() }; return table[id] }
    public func canUndo(_ id: String) -> Bool { compensator(for: id) != nil }
}

/// What an executed action returns so its compensator can find it again (message ts, file path…).
public struct ExecutionReceipt: Sendable, Equatable {
    public var handle: String
    public init(handle: String = "") { self.handle = handle }
}

public enum ConsentOutcome: Sendable, Equatable {
    case executed(ExecutionReceipt)
    case executedWithUndo(UndoToastModel, receipt: ExecutionReceipt)
    case awaitingConfirmation(ConfirmationCard)
    case cancelled
}

/// The policy engine. `execute` is the only way an action runs, and it is the single choke point
/// the fuzz test drives: irreversible actions never execute before `confirm(…)`.
public final class ConsentEngine: @unchecked Sendable {
    public typealias Executor = @Sendable (ConsentRequest) async throws -> ExecutionReceipt
    public let classifier: ActionClassifier
    public let registry: CompensatingActionRegistry
    public var now: @Sendable () -> TimeInterval
    private let lock = NSLock()
    private var pendingCards: [UUID: (ConfirmationCard, ConsentRequest, Executor)] = [:]
    private var toasts: [UUID: (UndoToastModel, ConsentRequest, ExecutionReceipt)] = [:]
    /// UI hooks; nil in tests.
    public var onToast: (@Sendable (UUID, UndoToastModel) -> Void)?
    public var onCard: (@Sendable (UUID, ConfirmationCard) -> Void)?

    private func sync<T>(_ f: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return f() }

    public init(classifier: ActionClassifier = ActionClassifier(), registry: CompensatingActionRegistry = .init(),
                now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }) {
        self.classifier = classifier; self.registry = registry; self.now = now
    }

    /// Route an action through the policy. Returns the token for toasts/cards alongside the outcome.
    @discardableResult
    public func submit(_ r: ConsentRequest, execute: @escaping Executor) async throws -> (UUID, ConsentOutcome) {
        let token = UUID()
        switch classifier.classify(r) {
        case .reversible:
            return (token, .executed(try await execute(r)))
        case .semi:
            let receipt = try await execute(r)
            let toast = UndoToastModel(actionID: r.id, title: r.title, startedAt: now())
            sync { toasts[token] = (toast, r, receipt) }
            onToast?(token, toast)
            return (token, .executedWithUndo(toast, receipt: receipt))
        case .irreversible:
            let card = ConfirmationCard(actionID: r.id, title: r.title, detail: "Requires confirmation")
            sync { pendingCards[token] = (card, r, execute) }
            onCard?(token, card)
            return (token, .awaitingConfirmation(card))
        }
    }

    /// Confirm by click (`spoken: nil`) or by utterance (must pass the spoken grammar).
    public func confirm(_ token: UUID, spoken: String? = nil) async throws -> ConsentOutcome {
        if let s = spoken, !ConfirmationCard.isSpokenConfirm(s) {
            if ConfirmationCard.isSpokenCancel(s) { cancel(token) ; return .cancelled }
            let c = sync { pendingCards[token]?.0 }
            return c.map { .awaitingConfirmation($0) } ?? .cancelled
        }
        let entry = sync { pendingCards.removeValue(forKey: token) }
        guard let (_, r, exec) = entry else { return .cancelled }
        return .executed(try await exec(r))
    }

    public func cancel(_ token: UUID) { lock.lock(); pendingCards[token] = nil; lock.unlock() }

    public func pendingCard(_ token: UUID) -> ConfirmationCard? { lock.lock(); defer { lock.unlock() }; return pendingCards[token]?.0 }
    public func toast(_ token: UUID) -> UndoToastModel? { lock.lock(); defer { lock.unlock() }; return toasts[token]?.0 }

    /// Undo within the 5s window via the registered compensator. Returns false when expired or no compensator.
    public func undo(_ token: UUID) async throws -> Bool {
        let t = now()
        let claimed: (ConsentRequest, ExecutionReceipt, CompensatingActionRegistry.Compensator)? = sync {
            guard var (toast, r, receipt) = toasts[token], toast.isOpen(at: t),
                  let comp = registry.compensator(for: r.id) else { return nil }
            toast.undone = true; toasts[token] = (toast, r, receipt)
            return (r, receipt, comp)
        }
        guard let (r, receipt, comp) = claimed else { return false }
        try await comp(r, receipt)
        return true
    }

    /// Expire toasts past the window (call from a UI tick or timer).
    public func expireToasts() {
        lock.lock(); defer { lock.unlock() }
        let t = now()
        for (k, v) in toasts where !v.0.undone && !v.0.isOpen(at: t) { toasts[k] = (v.0.with { $0.expired = true }, v.1, v.2) }
    }
}

private extension UndoToastModel {
    func with(_ f: (inout UndoToastModel) -> Void) -> UndoToastModel { var c = self; f(&c); return c }
}
