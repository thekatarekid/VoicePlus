import Engine
import Foundation
import Shared

/// P1.5.2 — pure model of what the dual-path reconciler changed, for the UX: the shimmer /
/// underline overlay, hover "was: …", one-tap revert, the "show what changed" menu list and the
/// "put it back" voice undo. No AppKit; `CorrectionOverlayController` renders it.
public struct CorrectionEntry: Equatable, Sendable, Identifiable {
    public enum Status: Equatable, Sendable { case applied, reverted, suggested(String) }
    public var id: UUID
    public var utteranceID: UUID
    public var appBundleID: String?
    /// UTF-16 range of `now` in the field (after the edit).
    public var range: Range<Int>
    public var was: String
    public var now: String
    public var at: Date
    public var status: Status

    public init(id: UUID = UUID(), utteranceID: UUID, appBundleID: String?, range: Range<Int>, was: String, now: String, at: Date, status: Status = .applied) {
        self.id = id; self.utteranceID = utteranceID; self.appBundleID = appBundleID; self.range = range
        self.was = was; self.now = now; self.at = at; self.status = status
    }

    public init(event: CorrectionEvent, appBundleID: String?, at: Date) {
        let status: Status
        switch event.kind {
        case .applied: status = .applied
        case .suggested(let r): status = .suggested(r.rawValue)
        case .refused: status = .suggested("refused")
        }
        self.init(utteranceID: event.utteranceID, appBundleID: appBundleID, range: event.range, was: event.was, now: event.now, at: at, status: status)
    }

    public var isRevertable: Bool { status == .applied }
    /// Hover text.
    public var hoverLabel: String { "was: \(was.isEmpty ? "∅" : was)" }
    /// One line for the menu list.
    public var menuLine: String {
        switch status {
        case .applied: return "\(was.isEmpty ? "∅" : was) → \(now)"
        case .reverted: return "\(was) ← \(now) (put back)"
        case .suggested: return "\(was) → \(now)? (suggested)"
        }
    }
}

/// Visual state of one underline: shimmer for the first beat, then a plain underline until 2 s.
public enum CorrectionHighlightPhase: Equatable, Sendable {
    case shimmer, underline, gone
    public static let shimmerSeconds: TimeInterval = 0.45
    public static let underlineSeconds: TimeInterval = 2.0
    public static func at(_ elapsed: TimeInterval) -> CorrectionHighlightPhase {
        if elapsed < shimmerSeconds { return .shimmer }
        if elapsed < underlineSeconds { return .underline }
        return .gone
    }
}

/// Thread-safe ledger of corrections. Implements `CorrectionEventSink` so the reconciler's
/// applier feeds it directly; the overlay / menu / voice-undo read from it.
public final class CorrectionLedger: CorrectionEventSink, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [CorrectionEntry] = []
    public var now: @Sendable () -> Date = { Date() }
    public var maxEntries = 50
    /// Bundle ID of the app the correction landed in (set by the lander before reconciling).
    public var currentAppBundleID: String?
    /// Fires on the caller's thread for every new entry (overlay hooks here).
    public var onEntry: (@Sendable (CorrectionEntry) -> Void)?
    /// "put it back" window (seconds) — matches the repair window.
    public var undoWindow: TimeInterval = 10

    public init() {}

    public func correction(_ event: CorrectionEvent) {
        let entry = CorrectionEntry(event: event, appBundleID: currentAppBundleID, at: now())
        lock.withLock {
            entries.append(entry)
            if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
        }
        onEntry?(entry)
    }

    public var all: [CorrectionEntry] { lock.withLock { entries } }
    /// Newest first, for the menu.
    public var recent: [CorrectionEntry] { all.reversed() }
    public func entry(id: UUID) -> CorrectionEntry? { lock.withLock { entries.first { $0.id == id } } }

    /// Latest applied, not-yet-reverted correction inside the undo window (voice "put it back").
    public func latestRevertable(at time: Date? = nil) -> CorrectionEntry? {
        let t = time ?? now()
        return lock.withLock { entries.last { $0.isRevertable && t.timeIntervalSince($0.at) <= undoWindow } }
    }

    /// Revert `entry` through `sink`: the document must still read `now` at `range` (safety rule).
    @discardableResult
    public func revert(_ entry: CorrectionEntry, via sink: ReplaceRangeSink) -> RepairReplaceOutcome {
        guard entry.isRevertable else { return .unavailable(reason: "not revertable") }
        let outcome = sink.replace(RepairReplaceRequest(range: entry.range, expected: entry.now, replacement: entry.was, utteranceID: entry.utteranceID))
        if outcome.succeeded {
            lock.withLock {
                guard let i = entries.firstIndex(where: { $0.id == entry.id }) else { return }
                entries[i].status = .reverted
                // Sibling corrections after this one shift by the length delta.
                let delta = entry.was.utf16.count - entry.now.utf16.count
                for j in entries.indices where j != i && entries[j].utteranceID == entry.utteranceID && entries[j].range.lowerBound > entry.range.lowerBound {
                    entries[j].range = (entries[j].range.lowerBound + delta)..<(entries[j].range.upperBound + delta)
                }
            }
        }
        return outcome
    }

    public func clear() { lock.withLock { entries.removeAll() } }
}

/// Per-app off switch (Settings). Key: `corrections.off.<bundleID>`; global: `corrections.enabled`.
public enum CorrectionSettings {
    public static let enabledKey = "corrections.enabled"
    public static func appKey(_ bundleID: String) -> String { "corrections.off.\(bundleID)" }

    public static func isEnabled(for bundleID: String?, store: SettingsStore) -> Bool {
        if store.bool(enabledKey) == false { return false }
        guard let bundleID else { return true }
        return store.bool(appKey(bundleID)) != true
    }

    public static func setEnabled(_ on: Bool, for bundleID: String, store: SettingsStore) {
        store.set(!on, for: appKey(bundleID))
    }
}

/// "put it back" routing: a recent silent correction is undone before the repair session's own
/// undo stack is consulted (the user can see the corrected word; that is what they mean).
public enum CorrectionUndoRouter {
    public enum Outcome: Equatable, Sendable { case revertedCorrection(CorrectionEntry), notACorrection }

    public static func handle(text: String, ledger: CorrectionLedger, sink: ReplaceRangeSink, at time: Date? = nil) -> Outcome {
        guard RepairGrammar.parse(text) == .undo, let entry = ledger.latestRevertable(at: time) else { return .notACorrection }
        let outcome = ledger.revert(entry, via: sink)
        guard outcome.succeeded, let updated = ledger.entry(id: entry.id) else { return .notACorrection }
        return .revertedCorrection(updated)
    }
}
