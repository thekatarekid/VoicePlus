import Foundation
import Shared

/// A request to replace a range of text we landed earlier. UTF-16 offsets in the focused
/// element's value, like Injection's `ReplaceRangeRequest` (Injection adapts this 1:1 and
/// applies the Bet 4 safety rule: only touch the document if `expected` is still there).
public struct RepairReplaceRequest: Equatable, Sendable {
    public var range: Range<Int>
    public var expected: String
    public var replacement: String
    public var utteranceID: UUID
    /// Index of the span in the landed utterance (nil for whole-utterance edits).
    public var spanIndex: Int?

    public init(range: Range<Int>, expected: String, replacement: String, utteranceID: UUID, spanIndex: Int? = nil) {
        self.range = range
        self.expected = expected
        self.replacement = replacement
        self.utteranceID = utteranceID
        self.spanIndex = spanIndex
    }
}

public enum RepairReplaceOutcome: Equatable, Sendable {
    case replaced
    /// The document no longer reads as expected; nothing was touched.
    case mismatch(actual: String?)
    case unavailable(reason: String)

    public var succeeded: Bool { self == .replaced }
}

/// Implemented by Injection (`ReplaceRangeEditor`). The engine never touches AX itself.
public protocol ReplaceRangeSink: AnyObject, Sendable {
    func replace(_ request: RepairReplaceRequest) -> RepairReplaceOutcome
}

/// T5 — provenance: every repair is logged (feeds the dictionary and Phase 6 training).
/// Production: `AppDatabase.insert(CorrectionRecord)`.
public protocol CorrectionSink: AnyObject, Sendable {
    func record(_ correction: CorrectionRecord)
}

/// T5 — the zero-edit counter must be decremented honestly when the user repairs by voice.
/// Production: Lab's `ZeroEditTracker` marks the dictation as edited.
public protocol ZeroEditSink: AnyObject, Sendable {
    func markEdited(utteranceID: UUID, wordsEdited: Int, source: String)
}

// MARK: - In-memory implementations (tests, Lab, and a sensible default)

/// Applies requests to an in-memory document string and records them. Mirrors the
/// Bet 4 safety rule so tests exercise the mismatch path too.
public final class InMemoryReplaceRangeSink: ReplaceRangeSink, @unchecked Sendable {
    private let lock = NSLock()
    public private(set) var document: String
    public private(set) var requests: [RepairReplaceRequest] = []
    public var failNext: RepairReplaceOutcome?

    public init(document: String = "") { self.document = document }

    public func replace(_ request: RepairReplaceRequest) -> RepairReplaceOutcome {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        if let forced = failNext { failNext = nil; return forced }
        var units = Array(document.utf16)
        guard request.range.lowerBound >= 0, request.range.upperBound <= units.count else { return .mismatch(actual: nil) }
        let actual = String(decoding: units[request.range], as: UTF16.self)
        guard actual == request.expected else { return .mismatch(actual: actual) }
        units.replaceSubrange(request.range, with: Array(request.replacement.utf16))
        document = String(decoding: units, as: UTF16.self)
        return .replaced
    }
}

public final class InMemoryCorrectionSink: CorrectionSink, @unchecked Sendable {
    private let lock = NSLock()
    public private(set) var records: [CorrectionRecord] = []
    public init() {}
    public func record(_ correction: CorrectionRecord) { lock.withLock { records.append(correction) } }
}

public final class InMemoryZeroEditSink: ZeroEditSink, @unchecked Sendable {
    public struct Event: Equatable, Sendable { public var utteranceID: UUID; public var wordsEdited: Int; public var source: String }
    private let lock = NSLock()
    public private(set) var events: [Event] = []
    public init() {}
    public func markEdited(utteranceID: UUID, wordsEdited: Int, source: String) {
        lock.withLock { events.append(Event(utteranceID: utteranceID, wordsEdited: wordsEdited, source: source)) }
    }
}
