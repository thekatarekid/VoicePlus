import Foundation

/// In-memory desktop: apps → windows → elements, focus, spaces, scroll. Simulates the effects the live system would have.
public final class MockActionSystem: ActionSystem {
    public struct MockApp {
        public var ref: AppRef
        public var kind: ActionCategory
        public var windows: [WindowRef]
        public var elements: [Int: [ElementRef]]     // windowID → elements
        public init(ref: AppRef, kind: ActionCategory, windows: [WindowRef], elements: [Int: [ElementRef]]) {
            self.ref = ref; self.kind = kind; self.windows = windows; self.elements = elements
        }
    }

    public var isAvailable = true
    public private(set) var apps: [String: MockApp] = [:]    // bundleID → app
    public private(set) var frontmost: String?
    public private(set) var focusedWindowID: Int?
    public private(set) var focusedElementID: Int?
    public private(set) var activeSpace = 1
    public var spaceCount = 4
    public var scroll: [Int: Double] = [:]                    // windowID → 0…1
    public private(set) var log: [String] = []
    public var browserBundleID = "com.apple.Safari"
    public var failNext: ActionSystemError?
    /// Apps that are not running but can be launched by name (the live system launches from /Applications).
    public var launchable: [String] = ["Terminal", "Calendar", "Music", "System Settings", "TextEdit"]

    public init() {}

    // MARK: building

    public func add(_ app: MockApp) { apps[app.ref.bundleID] = app; if frontmost == nil { frontmost = app.ref.bundleID; focusedWindowID = app.windows.first?.id } }
    public func bringToFront(_ bundleID: String) { frontmost = bundleID; focusedWindowID = apps[bundleID]?.windows.first { !$0.isMinimized }?.id; focusedElementID = nil }
    public func element(_ id: Int) -> ElementRef? { apps.values.lazy.flatMap { $0.elements.values.joined() }.first { $0.id == id } }

    private func update(_ id: Int, _ body: (inout ElementRef) -> Void) {
        for (b, app) in apps { for (w, els) in app.elements { if let i = els.firstIndex(where: { $0.id == id }) { var e = els[i]; body(&e); apps[b]!.elements[w]![i] = e; return } } }
    }
    private func gate() throws { if let e = failNext { failNext = nil; throw e } }

    // MARK: ActionSystem

    public func snapshot() -> DesktopSnapshot {
        let app = frontmost.flatMap { apps[$0] }
        let w = app?.windows.first { $0.id == focusedWindowID }
        return DesktopSnapshot(frontmostApp: app?.ref, focusedWindow: w, focusedElement: focusedElementID.flatMap(element), activeSpace: activeSpace)
    }
    public func runningApps() -> [AppRef] { apps.values.map(\.ref).sorted { $0.name < $1.name } }
    public func activate(appNamed name: String) throws -> AppRef {
        try gate()
        if let m = FuzzyMatch.best(name, in: Array(apps.values), label: { $0.ref.name }) {
            bringToFront(m.item.ref.bundleID); log.append("activate \(m.item.ref.name)"); return m.item.ref
        }
        guard let l = FuzzyMatch.best(name, in: launchable, label: { $0 }) else { throw ActionSystemError.notFound("app \(name)") }
        let ref = AppRef(name: l.item, bundleID: "mock." + l.item.replacingOccurrences(of: " ", with: ""))
        let wid = 9000 + apps.count
        apps[ref.bundleID] = MockApp(ref: ref, kind: .mac, windows: [WindowRef(id: wid, appBundleID: ref.bundleID, title: l.item)], elements: [wid: []])
        bringToFront(ref.bundleID); log.append("launch \(l.item)"); return ref
    }
    public func windows(of app: AppRef) -> [WindowRef] { apps[app.bundleID]?.windows ?? [] }
    public func raise(_ window: WindowRef) throws {
        try gate(); guard apps[window.appBundleID] != nil else { throw ActionSystemError.notFound("window") }
        frontmost = window.appBundleID; focusedWindowID = window.id; focusedElementID = nil
        if let i = apps[window.appBundleID]!.windows.firstIndex(of: window) { apps[window.appBundleID]!.windows[i].isMinimized = false }
        log.append("raise \(window.title)")
    }
    public func perform(_ op: WindowOp, on window: WindowRef) throws {
        try gate(); guard var app = apps[window.appBundleID], let i = app.windows.firstIndex(where: { $0.id == window.id }) else { throw ActionSystemError.notFound("window") }
        switch op {
        case .close: app.windows.remove(at: i); app.elements[window.id] = nil; if focusedWindowID == window.id { focusedWindowID = app.windows.first?.id }
        case .minimize: app.windows[i].isMinimized = true; if focusedWindowID == window.id { focusedWindowID = app.windows.first { !$0.isMinimized }?.id }
        case .restore: app.windows[i].isMinimized = false; focusedWindowID = window.id
        case .zoom, .fullscreen: break
        }
        apps[window.appBundleID] = app; log.append("\(op.rawValue) \(window.title)")
    }
    public func elements(in window: WindowRef) -> [ElementRef] { apps[window.appBundleID]?.elements[window.id] ?? [] }
    public func press(_ element: ElementRef) throws {
        try gate(); guard let live = self.element(element.id), live.isEnabled else { throw ActionSystemError.failed("element gone/disabled") }
        if live.isTab {
            for t in elements(in: WindowRef(id: live.windowID, appBundleID: frontmost ?? "", title: "")) where t.isTab { update(t.id) { $0.isSelected = ($0.id == live.id) } }
        }
        log.append("press \(live.title)")
    }
    public func focus(_ element: ElementRef) throws { try gate(); guard self.element(element.id) != nil else { throw ActionSystemError.notFound("element") }; focusedElementID = element.id }
    public func setValue(_ value: String, of element: ElementRef) throws { try gate(); update(element.id) { $0.value = value }; log.append("set \(element.title)=\(value)") }
    public func scrollPosition(in window: WindowRef) -> Double? { scroll[window.id] ?? 0.5 }
    public func scroll(_ direction: ScrollDirection, amount: Int, in window: WindowRef) throws {
        try gate(); let cur = scroll[window.id] ?? 0.5, step = Double(amount) * 0.1
        switch direction { case .up, .left: scroll[window.id] = max(0, cur - step); case .down, .right: scroll[window.id] = min(1, cur + step); case .top: scroll[window.id] = 0; case .bottom: scroll[window.id] = 1 }
        log.append("scroll \(direction.rawValue)")
    }
    public func keystroke(_ chord: KeyChord) throws { try gate(); log.append("key \(chord.description)") }
    public func typeText(_ text: String) throws { try gate(); guard let f = focusedElementID else { throw ActionSystemError.failed("no focus") }; update(f) { $0.value += text }; log.append("type \(text)") }
    public func openURL(_ url: URL) throws {
        try gate(); log.append("open \(url.absoluteString)")
        if apps[browserBundleID] != nil { bringToFront(browserBundleID) } else if frontmost == nil { throw ActionSystemError.failed("no browser") }
    }
    public func openFile(_ url: URL) throws { try gate(); log.append("openFile \(url.path)"); if frontmost == nil { throw ActionSystemError.failed("no app") } }
    public func switchSpace(_ move: SpaceMove) throws {
        try gate()
        switch move { case .left: activeSpace = max(1, activeSpace - 1); case .right: activeSpace = min(spaceCount, activeSpace + 1)
        case .index(let i): guard (1...spaceCount).contains(i) else { throw ActionSystemError.failed("no space \(i)") }; activeSpace = i
        case .missionControl, .showDesktop, .appExpose: break }
        log.append("space \(move)")
    }
}
