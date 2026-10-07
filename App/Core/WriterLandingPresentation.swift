import Foundation
import Shared

// Context Writer — the landing UX (VoicePlus_ContextWriter_Plan.md §4: "no deadline, one landing").
//
// The writer runs inside the lander before anything is typed, so the wait for it *is* the landing
// animation: nothing is typed early and nothing is swapped after it lands. What the pill says about
// it, as data:
//   - a writer slower than `WriterLandingTiming.faceDelay` turns the finishing face into a calm
//     "Writing…" (a fast one never shows it: no flicker);
//   - a writer that changed words leaves "Polished N words" with Undo on the landed row, and the
//     changed words shimmer for ~3 s (a static tint under Reduce Motion);
//   - a writer that timed out or failed leaves "Not polished" with Polish (retry is wave 3).
// Word pairs travel only between the controller and the pill; logs carry counts and reason codes.

/// The timings of the writer's presentation.
public enum WriterLandingTiming {
    /// A writer that finishes within this long of starting never shows "Writing…".
    public static let faceDelay: TimeInterval = 0.150
    /// How long the changed words shimmer in the text lane (a static tint under Reduce Motion).
    public static let shimmerDuration: TimeInterval = 3
    /// How long "Undo" on a polished landing stays possible (the row itself dwells `PillDwell.polished`).
    public static let undoWindow: TimeInterval = 10
}

/// The writer's words on the pill (DESIGN.md §7.1 voice: sentence case, no trailing period, the
/// design's typographic ellipsis).
public enum WriterCopy {
    /// The finishing face while the writer runs.
    public static let writingStatus = "Writing…"
    /// What VoiceOver hears when that face appears.
    public static let writingAnnouncement = "Writing"
    /// "Polished 1 word", "Polished 2 words".
    public static func polished(_ count: Int) -> String {
        "Polished \(count) word\(count == 1 ? "" : "s")"
    }
    /// The writer could not polish this landing: the words landed as heard.
    public static let notPolished = "Not polished"
    public static let undoLabel = "Undo"
    public static let polishLabel = "Polish"
}

/// What the pill knows about the writer for the turn on screen (`PillTurnContext.writer`).
public struct PillWriterNote: Equatable, Sendable {
    public enum Phase: String, Equatable, Sendable {
        /// The writer has run longer than `WriterLandingTiming.faceDelay`: "Writing…".
        case writing
        /// The writer changed `changes` (heard → written).
        case polished
        /// Timeout or failure: the rules text landed, unpolished.
        case unpolished
    }

    public var phase: Phase
    /// Polished: the words the writer changed. Ranges index the landed final text; the pill and the
    /// undo locate each one by its written words before trusting a range (`WriterChangeLocator`).
    public var changes: [WriterChangedWord]
    /// The controller holds a range-safe Undo for every changed word in the field.
    public var undoable: Bool

    public init(phase: Phase, changes: [WriterChangedWord] = [], undoable: Bool = false) {
        self.phase = phase
        self.changes = phase == .polished ? changes : []
        self.undoable = phase == .polished && undoable && !changes.isEmpty
    }

    public static let writing = PillWriterNote(phase: .writing)

    /// The note a finished writer leaves for the landed row; nil when there is nothing to say (the
    /// words are as heard: `unchanged`, `skipped:…`, a guard `rejected:…`, or nothing changed).
    public static func outcome(of event: WriterLandingEvent) -> PillWriterNote? {
        guard case .finished(_, _, let changed, _) = event else { return nil }
        if event.isUnpolished { return PillWriterNote(phase: .unpolished) }
        let real = changed.filter { !$0.written.isEmpty && $0.written != $0.heard }
        return real.isEmpty ? nil : PillWriterNote(phase: .polished, changes: real)
    }

    /// The landed row's note, nil while writing.
    public var landed: LandedWriterNote? {
        switch phase {
        case .writing: return nil
        case .polished: return .polished(count: changes.count, undoable: undoable)
        case .unpolished: return .unpolished
        }
    }
}

/// The writer's line on a landed row (`LandedPillInfo.writer`): the helper line, its one action,
/// and how long the row stays.
public enum LandedWriterNote: Equatable, Sendable {
    case polished(count: Int, undoable: Bool)
    case unpolished

