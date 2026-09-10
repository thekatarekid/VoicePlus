import Foundation
import Shared

/// R2.5 — the committed text region a repair command is bound to: one closed segment's text,
/// at the UTF-16 range where it landed in the destination.
///
/// Only `committed` (or `final`) text is repairable. Provisional preview text is not in the
/// document yet, so there is nothing to repair.
public struct CommittedTextRegion: Equatable, Sendable {
    public var segment: SegmentID
    public var stability: Stability
    /// UTF-16 range in the destination element's value.
    public var range: Range<Int>
    /// Exactly what we wrote there. The repair only proceeds while the destination still reads this.
    public var text: String
    public var destination: RepairDestination?
    public var at: Date

    public init(segment: SegmentID, stability: Stability = .committed, range: Range<Int>, text: String,
                destination: RepairDestination? = nil, at: Date = Date()) {
        self.segment = segment
        self.stability = stability
        self.range = range
        self.text = text
        self.destination = destination
        self.at = at
    }

    /// Repair binds to committed text only.
    public var isBindable: Bool { stability >= .committed }
    /// UTF-16 length of `text`; the range should agree with it.
    public var length: Int { text.utf16.count }
    /// Same region, after `replacement` took the place of `text`.
    public func replacing(_ replacement: String) -> CommittedTextRegion {
        var next = self
        next.text = replacement
        next.range = range.lowerBound..<(range.lowerBound + replacement.utf16.count)
        return next
    }
}

/// Where the committed text lives, for suggestion copy ("Notes") and for noticing that the
/// destination is not the one we wrote into.
public struct RepairDestination: Equatable, Sendable {
    public var bundleID: String?
    /// Stable-ish identity of the focused element, when the AX layer can produce one.
    public var elementID: String?
    /// Human name for the copy: "Notes", "Brave".
    public var label: String?

    public init(bundleID: String? = nil, elementID: String? = nil, label: String? = nil) {
        self.bundleID = bundleID
        self.elementID = elementID
        self.label = label
    }

    public var displayName: String { label ?? bundleID ?? "the field" }
}

// MARK: - Reading the destination back

/// The result of an AX read of the destination over the committed region.
public enum RepairRegionRead: Equatable, Sendable {
    /// The region still reads exactly what we wrote.
    case matches
    /// Someone (user, app, another process) changed it. `actual` is what is there now, if readable.
    case changed(actual: String?)
    /// AX could not be read at all. Treated like `changed`: the document is not touched.
    case unreadable(reason: String)

    public var isMatch: Bool { self == .matches }
}

/// Implemented by the App layer over Injection's AX focused-element read. `Actions` never
/// touches AX itself.
public protocol RepairRegionReader: AnyObject, Sendable {
    func read(_ region: CommittedTextRegion) -> RepairRegionRead
}

/// Region matching over a plain document string — the one place the comparison rule lives, so
/// the live AX reader and the test doubles cannot disagree about it.
public enum RepairRegionMatch {
    public static func slice(_ value: String, _ range: Range<Int>) -> String? {
        let units = Array(value.utf16)
        guard range.lowerBound >= 0, range.upperBound <= units.count, range.lowerBound <= range.upperBound else { return nil }
        return String(decoding: units[range], as: UTF16.self)
    }

    public static func check(_ region: CommittedTextRegion, in document: String?) -> RepairRegionRead {
        guard let document else { return .unreadable(reason: "destination unreadable") }
        guard let actual = slice(document, region.range) else { return .changed(actual: nil) }
        return actual == region.text ? .matches : .changed(actual: actual)
    }
}

/// A reader over a closure that hands back the destination's current whole text.
public final class DocumentTextRegionReader: RepairRegionReader, @unchecked Sendable {
    private let document: @Sendable () -> String?
    public init(document: @escaping @Sendable () -> String?) { self.document = document }
    public func read(_ region: CommittedTextRegion) -> RepairRegionRead {
        RepairRegionMatch.check(region, in: document())
    }
}

// MARK: - The one permitted edit

/// The only mutation repair is allowed to make: replace a range that still reads `expected`.
///
/// V3 §12.2 forbids destructive re-editing of committed text — no simulated deletes, no
/// wholesale rewrite of the element's value to retract text, no system undo shortcut. This
/// type is the entire vocabulary of the repair path, which is why it carries `expected`:
/// the writer refuses the edit when the destination has moved on.
public struct RepairRangeEdit: Equatable, Sendable {
    public var range: Range<Int>
    public var expected: String
    public var replacement: String
    public var segment: SegmentID
    public var destination: RepairDestination?

    public init(range: Range<Int>, expected: String, replacement: String, segment: SegmentID, destination: RepairDestination? = nil) {
        self.range = range
        self.expected = expected
        self.replacement = replacement
        self.segment = segment
        self.destination = destination
    }
}

