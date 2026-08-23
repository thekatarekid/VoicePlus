import Foundation

// MARK: - Desktop model (what the deterministic layer sees and touches)

public struct AppRef: Hashable, Codable, Sendable {
    public let name: String
    public let bundleID: String
    public init(name: String, bundleID: String) { self.name = name; self.bundleID = bundleID }
}

public struct WindowRef: Hashable, Codable, Sendable {
    public let id: Int
    public let appBundleID: String
    public let title: String
    public var isMinimized: Bool
    public init(id: Int, appBundleID: String, title: String, isMinimized: Bool = false) {
        self.id = id; self.appBundleID = appBundleID; self.title = title; self.isMinimized = isMinimized
    }
}

/// Flattened accessibility element. `role` uses AX role names ("AXButton", "AXTextField", "AXRadioButton" for tabs…).
public struct ElementRef: Hashable, Codable, Sendable {
    public let id: Int
    public let windowID: Int
    public let role: String
    public var title: String
    public var value: String
    public var isEnabled: Bool
    public var isSelected: Bool
    public init(id: Int, windowID: Int, role: String, title: String, value: String = "", isEnabled: Bool = true, isSelected: Bool = false) {
        self.id = id; self.windowID = windowID; self.role = role; self.title = title
        self.value = value; self.isEnabled = isEnabled; self.isSelected = isSelected
    }
    public var isTextInput: Bool { ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role) }
    public var isTab: Bool { role == "AXTab" || role == "AXRadioButton" }
}

public struct DesktopSnapshot: Equatable, Sendable {
    public var frontmostApp: AppRef?
    public var focusedWindow: WindowRef?
    public var focusedElement: ElementRef?
    public var activeSpace: Int
    public init(frontmostApp: AppRef?, focusedWindow: WindowRef?, focusedElement: ElementRef?, activeSpace: Int) {
        self.frontmostApp = frontmostApp; self.focusedWindow = focusedWindow
        self.focusedElement = focusedElement; self.activeSpace = activeSpace
    }
}

public enum WindowOp: String, Codable, Sendable { case minimize, close, zoom, fullscreen, restore }
public enum ScrollDirection: String, Codable, Sendable { case up, down, left, right, top, bottom }
public enum SpaceMove: Equatable, Sendable { case left, right, index(Int), missionControl, showDesktop, appExpose }

/// Modifier+key chord, e.g. `KeyChord("cmd+shift+t")`.
public struct KeyChord: Hashable, Codable, Sendable {
    public let key: String
    public let modifiers: Set<String>   // cmd, shift, opt, ctrl, fn
    public init(key: String, modifiers: Set<String>) { self.key = key.lowercased(); self.modifiers = modifiers }
    public init?(_ text: String) {
        let parts = text.lowercased().split(separator: "+").map { String($0).trimmingCharacters(in: .whitespaces) }
        guard let last = parts.last, !last.isEmpty else { return nil }
        let mods = Set(parts.dropLast().map { m -> String in
            switch m { case "command", "⌘": return "cmd"; case "option", "alt", "⌥": return "opt"
            case "control", "⌃": return "ctrl"; case "⇧": return "shift"; default: return m }
        })
        guard mods.isSubset(of: ["cmd", "shift", "opt", "ctrl", "fn"]) else { return nil }
        self.init(key: last, modifiers: mods)
    }
    public var description: String { (modifiers.sorted() + [key]).joined(separator: "+") }
}

public enum ActionSystemError: Error, Equatable {
    case unavailable(String)
    case notFound(String)
    case failed(String)
}

// MARK: - The only door to the OS

/// Every system access on the deterministic path goes through this protocol; no model calls anywhere behind it.
public protocol ActionSystem: AnyObject {
    var isAvailable: Bool { get }
    func snapshot() -> DesktopSnapshot
    func runningApps() -> [AppRef]
    /// Activate an already running app or launch it by name.
    func activate(appNamed name: String) throws -> AppRef
    func windows(of app: AppRef) -> [WindowRef]
    func raise(_ window: WindowRef) throws
    func perform(_ op: WindowOp, on window: WindowRef) throws
    func elements(in window: WindowRef) -> [ElementRef]
    func press(_ element: ElementRef) throws
    func focus(_ element: ElementRef) throws
    func setValue(_ value: String, of element: ElementRef) throws
    /// Returns nil when the system cannot read a scroll position (live AX without scroll bars).
    func scrollPosition(in window: WindowRef) -> Double?
    func scroll(_ direction: ScrollDirection, amount: Int, in window: WindowRef) throws
    func keystroke(_ chord: KeyChord) throws
    func typeText(_ text: String) throws
    func openURL(_ url: URL) throws
    func openFile(_ url: URL) throws
    func switchSpace(_ move: SpaceMove) throws
}