    /// "Polished 2 words" / "Not polished".
    public var line: String {
        switch self {
        case .polished(let count, _): return WriterCopy.polished(count)
        case .unpolished: return WriterCopy.notPolished
        }
    }

    /// Undo (restore what was heard) or Polish (wave 3: retry); none for a polish nothing can undo.
    public var button: PillButton? {
        switch self {
        case .polished(_, let undoable): return undoable ? PillButton(WriterCopy.undoLabel, .undo) : nil
        case .unpolished: return PillButton(WriterCopy.polishLabel, .polish)
        }
    }

    /// The landed row's dwell with this note: long enough to act on the Undo, to see the shimmer,
    /// or to read the note. It is never sticky: the text is in the field and in history.
    public var dwell: TimeInterval {
        switch self {
        case .polished(_, let undoable): return undoable ? PillDwell.undoWindow : WriterLandingTiming.shimmerDuration
        case .unpolished: return PillDwell.transientNotice
        }
    }
}

/// One changed word found in a text: its UTF-16 range there, and the pair.
public struct LocatedWriterChange: Equatable, Sendable {
    public var range: Range<Int>
    public var heard: String
    public var written: String

    public init(range: Range<Int>, heard: String, written: String) {
        self.range = range
        self.heard = heard
        self.written = written
    }
}

/// Finds the writer's changed words in a text. A change's own range is trusted only when the text
/// there is exactly its written words; otherwise the nearest occurrence of the written words on word
/// boundaries that no other change claimed is used; a change that cannot be found is dropped. The
/// result is sorted and never overlaps, so ranges can be drawn and replaced safely.
public enum WriterChangeLocator {
    public static func locate(_ changes: [WriterChangedWord], in text: String) -> [LocatedWriterChange] {
        let units = Array(text.utf16)
        var claimed: [Range<Int>] = []
        var found: [LocatedWriterChange] = []
        func free(_ r: Range<Int>) -> Bool { !claimed.contains { $0.overlaps(r) } }
        for change in changes {
            let written = Array(change.written.utf16)
            guard !written.isEmpty else { continue }
            var hit: Range<Int>?
            if let r = change.range, r.lowerBound >= 0, r.upperBound <= units.count,
               r.count == written.count, Array(units[r]) == written, free(r) {
                hit = r
            } else {
                let anchor = change.range?.lowerBound ?? 0
                hit = occurrences(of: written, in: units)
                    .filter { free($0) && onWordBoundary($0, units) }
                    .min { abs($0.lowerBound - anchor) < abs($1.lowerBound - anchor) }
            }
            guard let hit else { continue }
            claimed.append(hit)
            found.append(LocatedWriterChange(range: hit, heard: change.heard, written: change.written))
        }
        return found.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// `text` with every located change put back to what was heard.
    public static func restoringHeard(_ located: [LocatedWriterChange], in text: String) -> String {
        var units = Array(text.utf16)
        for change in located.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            guard change.range.upperBound <= units.count else { continue }
            units.replaceSubrange(change.range, with: Array(change.heard.utf16))
        }
        return String(decoding: units, as: UTF16.self)
    }

    static func occurrences(of needle: [UInt16], in haystack: [UInt16]) -> [Range<Int>] {
        guard !needle.isEmpty, needle.count <= haystack.count else { return [] }
        var out: [Range<Int>] = []
        var i = 0
        while i + needle.count <= haystack.count {
            if haystack[i] == needle[0], Array(haystack[i..<(i + needle.count)]) == needle {
                out.append(i..<(i + needle.count))
            }
            i += 1
        }
        return out
    }

    static func onWordBoundary(_ r: Range<Int>, _ units: [UInt16]) -> Bool {
        func isWordUnit(_ u: UInt16) -> Bool {
            guard let scalar = Unicode.Scalar(u) else { return true }   // a surrogate half: part of a word
            return CharacterSet.alphanumerics.contains(scalar)
        }
        let before = r.lowerBound == 0 || !isWordUnit(units[r.lowerBound - 1])
        let after = r.upperBound == units.count || !isWordUnit(units[r.upperBound])
        return before && after
    }
}
