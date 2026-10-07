import Foundation

// Context Writer (VoicePlus_ContextWriter_Plan.md §4) — what the landing UX hears about the writer.
//
// The writer runs inside the lander's pipeline, before anything is typed (one landing). The App's
// writer wiring posts `started` when the model call begins and `finished` when the stage is done;
// the turn presentation (pill "Writing…", outcome row, changed-word shimmer, undo correction)
// subscribes. Reason codes and word pairs only: the full text never travels on this channel.

public struct WriterChangedWord: Equatable, Sendable {
    /// What the recogniser heard (the span's `.repair` alternate the stage keeps).
    public var heard: String
    /// What the writer wrote.
    public var written: String
    /// UTF-16 range of `written` in the landed final text (`TurnRecord.finalText` contract).
    public var range: Range<Int>?
    public init(heard: String, written: String, range: Range<Int>? = nil) {
        self.heard = heard
        self.written = written
        self.range = range
    }
}

public enum WriterLandingEvent: Equatable, Sendable {
    /// The writer's model call began for this landing. `backend` is `cloud` or `local`.
    case started(landingID: UUID, backend: String)
    /// The writer is done. `outcome` is `WriterOutcome.code` (`accepted`, `unchanged`,
    /// `partiallyReverted:n`, `rejected:…`, `timeout`, `failed:…`, `skipped:…`).
    case finished(landingID: UUID, outcome: String, changed: [WriterChangedWord], ms: Double)

    public var landingID: UUID {
        switch self { case .started(let id, _), .finished(let id, _, _, _): return id }
    }

    /// The writer could not polish this landing (it landed the rules text).
    public var isUnpolished: Bool {
        guard case .finished(_, let outcome, _, _) = self else { return false }
        return outcome == "timeout" || outcome.hasPrefix("failed")
    }
}

/// Process-wide broadcast. Handlers run on the posting thread; UI subscribers hop to main.
public final class WriterLandingEvents: @unchecked Sendable {
    public static let shared = WriterLandingEvents()

    private let lock = NSLock()
    private var handlers: [UUID: @Sendable (WriterLandingEvent) -> Void] = [:]

    public init() {}

    @discardableResult
    public func subscribe(_ handler: @escaping @Sendable (WriterLandingEvent) -> Void) -> UUID {
        let token = UUID()
        lock.withLock { handlers[token] = handler }
        return token
    }

    public func unsubscribe(_ token: UUID) {
        _ = lock.withLock { handlers.removeValue(forKey: token) }
    }

    public func post(_ event: WriterLandingEvent) {
        let current = lock.withLock { Array(handlers.values) }
        for handler in current { handler(event) }
    }
}
