import Foundation
import Shared

/// R2.5 — what the pill should offer when a repair could not be applied.
///
/// `Actions` never touches the pill: it produces this value and hands it to a
/// `RepairSuggestionPresenter`. The App layer (R2.4) renders `pillLine` / `detail` / `actionTitle`.
public struct RepairSuggestion: Equatable, Sendable, Identifiable {
    public enum Reason: Equatable, Sendable {
        /// The region no longer reads what we wrote. The document was not touched.
        case regionChanged(actual: String?)
        /// AX could not read the destination. The document was not touched.
        case regionUnreadable(String)
        /// Nothing has been committed yet in this session.
        case noCommittedRegion
        /// A non-repair utterance came in between, so the repair context is gone.
        case contextExpired
        /// "put it back" with no repair on record.
        case nothingToPutBack
        /// "scratch that" with nothing left to scratch.
        case nothingToScratch
        /// The writer refused at write time (destination moved between read and write).
        case editRefused(String)

        /// True when the reason is "the text is not where we left it".
        public var isRegionMismatch: Bool {
            switch self {
            case .regionChanged, .regionUnreadable, .editRefused: return true
            case .noCommittedRegion, .contextExpired, .nothingToPutBack, .nothingToScratch: return false
            }
        }
    }

    public var id: UUID
    public var command: RepairVoiceCommand
    public var segment: SegmentID?
    public var reason: Reason
    /// The committed text the command was bound to, when there was one.
    public var was: String?
    /// What the user asked for: the replacement, or "" for a scratch.
    public var proposed: String?
    public var destination: RepairDestination?
    public var at: Date

    public init(id: UUID = UUID(), command: RepairVoiceCommand, segment: SegmentID?, reason: Reason,
                was: String? = nil, proposed: String? = nil, destination: RepairDestination? = nil, at: Date = Date()) {
        self.id = id
        self.command = command
        self.segment = segment
        self.reason = reason
        self.was = was
        self.proposed = proposed
        self.destination = destination
        self.at = at
    }

    /// Headline. Says what happened, in the app's voice: honest, and never claims an edit.
    public var pillLine: String {
        switch reason {
        case .regionChanged, .editRefused:
            switch command {
            case .scratchThat: return "Text changed — nothing scratched"
            case .replaceWith: return "Text changed — nothing replaced"
            case .putItBack: return "Text changed — nothing put back"
            }
        case .regionUnreadable:
            return "Can't read \(destination?.displayName ?? "the field") — nothing changed"
        case .noCommittedRegion:
            return "Nothing dictated yet"
        case .contextExpired:
            return "Too late to repair that"
        case .nothingToPutBack:
            return "Nothing to put back"
        case .nothingToScratch:
            return "Nothing to scratch"
        }
    }

    /// Second line: names the action the user can take (V3 §6 error copy rule).
    public var detail: String {
        switch reason {
        case .regionChanged(let actual):
            let now = (actual?.isEmpty == false) ? " It now reads “\(Self.trim(actual!))”." : ""
            return "\(suggestedFix)\(now)"
        case .editRefused, .regionUnreadable:
            return suggestedFix
        case .noCommittedRegion, .contextExpired:
            return "Say it again and it will land fresh."
        case .nothingToPutBack:
            return "No repair on record for this segment."
        case .nothingToScratch:
            return "The last thing dictated is already gone."
        }
    }

    /// What to offer instead of the edit.
    private var suggestedFix: String {
        switch command {
        case .scratchThat:
            return "Select the text and delete it yourself."
        case .replaceWith(let replacement):
            return "Suggested: “\(Self.trim(replacement))” — copy it or say it again."
        case .putItBack:
            return was.map { "Was: “\(Self.trim($0))” — copy it or say it again." } ?? "Copy the earlier text or say it again."
        }
    }

    /// Button title for the pill's one action, when the App layer offers one.
    public var actionTitle: String? {
        switch (reason, command) {
        case (.noCommittedRegion, _), (.contextExpired, _), (.nothingToPutBack, _), (.nothingToScratch, _): return nil
        case (_, .scratchThat): return nil
        case (_, .replaceWith): return "Copy replacement"
        case (_, .putItBack): return was == nil ? nil : "Copy original text"
        }
    }

