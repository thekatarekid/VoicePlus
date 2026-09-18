import AppKit
import ApplicationServices
import Foundation
import Injection
import ObjectiveC
import Pipeline
import Shared

/// D5 (V4.16) — the element a landing went into: app, AX role and the element's AX hash
/// (`FocusSnapshot.elementToken`, `CFHash` of the focused element in the live app).
public struct LandedElement: Hashable, Sendable {
    public var bundleID: String
    public var role: String?
    public var elementToken: String

    public init(bundleID: String, role: String?, elementToken: String) {
        self.bundleID = bundleID
        self.role = role
        self.elementToken = elementToken
    }

    /// `nil` when the element cannot be told apart from another (no AX hash).
    public init?(focus: FocusSnapshot?, role: String?) {
        guard let focus, let token = focus.elementToken, !token.isEmpty, !focus.bundleID.isEmpty else { return nil }
        self.init(bundleID: focus.bundleID, role: role, elementToken: token)
    }
}

/// How our own last landing ended — which decides how the next one joins onto it.
public enum LandingEnding: String, Sendable, Equatable, CaseIterable {
    /// Ended on a word or a non-terminal mark: the next one gets a space and a lowercase start.
    case word
    /// Ended on whitespace: no space is added.
    case space
    /// Ended a sentence: a space and a capital.
    case terminal

    public init?(of text: String) {
        guard let last = text.last else { return nil }
        if last.isWhitespace { self = .space }
        else if ContinuationPlanner.endsSentence(text) { self = .terminal }
        else { self = .word }
    }
}

public struct LandingRecord: Equatable, Sendable {
    public var element: LandedElement
    /// Exactly what was sent, continuation whitespace included.
    public var text: String
    public var ending: LandingEnding
    public var at: Date
}

/// Anything the user does that may have moved the caret away from where our text left it.
public enum LandingInvalidation: String, Sendable, Equatable, CaseIterable {
    case mouseDown, scroll, keyDown, appSwitch
    /// Our own edit elsewhere (a voice repair, a transform) changed the text around the caret.
    case otherEdit
}

/// Delivers `LandingInvalidation`s. The live one is `LiveLandingInputMonitor`; tests call
/// `LandingMemory.invalidate(_:)` directly or install a fake.
public protocol LandingInputMonitor: AnyObject {
    func start(_ handler: @escaping @Sendable (LandingInvalidation) -> Void)
    func stop()
    /// Called on every landing; lets a monitor pick up a permission granted since it started.
    func refresh()
}

public extension LandingInputMonitor {
    func refresh() {}
}

/// D5 (V4.16) — remember our own last landing.
///
/// Many apps (Electron, canvas-backed web editors) expose neither a caret range nor text markers,
/// so every dictation there is `unknown`: no leading space. When the previous VoicePlus insertion
/// went into the same element less than 30 s ago and the user has not clicked, scrolled, typed or
/// switched apps since, the caret is still where we left it: `FieldContextReader` then reads
/// `known(before: <our text>, after: "")` and the next dictation joins with one space or none,
/// by how our text ended.
public final class LandingMemory: @unchecked Sendable {
    public static let lifetime: TimeInterval = 30

    private let lock = NSLock()
    private var current: LandingRecord?
    private var monitor: LandingInputMonitor?
    private var lastReason: LandingInvalidation?
    public let clock: @Sendable () -> Date
    /// How much of our text is carried as "text before the caret".
    public var window: Int = CaretWindow.defaultWindow

    public init(clock: @escaping @Sendable () -> Date = { Date() }) {
        self.clock = clock
    }

    deinit { monitor?.stop() }

    /// Remembers `text` as the last landing into `element`. Empty text is not a landing.
    public func record(text: String, in element: LandedElement) {
        guard let ending = LandingEnding(of: text) else { return }
        let monitor = lock.withLock { () -> LandingInputMonitor? in
            current = LandingRecord(element: element, text: text, ending: ending, at: clock())
            lastReason = nil
            return self.monitor
        }
        monitor?.refresh()
    }

    /// The still-valid last landing, if any (expired records are dropped on read).
    public var last: LandingRecord? {
        lock.withLock { validRecordLocked() }
    }

    /// Why the memory was last cleared by user input; `nil` after a new landing.
    public var lastInvalidation: LandingInvalidation? { lock.withLock { lastReason } }