public enum RepairEditOutcome: Equatable, Sendable {
    /// `verified: false` means the write was posted and a readback could not confirm it —
    /// honest, and never retried with another method (V3 §6 readback rule).
    case replaced(verified: Bool)
    case mismatch(actual: String?)
    case unavailable(reason: String)

    public var succeeded: Bool { if case .replaced = self { return true }; return false }
    public var verified: Bool { if case .replaced(let v) = self { return v }; return false }
}

/// Implemented by the App layer over Injection's range-replace editor.
public protocol RepairRangeEditing: AnyObject, Sendable {
    func apply(_ edit: RepairRangeEdit) -> RepairEditOutcome
}

/// In-memory editor over a document string, applying the same safety rule. Tests, Lab, and a
/// sane default when no destination is wired.
public final class InMemoryRepairEditor: RepairRangeEditing, @unchecked Sendable {
    private let lock = NSLock()
    private var _document: String
    private var _edits: [RepairRangeEdit] = []
    /// Forced outcome for the next call (to exercise the refusal path).
    public var refuseNext: RepairEditOutcome?
    public var verify = true

    public init(document: String = "") { _document = document }

    public var document: String { lock.withLock { _document } }
    public var edits: [RepairRangeEdit] { lock.withLock { _edits } }

    public func apply(_ edit: RepairRangeEdit) -> RepairEditOutcome {
        lock.lock(); defer { lock.unlock() }
        _edits.append(edit)
        if let forced = refuseNext { refuseNext = nil; return forced }
        var units = Array(_document.utf16)
        guard edit.range.lowerBound >= 0, edit.range.upperBound <= units.count else { return .mismatch(actual: nil) }
        let actual = String(decoding: units[edit.range], as: UTF16.self)
        guard actual == edit.expected else { return .mismatch(actual: actual) }
        units.replaceSubrange(edit.range, with: Array(edit.replacement.utf16))
        _document = String(decoding: units, as: UTF16.self)
        return .replaced(verified: verify)
    }

    /// An out-of-band change to the document — the user typing, or another process. Not a repair
    /// path: it exists so tests and Lab can put the destination out of step with what we wrote.
    public func overwrite(_ text: String) { lock.withLock { _document = text } }

    /// A reader onto the same document, so a test can wire both ends consistently.
    public func reader() -> RepairRegionReader {
        DocumentTextRegionReader { [weak self] in self?.document }
    }
}

// MARK: - The record that makes "put it back" possible

/// One repair, as recorded. The App layer backs this with `CorrectionLedger`, which is what
/// V3 §6 asks for: silent correction stays off, but its ledger is the record for "put it back".
public struct RepairLedgerEntry: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var segment: SegmentID
    /// UTF-16 range of `now` in the destination — where the text sits *after* the repair.
    public var range: Range<Int>
    public var was: String
    public var now: String
    public var at: Date
    public var isRevertable: Bool
    public var destination: RepairDestination?

    public init(id: UUID = UUID(), segment: SegmentID, range: Range<Int>, was: String, now: String,
                at: Date = Date(), isRevertable: Bool = true, destination: RepairDestination? = nil) {
        self.id = id
        self.segment = segment
        self.range = range
        self.was = was
        self.now = now
        self.at = at
        self.isRevertable = isRevertable
        self.destination = destination
    }

    /// The region "put it back" has to find intact before it restores `was`.
    public func regionToVerify(stability: Stability = .committed) -> CommittedTextRegion {
        CommittedTextRegion(segment: segment, stability: stability, range: range, text: now, destination: destination, at: at)
    }
}

public protocol RepairLedgerRecording: AnyObject, Sendable {
    func record(_ entry: RepairLedgerEntry)
    /// Newest revertable repair, restricted to `segment` when one is given.
    func latestRevertable(segment: SegmentID?) -> RepairLedgerEntry?
    func markReverted(_ id: UUID)
}

public final class InMemoryRepairLedger: RepairLedgerRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var _entries: [RepairLedgerEntry] = []
    public var maxEntries = 50
    public init() {}

    public var entries: [RepairLedgerEntry] { lock.withLock { _entries } }

    public func record(_ entry: RepairLedgerEntry) {
        lock.withLock {
            _entries.append(entry)
            if _entries.count > maxEntries { _entries.removeFirst(_entries.count - maxEntries) }
        }
    }

    public func latestRevertable(segment: SegmentID?) -> RepairLedgerEntry? {
        lock.withLock {
            _entries.last { $0.isRevertable && (segment == nil || $0.segment == segment!) }
        }
    }

    public func markReverted(_ id: UUID) {
        lock.withLock {
            guard let i = _entries.firstIndex(where: { $0.id == id }) else { return }
            _entries[i].isRevertable = false
        }
    }
}