    /// Text the pill's action puts on the clipboard, if any. Copy is the only escape hatch:
    /// repair never re-edits text it cannot verify.
    public var copyPayload: String? {
        switch command {
        case .scratchThat: return nil
        case .replaceWith(let replacement): return replacement
        case .putItBack: return was
        }
    }

    private static func trim(_ text: String, limit: Int = 48) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }
}

/// R2.4 integration point: the App layer conforms (or uses `RepairCommandCoordinator.onSuggestion`)
/// and renders the suggestion in the pill. Nothing in `Actions` knows the pill exists.
public protocol RepairSuggestionPresenter: AnyObject, Sendable {
    func present(_ suggestion: RepairSuggestion)
}

/// A repair that landed.
public struct RepairApplication: Equatable, Sendable {
    public var command: RepairVoiceCommand
    public var segment: SegmentID
    /// Range of the new text in the destination.
    public var range: Range<Int>
    public var was: String
    public var now: String
    /// False when the write was posted but readback could not confirm it.
    public var verified: Bool
    /// Ledger entry recorded for this repair (nil for a "put it back", which closes one).
    public var recordID: UUID?
    public var revertedRecordID: UUID?

    public init(command: RepairVoiceCommand, segment: SegmentID, range: Range<Int>, was: String, now: String,
                verified: Bool, recordID: UUID? = nil, revertedRecordID: UUID? = nil) {
        self.command = command
        self.segment = segment
        self.range = range
        self.was = was
        self.now = now
        self.verified = verified
        self.recordID = recordID
        self.revertedRecordID = revertedRecordID
    }
}

/// The outcome of handing one finalized utterance to the repair coordinator.
public enum RepairDecision: Equatable, Sendable {
    /// A repair command, applied. The utterance must not also be dictated.
    case applied(RepairApplication)
    /// A repair command that could not be applied safely. Document untouched; the pill shows
    /// the suggestion. The utterance is still consumed — it was a command, not text.
    case suggested(RepairSuggestion)
    /// Not a repair. The caller dictates `text` as usual. `quotedCommand` is set when the user
    /// said one of the three commands inside quotes (R2.5 task 4: quoted commands are text).
    case dictation(text: String, quotedCommand: RepairVoiceCommand?)

    /// True when the repair path consumed the utterance and it must not be injected as text.
    public var consumedUtterance: Bool {
        switch self {
        case .applied, .suggested: return true
        case .dictation: return false
        }
    }

    public var suggestion: RepairSuggestion? { if case .suggested(let s) = self { return s } else { return nil } }
    public var application: RepairApplication? { if case .applied(let a) = self { return a } else { return nil } }
}

/// R2.5 — the three repair commands, bound to the last committed segment's text region.
///
/// Rules, all enforced here:
/// 1. `scratch that`, `no, <replacement>`, `put it back` act on the **last committed region only**.
/// 2. An edit happens **only if that region still matches** an AX read of the destination
///    (`RepairRegionReader`). Otherwise nothing is touched and a `RepairSuggestion` is produced.
/// 3. `CorrectionLedger` (via `RepairLedgerRecording`) is the record that makes "put it back"
///    possible — repair never asks a beam decoder for anything.
/// 4. A command inside quotes is dictation.
/// 5. The repair context expires after the next non-repair utterance.
///
/// The only mutation available to this type is `RepairRangeEdit` — a range replacement guarded by
/// `expected`. There is no path here that simulates deletes, rewrites the element's whole value to
/// retract text, or sends the system undo shortcut (V3 §12.2).
public final class RepairCommandCoordinator: @unchecked Sendable {
    public var reader: RepairRegionReader?
    public var editor: RepairRangeEditing?
    public let ledger: RepairLedgerRecording
    public var now: @Sendable () -> Date
    /// R2.4 wires the pill here (or conforms to `RepairSuggestionPresenter` and sets `presenter`).
    public var onSuggestion: (@Sendable (RepairSuggestion) -> Void)?
    public weak var presenter: (any RepairSuggestionPresenter)?

