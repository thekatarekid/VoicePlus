import Foundation

/// R2.1 — identity of one closed audio segment (Build doc §2).
///
/// A segment is the audio `[t0, t1]` closed by key release (hold) or by endpoint (latch).
/// `sessionID` identifies the dictation session; `index` counts segments inside it from 0.
///
/// Used to order the commit queue, to reject stale engine results, and to make sure the
/// same segment is never delivered twice.
///
/// **Comparison:** `Comparable` exists only so segments can be sorted and stored in
/// ordered containers. Comparing two IDs from *different* sessions is meaningless — the
/// ordering between sessions is an arbitrary (but stable and total) tiebreak on the UUID.
/// Callers that care must gate on `isSameSession(as:)` first, or use `precedes(_:)`,
/// which returns `nil` across sessions instead of inventing an answer.
public struct SegmentID: Codable, Sendable, Hashable, Comparable, CustomStringConvertible {
    /// The dictation session this segment belongs to.
    public var sessionID: UUID
    /// Segment number inside the session, counting from 0.
    public var index: Int

    public init(sessionID: UUID, index: Int) {
        self.sessionID = sessionID
        self.index = index
    }

    /// The first segment of a session.
    public static func first(in sessionID: UUID) -> SegmentID {
        SegmentID(sessionID: sessionID, index: 0)
    }

    /// The next segment in the same session.
    public var next: SegmentID { SegmentID(sessionID: sessionID, index: index + 1) }

    /// True when both IDs belong to the same dictation session. Order between two IDs
    /// is only meaningful when this is true.
    public func isSameSession(as other: SegmentID) -> Bool { sessionID == other.sessionID }

    /// `true` / `false` when both IDs are in the same session, `nil` when they are not —
    /// so a caller can tell "earlier" from "not comparable".
    public func precedes(_ other: SegmentID) -> Bool? {
        guard isSameSession(as: other) else { return nil }
        return index < other.index
    }

    /// Total order: index inside a session, arbitrary-but-stable UUID order across
    /// sessions. See the type doc — cross-session ordering carries no meaning.
    public static func < (lhs: SegmentID, rhs: SegmentID) -> Bool {
        if lhs.sessionID == rhs.sessionID { return lhs.index < rhs.index }
        return lhs.sessionID.uuidString < rhs.sessionID.uuidString
    }

    /// Short, log-friendly form: `1a2b3c4d#3`.
    public var description: String {
        "\(sessionID.uuidString.prefix(8))#\(index)"
    }
}
