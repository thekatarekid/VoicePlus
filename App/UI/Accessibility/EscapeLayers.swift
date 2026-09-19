import AppKit
import Combine
import Shared
import SwiftUI

// S10 — Escape and focus (design §11): "Escape dismisses a popover before cancelling a parent
// operation … focus returns to the originating word or screen. No global key swallowing."
//
// During a turn Escape is a system-wide hot key (I2, `EscapeHotkey`), so it reaches VoicePlus before
// any window does — including a popover shown over the turn (the correction popover on the final
// preview, the onboarding review). `EscapeLayerStack` is the list of such layers, newest last: a press
// closes the newest layer and stops there, so the turn is only cancelled by the press after that.
// Outside a turn nothing is registered and every Escape goes to whoever has focus.

/// Open layers Escape closes first, newest on top. Popovers register themselves through
/// `observePopovers` (every `NSPopover`, including SwiftUI's `.popover`); a custom panel (e.g. an
/// `NSPanel` popover) calls `push` when shown and `remove` when closed.
public final class EscapeLayerStack {
    public static let shared = EscapeLayerStack()

    public struct Layer {
        public let id: ObjectIdentifier
        let dismiss: () -> Void
    }

    public private(set) var layers: [Layer] = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    public init() {}

    deinit { observers.forEach { $0.0.removeObserver($0.1) } }

    public var isEmpty: Bool { layers.isEmpty }
    public var topID: ObjectIdentifier? { layers.last?.id }

    /// A layer opened. Re-pushing an open layer moves it to the top.
    public func push(_ id: ObjectIdentifier, dismiss: @escaping () -> Void) {
        layers.removeAll { $0.id == id }
        layers.append(Layer(id: id, dismiss: dismiss))
    }

    /// A layer closed (by Escape, a button, or a click outside).
    public func remove(_ id: ObjectIdentifier) {
        layers.removeAll { $0.id == id }
    }

    /// One Escape press: closes the newest layer and reports that it consumed the press. `false`
    /// when nothing is open — the press is the turn's.
    @discardableResult
    public func dismissTop() -> Bool {
        guard let top = layers.popLast() else { return false }
        top.dismiss()
        return true
    }

    /// Follows every `NSPopover` in the process. Idempotent per center.
    public func observePopovers(center: NotificationCenter = .default) {
        guard !observers.contains(where: { $0.0 === center }) else { return }
        observers.append((center, center.addObserver(forName: NSPopover.willShowNotification, object: nil,
                                                     queue: nil) { [weak self] note in
            guard let popover = note.object as? NSPopover else { return }
            self?.push(ObjectIdentifier(popover)) { [weak popover] in popover?.performClose(nil) }
        }))
        observers.append((center, center.addObserver(forName: NSPopover.didCloseNotification, object: nil,
                                                     queue: nil) { [weak self] note in
            guard let popover = note.object as? NSPopover else { return }
            self?.remove(ObjectIdentifier(popover))
        }))
    }
}

// MARK: - Focus returns to where it came from

/// Where keyboard focus goes back to when something opened from it closes: the row a turn detail
/// was opened from, the word a popover was opened on (design §11). A stack, so nested openings
/// unwind in order; a target that no longer exists is skipped by the view that owns it.
public final class FocusReturn: ObservableObject {
    /// Today's rows → turn detail → back.
    public static let today = FocusReturn()

    private var origins: [String] = []
    /// The target to focus now; views with that id take focus when it is published.
    @Published public private(set) var restoreTarget: String?

    public init() {}

    public var pending: [String] { origins }

    /// Something opened from `origin` (a row id, a word id).
    public func opened(from origin: String) {
        origins.append(origin)
    }

    /// The thing opened last closed: focus goes back to where it was opened from.
    @discardableResult
    public func closed() -> String? {
        let origin = origins.popLast()
        restoreTarget = origin
        return origin
    }

    /// Send focus to `target` now (the closing view knows where it was opened from).
    public func restore(_ target: String) {
        restoreTarget = target
    }

    /// The target took focus.
    public func restored(_ target: String) {
        if restoreTarget == target { restoreTarget = nil }
    }
}

/// Makes a view the place focus returns to for `id`.
struct FocusReturnTarget: ViewModifier {
    let id: String
    @ObservedObject var center: FocusReturn
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focusable()
            .focused($focused)
            // The view focus returns to is often re-created by the close itself (turn detail → Today):
            // it finds the request on appearing; a view already on screen hears it change.
            .onAppear { DispatchQueue.main.async { take(center.restoreTarget) } }
            .onChange(of: center.restoreTarget) { _, target in take(target) }
    }

    private func take(_ target: String?) {
        guard target == id else { return }
        focused = true
        center.restored(id)
    }
}

/// Focus ids on Today.
public enum TodayFocus {
    /// A recent-dictation row.
    public static func row(_ id: TurnID) -> String { "today.turn.\(id.rawValue.uuidString)" }
}

extension View {
    /// `row.focusReturnTarget(TodayFocus.row(id), in: .today)`.
    func focusReturnTarget(_ id: String, in center: FocusReturn) -> some View {
        modifier(FocusReturnTarget(id: id, center: center))
    }
}
