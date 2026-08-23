import ApplicationServices
import Foundation

/// `AXNodeAccess` over real `AXUIElement`s. Every call is guarded by `AXIsProcessTrusted()` and returns `nil`
/// rather than throwing when an app does not implement an attribute (Electron, Java, canvases).
public final class LiveAXNodeAccess: AXNodeAccess {
    public init() {}

    public var isTrusted: Bool { AXIsProcessTrusted() }

    public func windows(pid: Int32) -> [AXNodeRef] {
        guard isTrusted else { return [] }
        let app = AXUIElementCreateApplication(pid)
        let list = copy(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        return list.map(ref)
    }

    public func focusedWindow(pid: Int32) -> AXNodeRef? {
        guard isTrusted, let w = copy(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute) else { return nil }
        // swiftlint:disable:next force_cast
        return ref(w as! AXUIElement)
    }

    public func windowID(of node: AXNodeRef) -> AXWindowID? {
        guard let element = element(node) else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        // CGWindowID needs the private _AXUIElementGetWindow; the element hash is stable for the window's lifetime.
        return AXWindowID(pid: pid, windowNumber: Int(truncatingIfNeeded: CFHash(element)))
    }

    public func role(of node: AXNodeRef) -> String {
        element(node).flatMap { copy($0, kAXRoleAttribute) as? String } ?? "unknown"
    }

    public func title(of node: AXNodeRef) -> String? {
        element(node).flatMap { copy($0, kAXTitleAttribute) as? String }
    }

    public func children(of node: AXNodeRef) -> [AXNodeRef] {
        guard let element = element(node) else { return [] }
        return (copy(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).map(ref)
    }

    public func value(of node: AXNodeRef) -> String? {
        element(node).flatMap { copy($0, kAXValueAttribute) as? String }
    }

    public func numberOfCharacters(of node: AXNodeRef) -> Int? {
        element(node).flatMap { copy($0, kAXNumberOfCharactersAttribute) as? Int }
    }

    public func visibleCharacterRange(of node: AXNodeRef) -> Range<Int>? {
        guard let element = element(node), let v = copy(element, kAXVisibleCharacterRangeAttribute) else { return nil }
        var r = CFRange()
        // swiftlint:disable:next force_cast
        guard AXValueGetValue(v as! AXValue, .cfRange, &r) else { return nil }
        return r.location..<(r.location + r.length)
    }

    public func string(of node: AXNodeRef, range: Range<Int>) -> String? {
        guard let element = element(node) else { return nil }
        var cf = CFRange(location: range.lowerBound, length: range.count)
        guard let param = AXValueCreate(.cfRange, &cf) else { return nil }
        var out: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, param, &out)
        guard err == .success else { return nil }
        if let s = out as? String { return s }
        return (out as? NSAttributedString)?.string
    }

    public func observe(window: AXWindowID, handler: @escaping (AXChangeEvent) -> Void) -> AXObservationToken? {
        guard isTrusted else { return nil }
        return LiveObservation(window: window, handler: handler)
    }

    // MARK: Plumbing

    private func ref(_ element: AXUIElement) -> AXNodeRef { AXNodeRef(id: String(CFHash(element)), raw: element) }

    private func element(_ node: AXNodeRef) -> AXUIElement? {
        guard isTrusted, let raw = node.raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast
        return (raw as! AXUIElement)
    }

    private func copy(_ element: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attr as CFString, &v) == .success ? v : nil
    }
}

/// One `AXObserver` on the window's application; any value/focus/destroy notification maps to the window.
final class LiveObservation: AXObservationToken {
    private static let notifications = [
        kAXValueChangedNotification, kAXFocusedUIElementChangedNotification,
        kAXFocusedWindowChangedNotification, kAXUIElementDestroyedNotification,
    ]
    private var observer: AXObserver?
    private let app: AXUIElement
    let window: AXWindowID
    let handler: (AXChangeEvent) -> Void

    init?(window: AXWindowID, handler: @escaping (AXChangeEvent) -> Void) {
        self.window = window
        self.handler = handler
        self.app = AXUIElementCreateApplication(window.pid)
        var obs: AXObserver?
        let callback: AXObserverCallback = { _, _, name, refcon in
            guard let refcon else { return }
            let me = Unmanaged<LiveObservation>.fromOpaque(refcon).takeUnretainedValue()
            let n = name as String
            if n == kAXUIElementDestroyedNotification { me.handler(.windowDestroyed(me.window)) }
            else if n == kAXValueChangedNotification { me.handler(.valueChanged(me.window)) }
            else { me.handler(.focusChanged(me.window)) }
        }
        guard AXObserverCreate(window.pid, callback, &obs) == .success, let obs else { return nil }
        observer = obs
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for n in Self.notifications { AXObserverAddNotification(obs, app, n as CFString, refcon) }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
    }

    func cancel() {
        guard let obs = observer else { return }
        for n in Self.notifications { AXObserverRemoveNotification(obs, app, n as CFString) }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = nil
    }

    deinit { cancel() }
}

// MARK: - SystemAccess conformances (additive; SystemAccess itself is untouched)

extension LiveSystemAccess: AXReaderProviding {
    /// A fresh cached reader per access; callers that need cache continuity should hold onto it.
    public var axReader: AXReading { CachedAXReader(access: LiveAXNodeAccess()) }
}
