import Foundation
import Shared

/// A fully-resolved action: catalogue kind + params (with any spoken argument merged in).
public struct ActionRequest: Equatable, Sendable {
    public let kind: ActionKind
    public var params: [String: String]
    public let reversibility: Reversibility
    public let catalogID: String?
    public init(kind: ActionKind, params: [String: String] = [:], reversibility: Reversibility = .reversible, catalogID: String? = nil) {
        self.kind = kind; self.params = params; self.reversibility = reversibility; self.catalogID = catalogID
    }
    public init(_ entry: CatalogEntry, argument: String? = nil) {
        var p = entry.params
        if let a = argument, !a.isEmpty { p[p["argSlot"] ?? "target"] = a }
        self.init(kind: entry.kind, params: p, reversibility: entry.reversibility, catalogID: entry.id)
    }
}

public enum ActionPhase: String, Sendable { case precondition, execute, postcondition }

public enum ActionOutcome: Equatable, Sendable {
    /// `verified` is false when the system offers no readback for this action (e.g. a keystroke) and the delivery itself is the evidence.
    case success(verified: Bool)
    case failed(ActionPhase, String)
    public var isSuccess: Bool { if case .success = self { return true }; return false }
}

public struct ActionResult: Equatable, Sendable {
    public let request: ActionRequest
    public let outcome: ActionOutcome
    public let durationMs: Double
}

/// precondition → execute → postcondition (AX readback) for every kind. No model calls.
public final class ActionExecutor {
    public let system: ActionSystem
    public init(system: ActionSystem) { self.system = system }

    public func run(_ r: ActionRequest) -> ActionResult {
        let t0 = Date()
        let outcome: ActionOutcome
        do { outcome = try perform(r) } catch let e as ActionSystemError { outcome = .failed(.execute, "\(e)") } catch { outcome = .failed(.execute, error.localizedDescription) }
        return ActionResult(request: r, outcome: outcome, durationMs: Date().timeIntervalSince(t0) * 1000)
    }

    // MARK: per-kind contracts