    private let lock = NSLock()
    private var region: CommittedTextRegion?
    /// Segment of the region that a non-repair utterance retired, so the copy can say "too late"
    /// instead of "nothing dictated yet".
    private var expiredSegment: SegmentID?
    private var _lastDecision: RepairDecision?

    public init(reader: RepairRegionReader? = nil, editor: RepairRangeEditing? = nil,
                ledger: RepairLedgerRecording = InMemoryRepairLedger(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.reader = reader
        self.editor = editor
        self.ledger = ledger
        self.now = now
    }

    // MARK: - Context

    /// Called after a segment's text has been delivered. Provisional regions are ignored:
    /// repair binds to committed text only.
    @discardableResult
    public func committed(_ region: CommittedTextRegion) -> Bool {
        guard region.isBindable else { return false }
        lock.lock(); defer { lock.unlock() }
        // Never step backwards inside a session (a late duplicate must not rebind the context).
        if let current = self.region, current.segment.precedes(region.segment) == false { return false }
        self.region = region
        expiredSegment = nil
        return true
    }

    /// The region a repair command would act on right now.
    public var activeRegion: CommittedTextRegion? { lock.withLock { region } }
    public var lastDecision: RepairDecision? { lock.withLock { _lastDecision } }

    /// Retire the repair context: a non-repair utterance, a focus change, or session end.
    public func expire() {
        lock.withLock {
            expiredSegment = region?.segment ?? expiredSegment
            region = nil
        }
    }

    // MARK: - Handling one utterance

    /// Classify `text` and, when it is one of the three commands, act on it.
    @discardableResult
    public func handle(_ text: String) -> RepairDecision {
        let classification = RepairCommandGrammar.classify(text)
        guard let command = classification.command else {
            // Rule 5: any non-repair utterance — a quoted command included — expires the context.
            expire()
            let decision = RepairDecision.dictation(text: text, quotedCommand: classification.quotedCommand)
            lock.withLock { _lastDecision = decision }
            return decision
        }
        let decision = apply(command)
        lock.withLock { _lastDecision = decision }
        return decision
    }

    /// Act on an already-classified command (used by the App layer when routing decided).
    @discardableResult
    public func apply(_ command: RepairVoiceCommand) -> RepairDecision {
        let decision: RepairDecision
        switch command {
        case .scratchThat: decision = edit(command, replacement: "")
        case .replaceWith(let replacement): decision = edit(command, replacement: replacement)
        case .putItBack: decision = putItBack(command)
        }
        if let suggestion = decision.suggestion { publish(suggestion) }
        lock.withLock { _lastDecision = decision }
        return decision
    }

    // MARK: - The three commands

    private func edit(_ command: RepairVoiceCommand, replacement: String) -> RepairDecision {
        guard let target = activeRegion else { return .suggested(suggestion(command, reason: missingContextReason())) }
        if case .scratchThat = command, target.text.isEmpty {
            return .suggested(suggestion(command, region: target, reason: .nothingToScratch, proposed: replacement))
        }
        if let read = verify(target, command: command, proposed: replacement) { return read }
        guard let editor else {
            return .suggested(suggestion(command, region: target, reason: .editRefused("no destination"), proposed: replacement))
        }
        let request = RepairRangeEdit(range: target.range, expected: target.text, replacement: replacement,
                                      segment: target.segment, destination: target.destination)
        let outcome = editor.apply(request)
        switch outcome {
        case .mismatch(let actual):
            return .suggested(suggestion(command, region: target, reason: .regionChanged(actual: actual), proposed: replacement))
        case .unavailable(let reason):
            return .suggested(suggestion(command, region: target, reason: .editRefused(reason), proposed: replacement))
        case .replaced(let verified):
            let updated = target.replacing(replacement)
            let entry = RepairLedgerEntry(segment: target.segment, range: updated.range, was: target.text,
                                          now: replacement, at: now(), isRevertable: true, destination: target.destination)
            ledger.record(entry)
            lock.withLock { region = updated; expiredSegment = nil }
            return .applied(RepairApplication(command: command, segment: target.segment, range: updated.range,
                                              was: target.text, now: replacement, verified: verified, recordID: entry.id))
        }
    }

    private func putItBack(_ command: RepairVoiceCommand) -> RepairDecision {
        let target = activeRegion
        guard let entry = ledger.latestRevertable(segment: target?.segment) else {
            let reason: RepairSuggestion.Reason = target == nil ? missingContextReason() : .nothingToPutBack
            return .suggested(suggestion(command, region: target, reason: reason))
        }
        // "put it back" verifies the region the *repair* left behind, not the original landing.
        let verifyRegion = entry.regionToVerify(stability: target?.stability ?? .committed)
        if let read = verify(verifyRegion, command: command, proposed: entry.was, was: entry.was) { return read }
        guard let editor else {
            return .suggested(suggestion(command, region: verifyRegion, reason: .editRefused("no destination"),
                                         proposed: entry.was, was: entry.was))
        }
        let request = RepairRangeEdit(range: entry.range, expected: entry.now, replacement: entry.was,
                                      segment: entry.segment, destination: entry.destination)
        let outcome = editor.apply(request)
        switch outcome {
        case .mismatch(let actual):
            return .suggested(suggestion(command, region: verifyRegion, reason: .regionChanged(actual: actual),
                                         proposed: entry.was, was: entry.was))
        case .unavailable(let reason):
            return .suggested(suggestion(command, region: verifyRegion, reason: .editRefused(reason),
                                         proposed: entry.was, was: entry.was))
        case .replaced(let verified):
            ledger.markReverted(entry.id)
            // History keeps the revert, but it is not itself revertable: "put it back" twice
            // reaches the repair before it, never a toggle.
            let restored = verifyRegion.replacing(entry.was)
            ledger.record(RepairLedgerEntry(segment: entry.segment, range: restored.range, was: entry.now,
                                            now: entry.was, at: now(), isRevertable: false, destination: entry.destination))
            lock.withLock { region = restored; expiredSegment = nil }
            return .applied(RepairApplication(command: command, segment: entry.segment, range: restored.range,
                                              was: entry.now, now: entry.was, verified: verified,
                                              revertedRecordID: entry.id))
        }
    }

    // MARK: - Helpers

    /// Non-nil when the region does not still match: the caller must not touch the document.
    private func verify(_ target: CommittedTextRegion, command: RepairVoiceCommand,
                        proposed: String?, was: String? = nil) -> RepairDecision? {
        guard let reader else {
            return .suggested(suggestion(command, region: target, reason: .regionUnreadable("no destination reader"),
                                         proposed: proposed, was: was))
        }
        switch reader.read(target) {
        case .matches:
            return nil
        case .changed(let actual):
            return .suggested(suggestion(command, region: target, reason: .regionChanged(actual: actual),
                                         proposed: proposed, was: was))
        case .unreadable(let reason):
            return .suggested(suggestion(command, region: target, reason: .regionUnreadable(reason),
                                         proposed: proposed, was: was))
        }
    }

    private func missingContextReason() -> RepairSuggestion.Reason {
        lock.withLock { expiredSegment == nil ? .noCommittedRegion : .contextExpired }
    }

    private func suggestion(_ command: RepairVoiceCommand, region: CommittedTextRegion? = nil,
                            reason: RepairSuggestion.Reason, proposed: String? = nil, was: String? = nil) -> RepairSuggestion {
        let segment = region?.segment ?? lock.withLock { expiredSegment }
        return RepairSuggestion(command: command, segment: segment, reason: reason,
                                was: was ?? region?.text, proposed: proposed,
                                destination: region?.destination, at: now())
    }

    private func publish(_ suggestion: RepairSuggestion) {
        onSuggestion?(suggestion)
        presenter?.present(suggestion)
    }
}
