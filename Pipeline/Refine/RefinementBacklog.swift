// VoicePlus original (task R5.2). The bounded backlog from V3 §10.2.
import Foundation

/// How many segments may be waiting on refinement at once (V3 §10.2:
/// "Qwen, earlier segments · off the critical path · backlog ≤ 2 segments, else commit pass-1").
///
/// One instance is shared by every `RefineStage` in a session — it is the thing that keeps a slow
/// second pass from turning into an unbounded queue when the user keeps talking. A segment that
/// cannot be admitted is not queued and not delayed: it commits pass-1 immediately.
public actor RefinementBacklog {
    /// V3 §10.2.
    public static let defaultLimit = 2

    public let limit: Int
    private var inFlight = 0
    private var admitted = 0
    private var rejected = 0

    public init(limit: Int = RefinementBacklog.defaultLimit) {
        self.limit = max(0, limit)
    }

    /// Segments currently being refined.
    public var depth: Int { inFlight }
    /// Segments that were let in (cumulative).
    public var admittedCount: Int { admitted }
    /// Segments that were turned away and committed pass-1 (cumulative).
    public var rejectedCount: Int { rejected }

    /// Take a slot, or refuse. `false` means "commit pass-1 rather than queueing".
    public func admit() -> Bool {
        guard inFlight < limit else {
            rejected += 1
            return false
        }
        inFlight += 1
        admitted += 1
        return true
    }

    /// Give a slot back. Safe to call more often than `admit` returned true.
    public func release() {
        inFlight = max(0, inFlight - 1)
    }
}
