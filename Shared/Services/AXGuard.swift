#if canImport(ApplicationServices)
import ApplicationServices
import Foundation

/// K18 — the one place AX roots are created outside `Injection`.
///
/// FX1 found the onboarding freeze: an AX call into **our own** process from a background thread
/// runs our AppKit handlers on that thread and deadlocks. `LiveSystemAccess` has guarded its own
/// calls since then; every other AX caller (selection detection, the tape flight, destination
/// marks, recovery, repair, actions, deixis, biasing) now goes through these guards too:
///
/// - **own pid → refuse.** `application(pid:)` never hands out our own app element, and
///   `admit(_:)` drops an element that resolves to our process when we are off the main thread.
/// - **main thread → hop.** `ownProcessRead` runs work that must touch our own element on the
///   main thread (bounded wait), never on the caller's background thread.
///
/// Lives in `Shared` (not `Injection`) because `Pipeline`, `Engine` and `Actions` cannot import
/// `Injection`. A source-audit test asserts no `AXUIElementCreateApplication(` /
/// `AXUIElementCreateSystemWide(` exists outside this file, `LiveSystemAccess` and `LiveAXNodeAccess`.
public enum AXGuard {
    public static let ownPID: Int32 = ProcessInfo.processInfo.processIdentifier

    /// The app element for `pid`, or `nil` for VoicePlus itself (own pid → refuse).
    public static func application(pid: Int32) -> AXUIElement? {
        guard pid > 0, pid != ownPID else { return nil }
        return AXUIElementCreateApplication(pid)
    }

    /// The system-wide root. Anything copied from it may belong to our own process: pass the
    /// result through `admit(_:)` before reading it.
    public static func systemWide() -> AXUIElement { AXUIElementCreateSystemWide() }

    public static func pid(of element: AXUIElement) -> Int32? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    /// True when the element lives in VoicePlus's own process.
    public static func isOwn(_ element: AXUIElement) -> Bool { pid(of: element) == ownPID }

    /// `element`, unless it is ours and we are off the main thread (own pid → refuse).
    public static func admit(_ element: AXUIElement?) -> AXUIElement? {
        guard let element else { return nil }
        return isOwnOffMain(element) ? nil : element
    }

    /// The pure rule, for tests: an own-process element read off the main thread is refused.
    public static func refuses(elementPID: Int32?, ownPID: Int32 = AXGuard.ownPID, isMainThread: Bool) -> Bool {
        elementPID == ownPID && !isMainThread
    }

    static func isOwnOffMain(_ element: AXUIElement) -> Bool {
        refuses(elementPID: pid(of: element), isMainThread: Thread.isMainThread)
    }

    /// The system-wide focused element, admitted (`nil` when untrusted, absent, or ours off-main).
    public static func focusedElement() -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide(), kAXFocusedUIElementAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return admit((ref as! AXUIElement))
    }

    /// The element at a screen point (top-left origin), admitted.
    public static func element(atX x: Float, y: Float) -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide(), x, y, &hit) == .success else { return nil }
        return admit(hit)
    }

    /// Main thread → hop: runs `work` on the main thread when the caller is off it, waiting at most
    /// `timeout`. `nil` when the main thread did not take it in time (the work is then skipped).
    public static func onMain<T>(timeout: TimeInterval = 1.0, _ work: @escaping () -> T?) -> T? {
        if Thread.isMainThread { return work() }
        let box = HopBox<T>()
        DispatchQueue.main.async {
            guard box.begin() else { return }
            box.finish(work())
        }
        if box.started.wait(timeout: .now() + max(0, timeout)) == .timedOut, box.cancel() { return nil }
        box.done.wait()
        return box.value
    }

    private final class HopBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var state = 0   // 0 pending, 1 running, 2 cancelled
        private(set) var value: T?
        let started = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)

        func begin() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard state == 0 else { return false }
            state = 1
            started.signal()
            return true
        }
        func cancel() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard state == 0 else { return false }
            state = 2
            return true
        }
        func finish(_ value: T?) {
            self.value = value
            done.signal()
        }
    }
}
#endif