    /// The caret our last landing left in `element`: `known(before: <our text>, after: "")`, or
    /// `nil` when the landing was elsewhere, too old, or the user has touched anything since.
    public func caret(for element: LandedElement) -> CaretState? {
        lock.withLock {
            guard let record = validRecordLocked(), record.element == element else { return nil }
            return .known(before: CaretWindow.tail(of: record.text, window: window), after: "")
        }
    }

    public func invalidate(_ reason: LandingInvalidation) {
        lock.withLock {
            guard current != nil else { return }
            current = nil
            lastReason = reason
        }
    }

    /// Starts `monitor`, replacing any previous one.
    public func startMonitoring(_ monitor: LandingInputMonitor) {
        let previous = lock.withLock { () -> LandingInputMonitor? in
            let old = self.monitor
            self.monitor = monitor
            return old
        }
        previous?.stop()
        monitor.start { [weak self] reason in self?.invalidate(reason) }
    }

    public func stopMonitoring() {
        let previous = lock.withLock { () -> LandingInputMonitor? in
            let old = monitor
            monitor = nil
            return old
        }
        previous?.stop()
    }

    public var isMonitoring: Bool { lock.withLock { monitor != nil } }

    private func validRecordLocked() -> LandingRecord? {
        guard let record = current else { return nil }
        guard clock().timeIntervalSince(record.at) < Self.lifetime else {
            current = nil
            return nil
        }
        return record
    }

    // MARK: - One memory per SystemAccess

    private static let associationKey = UnsafeRawPointer(UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1))
    private static let attachLock = NSLock()

    /// The memory shared by everything that reads and writes through `system`: the lander that
    /// records landings and the `FieldContextReader` that consults them are built separately
    /// (`AppContainer`) but over the same `SystemAccess`, so this is where they meet. Lives as
    /// long as `system`. Over `LiveSystemAccess` it watches real input (`LiveLandingInputMonitor`);
    /// over a mock it watches nothing and tests invalidate it by hand.
    public static func attached(to system: SystemAccess) -> LandingMemory {
        attachLock.withLock {
            if let existing = objc_getAssociatedObject(system, associationKey) as? LandingMemory { return existing }
            let memory = LandingMemory()
            if system is LiveSystemAccess { memory.startMonitoring(LiveLandingInputMonitor()) }
            objc_setAssociatedObject(system, associationKey, memory, .OBJC_ASSOCIATION_RETAIN)
            return memory
        }
    }
}

/// NSEvent global monitors + app activation.
///
/// Mouse-down (any button), scroll and app activation are watched always; key-down only with
/// Accessibility trust (macOS delivers global key events to trusted processes only). Without
/// trust the memory therefore relies on mouse, app switch and the 30 s lifetime. Global monitors
/// never see events aimed at VoicePlus's own windows, and key events VoicePlus itself posted
/// (keystroke insertion, ⌘V) are ignored by source process.
public final class LiveLandingInputMonitor: LandingInputMonitor {
    private var handler: (@Sendable (LandingInvalidation) -> Void)?
    private var monitors: [Any] = []
    private var keyMonitor: Any?
    private var activation: NSObjectProtocol?
    private let isTrusted: () -> Bool

    public init(isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() }) {
        self.isTrusted = isTrusted
    }

    public func start(_ handler: @escaping @Sendable (LandingInvalidation) -> Void) {
        onMain {
            self.removeAll()
            self.handler = handler
            let mouse: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            if let m = NSEvent.addGlobalMonitorForEvents(matching: mouse, handler: { _ in handler(.mouseDown) }) {
                self.monitors.append(m)
            }
            if let m = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel, handler: { _ in handler(.scroll) }) {
                self.monitors.append(m)
            }
            self.activation = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in handler(.appSwitch) }
            self.installKeyMonitorIfTrusted()
        }
    }

    public func refresh() {
        onMain { self.installKeyMonitorIfTrusted() }
    }

    public func stop() {
        onMain { self.removeAll() }
    }

    private func installKeyMonitorIfTrusted() {
        guard keyMonitor == nil, let handler, isTrusted() else { return }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            guard !Self.isOwnEvent(event) else { return }
            handler(.keyDown)
        }
    }

    /// Posted by this process (keystroke insertion, paste): not the user moving the caret.
    static func isOwnEvent(_ event: NSEvent) -> Bool {
        guard let cg = event.cgEvent else { return false }
        return cg.getIntegerValueField(.eventSourceUnixProcessID) == Int64(ProcessInfo.processInfo.processIdentifier)
    }

    private func removeAll() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
        activation = nil
        handler = nil
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}
