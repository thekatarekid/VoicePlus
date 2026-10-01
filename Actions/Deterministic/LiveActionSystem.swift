#if canImport(AppKit) && canImport(ApplicationServices)
import AppKit
import ApplicationServices
import Shared

/// Real macOS backend: NSWorkspace (apps), AX (windows/elements/readback), CGEvent (keys, spaces). Requires Accessibility trust.
public final class LiveActionSystem: ActionSystem {
    private var windowHandles: [Int: AXUIElement] = [:]
    private var elementHandles: [Int: AXUIElement] = [:]
    private var nextID = 1
    private let maxDepth: Int
    public init(maxDepth: Int = 12) { self.maxDepth = maxDepth }

    public var isAvailable: Bool { AXIsProcessTrusted() }

    // MARK: AX helpers
    private func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?; guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }; return v as? T
    }
    private func children(_ el: AXUIElement) -> [AXUIElement] { (attr(el, kAXChildrenAttribute) as [AXUIElement]?) ?? [] }
    private func id(for el: AXUIElement, in table: inout [Int: AXUIElement]) -> Int {
        if let k = table.first(where: { CFEqual($0.value, el) })?.key { return k }
        let k = nextID; nextID += 1; table[k] = el; return k
    }
    private func appElement(_ bundleID: String) -> AXUIElement? {
        // K18 — own pid → refuse.
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first.flatMap { AXGuard.application(pid: $0.processIdentifier) }
    }
    private func ref(_ app: NSRunningApplication) -> AppRef { AppRef(name: app.localizedName ?? "", bundleID: app.bundleIdentifier ?? "") }

    // MARK: ActionSystem
    public func snapshot() -> DesktopSnapshot {
        let front = NSWorkspace.shared.frontmostApplication
        var win: WindowRef?, el: ElementRef?
        if let f = front, let ax = appElement(f.bundleIdentifier ?? "") {
            if let w: AXUIElement = attr(ax, kAXFocusedWindowAttribute) { win = windowRef(w, bundleID: f.bundleIdentifier ?? "") }
            if let e: AXUIElement = attr(ax, kAXFocusedUIElementAttribute) { el = elementRef(e, windowID: win?.id ?? 0) }
        }
        return DesktopSnapshot(frontmostApp: front.map(ref), focusedWindow: win, focusedElement: el, activeSpace: 0)
    }
    public func runningApps() -> [AppRef] { NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map(ref) }
    public func activate(appNamed name: String) throws -> AppRef {
        if let m = FuzzyMatch.best(name, in: runningApps(), label: \.name), let app = NSRunningApplication.runningApplications(withBundleIdentifier: m.item.bundleID).first {
            app.activate(); usleep(150_000); return m.item
        }
        guard let url = Self.appURL(named: name) else { throw ActionSystemError.notFound("app \(name)") }
        let sem = DispatchSemaphore(value: 0); var result: AppRef?
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { app, _ in result = app.map(self.ref); sem.signal() }
        _ = sem.wait(timeout: .now() + 5)
        guard let r = result else { throw ActionSystemError.failed("launch \(name)") }; return r
    }
    private static func appURL(named name: String) -> URL? {
        for dir in ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"] {
            let u = URL(fileURLWithPath: "\(dir)/\(name).app"); if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }
    private func windowRef(_ w: AXUIElement, bundleID: String) -> WindowRef {
        WindowRef(id: id(for: w, in: &windowHandles), appBundleID: bundleID, title: attr(w, kAXTitleAttribute) ?? "", isMinimized: (attr(w, kAXMinimizedAttribute) as Bool?) ?? false)
    }
    public func windows(of app: AppRef) -> [WindowRef] {
        guard let ax = appElement(app.bundleID), let ws: [AXUIElement] = attr(ax, kAXWindowsAttribute) else { return [] }
        return ws.map { windowRef($0, bundleID: app.bundleID) }
    }
    public func raise(_ window: WindowRef) throws {
        guard let w = windowHandles[window.id] else { throw ActionSystemError.notFound("window") }
        NSRunningApplication.runningApplications(withBundleIdentifier: window.appBundleID).first?.activate()
        AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        guard AXUIElementPerformAction(w, kAXRaiseAction as CFString) == .success else { throw ActionSystemError.failed("raise") }
        usleep(100_000)
    }
    public func perform(_ op: WindowOp, on window: WindowRef) throws {
        guard let w = windowHandles[window.id] else { throw ActionSystemError.notFound("window") }
        func pressButton(_ a: String) throws { guard let b: AXUIElement = attr(w, a), AXUIElementPerformAction(b, kAXPressAction as CFString) == .success else { throw ActionSystemError.failed(a) } }
        switch op {
        case .close: try pressButton(kAXCloseButtonAttribute)
        case .minimize: AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        case .restore: AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        case .zoom: try pressButton(kAXZoomButtonAttribute)
        case .fullscreen: try pressButton(kAXFullScreenButtonAttribute)
        }
        usleep(150_000)
    }
    private func elementRef(_ e: AXUIElement, windowID: Int) -> ElementRef {
        let role: String = attr(e, kAXRoleAttribute) ?? ""
        let title = (attr(e, kAXTitleAttribute) as String?).flatMap { $0.isEmpty ? nil : $0 } ?? (attr(e, kAXDescriptionAttribute) as String?) ?? (attr(e, "AXLabel") as String?) ?? ""
        let value = attr(e, kAXValueAttribute) as String? ?? ""
        let enabled = (attr(e, kAXEnabledAttribute) as Bool?) ?? true
        let selected = (attr(e, kAXSelectedAttribute) as Bool?) ?? (role == "AXRadioButton" && (attr(e, kAXValueAttribute) as Int?) == 1)
        return ElementRef(id: id(for: e, in: &elementHandles), windowID: windowID, role: role, title: title, value: value, isEnabled: enabled, isSelected: selected)
    }
    public func elements(in window: WindowRef) -> [ElementRef] {
        guard let w = windowHandles[window.id] else { return [] }
        var out: [ElementRef] = []
        func walk(_ e: AXUIElement, _ depth: Int) {
            guard depth < maxDepth, out.count < 4000 else { return }
            let r = elementRef(e, windowID: window.id)
            if !r.title.isEmpty || r.isTextInput || r.isTab { out.append(r) }
            for c in children(e) { walk(c, depth + 1) }
        }
        walk(w, 0); return out
    }
    public func press(_ element: ElementRef) throws {
        guard let e = elementHandles[element.id] else { throw ActionSystemError.notFound("element") }
        guard AXUIElementPerformAction(e, kAXPressAction as CFString) == .success else { throw ActionSystemError.failed("press") }
        usleep(120_000)
    }
    public func focus(_ element: ElementRef) throws {
        guard let e = elementHandles[element.id] else { throw ActionSystemError.notFound("element") }
        AXUIElementSetAttributeValue(e, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }
    public func setValue(_ value: String, of element: ElementRef) throws {
        guard let e = elementHandles[element.id] else { throw ActionSystemError.notFound("element") }
        guard AXUIElementSetAttributeValue(e, kAXValueAttribute as CFString, value as CFString) == .success else { throw ActionSystemError.failed("setValue") }
    }
    public func scrollPosition(in window: WindowRef) -> Double? {
        guard let w = windowHandles[window.id] else { return nil }
        func find(_ e: AXUIElement, _ d: Int) -> Double? {
            if d > 8 { return nil }
            if (attr(e, kAXRoleAttribute) as String?) == "AXScrollArea", let bar: AXUIElement = attr(e, kAXVerticalScrollBarAttribute), let v: Double = attr(bar, kAXValueAttribute) { return v }
            for c in children(e) { if let v = find(c, d + 1) { return v } }
            return nil
        }
        return find(w, 0)
    }
    public func scroll(_ direction: ScrollDirection, amount: Int, in window: WindowRef) throws {
        switch direction {
        case .top: try keystroke(KeyChord(key: "home", modifiers: [])); case .bottom: try keystroke(KeyChord(key: "end", modifiers: []))
        default:
            let (dy, dx): (Int32, Int32) = direction == .up ? (Int32(amount), 0) : direction == .down ? (-Int32(amount), 0) : direction == .left ? (0, Int32(amount)) : (0, -Int32(amount))
            guard let ev = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { throw ActionSystemError.failed("scroll event") }
            ev.post(tap: .cghidEventTap)
        }
        usleep(120_000)
    }
    public func keystroke(_ chord: KeyChord) throws {
        guard let code = Self.keyCodes[chord.key] else { throw ActionSystemError.failed("unknown key \(chord.key)") }
        var flags: CGEventFlags = []
        for m in chord.modifiers { switch m { case "cmd": flags.insert(.maskCommand); case "shift": flags.insert(.maskShift); case "opt": flags.insert(.maskAlternate); case "ctrl": flags.insert(.maskControl); case "fn": flags.insert(.maskSecondaryFn); default: break } }
        for down in [true, false] {
            guard let ev = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { throw ActionSystemError.failed("key event") }
            ev.flags = flags; ev.post(tap: .cghidEventTap)
        }
        usleep(60_000)
    }
    public func typeText(_ text: String) throws {
        for ch in text.utf16.map({ $0 }) {
            for down in [true, false] { guard let ev = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { continue }; var u = ch; ev.keyboardSetUnicodeString(stringLength: 1, unicodeString: &u); ev.post(tap: .cghidEventTap) }
        }
    }
    public func openURL(_ url: URL) throws { guard NSWorkspace.shared.open(url) else { throw ActionSystemError.failed("open url") }; usleep(300_000) }
    public func openFile(_ url: URL) throws { guard NSWorkspace.shared.open(url) else { throw ActionSystemError.failed("open file") }; usleep(300_000) }
    /// Mission Control via its default shortcuts (ctrl+arrows / ctrl+digit / F11); active space is not readable from AX, so readback is delivery-only.
    public func switchSpace(_ move: SpaceMove) throws {
        switch move {
        case .left: try keystroke(KeyChord(key: "left", modifiers: ["ctrl"]))
        case .right: try keystroke(KeyChord(key: "right", modifiers: ["ctrl"]))
        case .index(let i): try keystroke(KeyChord(key: String(i), modifiers: ["ctrl"]))
        case .missionControl: try keystroke(KeyChord(key: "up", modifiers: ["ctrl"]))
        case .appExpose: try keystroke(KeyChord(key: "down", modifiers: ["ctrl"]))
        case .showDesktop: try keystroke(KeyChord(key: "f11", modifiers: ["fn"]))
        }
    }

    static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33,
        "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53, "esc": 53, "forwarddelete": 117,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121, "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]
}
#endif
