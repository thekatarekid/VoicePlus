import Foundation
import Shared

/// Q2 — Electron and Chromium build no accessibility tree until someone asks for one: 79 of 80
/// writes into Claude read back "unavailable" because the composer had no AX value, no caret and
/// no selection. Setting `AXManualAccessibility` (Electron) or `AXEnhancedUserInterface`
/// (Chromium browsers) on the application element turns the tree on.
///
/// Additive protocol: `system as? AppAccessibilityEnabling`. Called at key-down
/// (`FocusGuard.targetRevision`, `FieldContextReader`) and before the injector's first read, always
/// *before* the caret read. Cheap after the first call per pid.
public protocol AppAccessibilityEnabling: AnyObject {
    /// `true` when the app is (now, or already) asked to expose its tree. `false` for a native app,
    /// our own process, or when the attribute could not be set.
    @discardableResult func enableAppAccessibility(pid: Int32) -> Bool
}

/// What kind of tree switch an app needs.
public enum AppAccessibilityKind: String, Sendable, Equatable {
    /// `AXManualAccessibility` — Electron (Claude, Slack, VS Code, Cursor, Discord, Notion…).
    case electron
    /// `AXEnhancedUserInterface` — Chromium browsers (Chrome, Brave, Edge, Arc).
    case chromium
    /// AppKit / WebKit apps already expose their tree.
    case native

    public static let electronAttribute = "AXManualAccessibility"
    public static let chromiumAttribute = "AXEnhancedUserInterface"

    /// The attribute to set, `nil` for native apps.
    public var attribute: String? {
        switch self {
        case .electron: return Self.electronAttribute
        case .chromium: return Self.chromiumAttribute
        case .native: return nil
        }
    }

    /// Electron by **bundle contents** (`Contents/Frameworks/Electron Framework.framework`), not only
    /// by bundle id — every Electron app is covered, including ones no adapter names. Chromium by
    /// the browser bundle ids `ChromiumAdapter` knows.
    public static func classify(bundleID: String?, bundleURL: URL?,
                                fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> AppAccessibilityKind {
        if let bundleURL {
            let electron = bundleURL.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path
            if fileExists(electron) { return .electron }
        }
        guard let bundleID else { return .native }
        if ElectronAdapter.bundleIDs.contains(bundleID) || CursorAdapter().matches(bundleID: bundleID) { return .electron }
        if ChromiumAdapter().matches(bundleID: bundleID) { return .chromium }
        return .native
    }
}

/// Settings for Q2. `App` writes the switch (lane 1b adds the row); `Injection` only reads it.
public extension InjectionSettingsKeys {
    /// "Expose text in Chromium browsers" — default on. Electron is always exposed (it is our
    /// own write path's readback), only the browser switch is user-facing.
    static let exposeChromiumText = "injection.exposeChromiumText"

    static func exposeChromiumText(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: exposeChromiumText) == nil ? true : defaults.bool(forKey: exposeChromiumText)
    }
}

/// The pure part of Q2: classify the app, honour the switch, cache per pid, re-apply when the pid
/// changes (an app relaunch is a new pid, so it is simply a cache miss). The OS calls are closures
/// so tests drive it without AX.
public final class AppAccessibilityEnabler: @unchecked Sendable {
    public struct App: Equatable, Sendable {
        public var bundleID: String?
        public var bundleURL: URL?
        public init(bundleID: String?, bundleURL: URL?) {
            self.bundleID = bundleID
            self.bundleURL = bundleURL
        }
    }

    /// pid → the running app's identity. Live: `NSRunningApplication`.
    public var lookup: (Int32) -> App?
    /// Sets `attribute` to true on the application element of `pid`. Live: `AXUIElementSetAttributeValue`.
    public var setAttribute: (Int32, String) -> Bool
    public var fileExists: (String) -> Bool
    /// The "Expose text in Chromium browsers" switch.
    public var chromiumEnabled: () -> Bool

    private let lock = NSLock()
    /// pid → the answer last given. Only successes and "native" are cached: a failed set is retried
    /// on the next key-down (the app may still have been launching).
    private var cache: [Int32: Bool] = [:]
    public private(set) var setCount = 0

    public init(lookup: @escaping (Int32) -> App?,
                setAttribute: @escaping (Int32, String) -> Bool,
                fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                chromiumEnabled: @escaping () -> Bool = { InjectionSettingsKeys.exposeChromiumText() }) {
        self.lookup = lookup
        self.setAttribute = setAttribute
        self.fileExists = fileExists
        self.chromiumEnabled = chromiumEnabled
    }

    @discardableResult
    public func enable(pid: Int32) -> Bool {
        guard pid > 0, pid != OwnProcess.pid else { return false }
        if let cached = lock.withLock({ cache[pid] }) { return cached }
        guard let app = lookup(pid) else { return false }
        let kind = AppAccessibilityKind.classify(bundleID: app.bundleID, bundleURL: app.bundleURL, fileExists: fileExists)
        if kind == .chromium, !chromiumEnabled() { return false }   // not cached: the switch may flip
        guard let attribute = kind.attribute else {
            lock.withLock { cache[pid] = false }
            return false
        }
        let ok = setAttribute(pid, attribute)
        lock.withLock {
            setCount += 1
            if ok { cache[pid] = true }
            // Drop pids that are long gone so the table cannot grow without bound.
            if cache.count > 64 { cache = cache.filter { $0.key == pid } }
        }
        if ok { Log.injection.info("Q2: \(attribute) on pid \(pid) (\(app.bundleID ?? "?"))") }
        else { Log.injection.notice("Q2: could not set \(attribute) on pid \(pid) (\(app.bundleID ?? "?"))") }
        return ok
    }

    /// Forget a pid (app quit). Not required — a relaunch is a new pid — but keeps the table small.
    public func forget(pid: Int32) { lock.withLock { cache[pid] = nil } }
}
