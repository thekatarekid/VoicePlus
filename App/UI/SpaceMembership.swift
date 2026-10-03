import AppKit

/// The parts of a window that Space membership needs. `NSWindow` conforms. Tests use fakes.
protocol SpaceMemberWindow: AnyObject {
    var collectionBehavior: NSWindow.CollectionBehavior { get set }
    var isOnActiveSpace: Bool { get }
    var isVisible: Bool { get }
    func orderFrontRegardless()
    /// Sends the window's pending changes (its Space tags among them) to the WindowServer now.
    func commitSpaceTags()
}

extension NSWindow: SpaceMemberWindow {
    /// Verify-notch: AppKit hands collection-behaviour changes to the WindowServer at the next
    /// transaction commit, so two assignments in one run-loop turn coalesce into "no change".
    func commitSpaceTags() { CATransaction.flush() }
}

/// Fix notch (2026-10-03): keeps an all-Spaces window that is ordered out between uses on every Space.
///
/// The pill, the ribbon overlay, the ink overlay and the presence chin all use `.canJoinAllSpaces`
/// and are ordered out between turns. When the Space layout changes (creating or destroying a Space,
/// a full-screen transition, an AirPlay display attaching), the Dock runs
/// `BatchReassociateWindowsToSpace`, which removes every *ordered-out* all-Spaces window from every
/// Space. The window joins Spaces only once, when it is first ordered in, so later
/// `orderFrontRegardless()` calls order it into no Space at all. WindowServer then logs
/// "none→hidden" instead of "none→visible". The owner saw no pill, the presence chin's listening
/// bar instead (the white dot), and a ribbon that was logged as flown but never seen.
///
/// Setting `collectionBehavior` to `[]`, committing that to the WindowServer, and setting it back
/// makes the window rejoin every Space. The commit in between is required: without it AppKit sends
/// both assignments in one transaction, the WindowServer sees no change, and the window stays on no
/// Space (verified 2026-10-03 on macOS 26 with a panel removed from every Space through SkyLight:
/// toggle alone → still on no Space; toggle with a commit → on every Space). `orderIn` does that
/// before ordering a window in. It then checks the active Space and does it once more if the window
/// is still off it. `isOnActiveSpace` catches up with a rejoin only a moment later, so a rejoined
/// window can still read "off" here; a caller that can rebuild its window does so then, because a
/// new window joins every Space when it is first ordered in (and reads "on" at once).
enum SpaceMembership {
    enum Outcome: String, Equatable, Sendable {
        /// On the active Space after the pre-order reassert (the normal case).
        case onActiveSpace
        /// Ordered in off the active Space, then rejoined by a second reassert.
        case rejoined
        /// Still off the active Space: the caller should rebuild the window.
        case offActiveSpace
    }

    /// Sends the all-Spaces tag again. Does nothing for a window that does not join all Spaces.
    static func reassert(_ window: SpaceMemberWindow) {
        let behavior = window.collectionBehavior
        guard behavior.contains(.canJoinAllSpaces) else { return }
        window.collectionBehavior = []
        window.commitSpaceTags()
        window.collectionBehavior = behavior
    }

    /// Orders `windows` in, front-most last, and makes sure they are on the active Space.
    /// A window that is already visible is not reasserted first, so nothing on screen flickers.
    @discardableResult
    static func orderIn(_ windows: [SpaceMemberWindow]) -> Outcome {
        for window in windows where !window.isVisible { reassert(window) }
        windows.forEach { $0.orderFrontRegardless() }
        if windows.allSatisfy(\.isOnActiveSpace) { return .onActiveSpace }
        for window in windows where !window.isOnActiveSpace { reassert(window) }
        return windows.allSatisfy(\.isOnActiveSpace) ? .rejoined : .offActiveSpace
    }
}