    private func perform(_ r: ActionRequest) throws -> ActionOutcome {
        guard system.isAvailable else { return .failed(.precondition, "action system unavailable") }
        let p = r.params
        switch r.kind {
        case .focusApp:
            guard let name = p["target"] ?? p["name"], !name.isEmpty else { return .failed(.precondition, "no app name") }
            let app = try system.activate(appNamed: name)
            return system.snapshot().frontmostApp == app ? .success(verified: true) : .failed(.postcondition, "\(app.name) not frontmost")

        case .focusWindow:
            guard let app = system.snapshot().frontmostApp else { return .failed(.precondition, "no frontmost app") }
            let wins = system.windows(of: app)
            guard !wins.isEmpty else { return .failed(.precondition, "no windows") }
            let target: WindowRef
            if let name = p["target"], let m = FuzzyMatch.best(name, in: wins, label: { $0.title }) { target = m.item }
            else if p["target"] == nil || p["target"] == "next" {
                let cur = system.snapshot().focusedWindow
                let i = wins.firstIndex { $0 == cur } ?? -1
                target = wins[(i + 1) % wins.count]
            } else { return .failed(.precondition, "no window matching \(p["target"] ?? "")") }
            try system.raise(target)
            return system.snapshot().focusedWindow?.id == target.id ? .success(verified: true) : .failed(.postcondition, "window not focused")

        case .windowOp:
            guard let op = p["op"].flatMap(WindowOp.init(rawValue:)) else { return .failed(.precondition, "bad op") }
            guard let w = system.snapshot().focusedWindow else { return .failed(.precondition, "no focused window") }
            try system.perform(op, on: w)
            let after = system.snapshot().frontmostApp.map(system.windows(of:)) ?? []
            let still = after.first { $0.id == w.id }
            switch op {
            case .close: return still == nil ? .success(verified: true) : .failed(.postcondition, "window still open")
            case .minimize: return (still?.isMinimized ?? true) ? .success(verified: true) : .failed(.postcondition, "not minimized")
            case .restore: return (still.map { !$0.isMinimized } ?? false) ? .success(verified: true) : .failed(.postcondition, "not restored")
            case .zoom, .fullscreen: return still != nil ? .success(verified: false) : .failed(.postcondition, "window vanished")
            }

        case .click:
            guard let name = p["name"] ?? p["target"], let w = system.snapshot().focusedWindow else { return .failed(.precondition, "no name/window") }
            let els = system.elements(in: w).filter { $0.isEnabled && !$0.isTab }
            guard let m = FuzzyMatch.best(name, in: els, label: { $0.title }) else { return .failed(.precondition, "no control named \(name)") }
            try system.press(m.item)
            // Readback: the window may legitimately close or change (e.g. "Send"); evidence is either the element still present or focus moved.
            let snap = system.snapshot()
            let stillThere = snap.focusedWindow.map { system.elements(in: $0).contains { $0.id == m.item.id } } ?? false
            return (stillThere || snap.focusedWindow != w || snap.frontmostApp?.bundleID != w.appBundleID) ? .success(verified: true) : .failed(.postcondition, "no observable effect")

        case .focusTab:
            guard let w = system.snapshot().focusedWindow else { return .failed(.precondition, "no window") }
            let tabs = system.elements(in: w).filter(\.isTab)
            guard !tabs.isEmpty else { return .failed(.precondition, "no tabs") }
            let target: ElementRef
            if let t = p["target"], t != "next", t != "previous" {
                guard let m = FuzzyMatch.best(t, in: tabs, label: { $0.title }) else { return .failed(.precondition, "no tab \(t)") }
                target = m.item
            } else {
                let i = tabs.firstIndex(where: \.isSelected) ?? 0
                target = tabs[(i + (p["target"] == "previous" ? tabs.count - 1 : 1)) % tabs.count]
            }
            try system.press(target)
            let sel = system.elements(in: w).first { $0.id == target.id }?.isSelected ?? false
            return sel ? .success(verified: true) : .failed(.postcondition, "tab not selected")

        case .fillField:
            guard let w = system.snapshot().focusedWindow else { return .failed(.precondition, "no window") }
            let value = p["value"] ?? p["target"] ?? ""
            let fields = system.elements(in: w).filter { $0.isTextInput && $0.isEnabled }
            let field: ElementRef
            if let n = p["name"] { guard let m = FuzzyMatch.best(n, in: fields, label: { $0.title }) else { return .failed(.precondition, "no field \(n)") }; field = m.item }
            else if let f = system.snapshot().focusedElement, f.isTextInput { field = f }
            else { return .failed(.precondition, "no text field") }
            try system.focus(field); try system.setValue(value, of: field)
            let read = system.elements(in: w).first { $0.id == field.id }?.value
            return read == value ? .success(verified: true) : .failed(.postcondition, "readback \(read ?? "nil") != \(value)")

        case .scroll:
            guard let dir = p["direction"].flatMap(ScrollDirection.init(rawValue:)), let w = system.snapshot().focusedWindow else { return .failed(.precondition, "no direction/window") }
            let before = system.scrollPosition(in: w)
            try system.scroll(dir, amount: Int(p["amount"] ?? "") ?? 3, in: w)
            guard let b = before, let a = system.scrollPosition(in: w) else { return .success(verified: false) }
            if a != b { return .success(verified: true) }
            // At a bound already (top/bottom) counts as satisfied for absolute moves and for already-saturated relative moves.
            return (b == 0 || b == 1) ? .success(verified: true) : .failed(.postcondition, "scroll position unchanged")

        case .shortcut:
            guard let chord = p["keys"].flatMap(KeyChord.init) else { return .failed(.precondition, "bad chord \(p["keys"] ?? "")") }
            guard system.snapshot().frontmostApp != nil else { return .failed(.precondition, "no frontmost app") }
            try system.keystroke(chord)
            return .success(verified: false)

        case .typeText:
            let text = p["value"] ?? p["target"] ?? ""
            guard !text.isEmpty else { return .failed(.precondition, "empty text") }
            guard let f = system.snapshot().focusedElement, f.isTextInput else { return .failed(.precondition, "no focused text input") }
            let before = f.value
            try system.typeText(text)
            let after = system.snapshot().focusedElement?.value ?? ""
            return after.hasSuffix(text) || after.count > before.count ? .success(verified: true) : .failed(.postcondition, "text not inserted")

        case .openURL:
            guard let raw = p["url"] ?? p["target"], let url = Self.url(fromSpoken: raw) else { return .failed(.precondition, "bad url") }
            try system.openURL(url)
            return system.snapshot().frontmostApp != nil ? .success(verified: false) : .failed(.postcondition, "nothing frontmost")

        case .openFile:
            guard let path = p["path"] ?? p["target"], !path.isEmpty else { return .failed(.precondition, "no path") }
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            try system.openFile(url)
            return system.snapshot().frontmostApp != nil ? .success(verified: false) : .failed(.postcondition, "nothing frontmost")

        case .switchSpace:
            let move: SpaceMove
            switch p["move"] ?? "" {
            case "left": move = .left; case "right": move = .right; case "missionControl": move = .missionControl
            case "showDesktop": move = .showDesktop; case "appExpose": move = .appExpose
            case let s where Int(s) != nil: move = .index(Int(s)!)
            default: return .failed(.precondition, "bad move")
            }
            let before = system.snapshot().activeSpace
            try system.switchSpace(move)
            let after = system.snapshot().activeSpace
            switch move {
            case .index(let i): return after == i ? .success(verified: true) : .failed(.postcondition, "space \(after) != \(i)")
            case .left, .right: return after != before ? .success(verified: true) : .success(verified: false) // at edge: delivered but unobservable
            default: return .success(verified: false)
            }
        }
    }

    /// "github dot com slash pulls" → https://github.com/pulls
    public static func url(fromSpoken s: String) -> URL? {
        var t = s.trimmingCharacters(in: .whitespaces).lowercased()
        for (k, v) in [" dot ": ".", " slash ": "/", " colon ": ":", " dash ": "-", " underscore ": "_"] { t = t.replacingOccurrences(of: k, with: v) }
        t = t.replacingOccurrences(of: " ", with: "")
        if !t.contains("://") { t = (t.contains(".") ? "https://" : "https://www.google.com/search?q=") + t }
        return URL(string: t)
    }
}
