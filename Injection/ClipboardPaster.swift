import Foundation
import Shared

/// Layer ④: paste via the pasteboard, then put the user's clipboard back exactly (all items, all types,
/// images included). The restore is skipped — never clobbering — if `changeCount` shows anything else
/// wrote to the pasteboard after us (clipboard managers, the user copying mid-paste).
public final class ClipboardPaster {
    public enum RestoreResult: Equatable, Sendable { case restored, skippedChangeCountMismatch, nothingToRestore }

    private let system: SystemAccess
    public var settleMilliseconds = 60

    public init(system: SystemAccess) { self.system = system }

    @discardableResult
    public func paste(_ text: String, toPID pid: Int32) throws -> RestoreResult {
        let saved = system.readPasteboard()
        let ours = system.writePasteboard(string: text)
        do {
            try system.postKeyCombo(.paste, toPID: pid)
        } catch {
            _ = restore(saved, ourChangeCount: ours)
            throw error
        }
        system.settle(milliseconds: settleMilliseconds)   // let the target app consume the paste before we swap back
        return restore(saved, ourChangeCount: ours)
    }

    private func restore(_ saved: PasteboardSnapshot, ourChangeCount: Int) -> RestoreResult {
        guard system.pasteboardChangeCount == ourChangeCount else {
            Log.injection.warning("pasteboard changed during paste; leaving it alone")
            return .skippedChangeCountMismatch
        }
        system.restorePasteboard(saved)
        return saved.items.isEmpty ? .nothingToRestore : .restored
    }
}
