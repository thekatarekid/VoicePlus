import Foundation
import Shared

/// Q2 / N10 — Electron and Chromium build no accessibility tree until someone asks for one.
///
/// N10 (round 4, R4 Q2): turn accessibility on **by trying, not by recognising the app**.
/// 1. At key-down, set the harmless `AXManualAccessibility` on any app, once per process + app
///    version. Native apps ignore it (the set simply fails).
/// 2. Probe the focused element: is it editable, and does it sit inside an `AXWebArea`?
/// 3. Only if nothing editable is found **and** the bundle ships a `… (Renderer).app` helper (one
///    cached structural check, no name lists) set `AXEnhancedUserInterface` and probe again.
/// 4. "Web content" comes from the `AXWebArea` ancestor the probe saw, not from the runtime.
/// 5. Honour "Expose text in Chromium browsers" (gates the enhanced switch) and a per-app off
///    switch; log which switch worked.
///
/// Additive protocol: `system as? AppAccessibilityEnabling`. Called at key-down
/// (`FocusGuard.targetRevision`, `FieldContextReader`) and before the injector's first read, always
/// *before* the caret read.
public protocol AppAccessibilityEnabling: AnyObject {
    /// `true` when the focused element of the app is (now, or already) readable as editable text.
    /// `false` for our own process, a disabled app, or when nothing editable was found.
    @discardableResult func enableAppAccessibility(pid: Int32) -> Bool
}

/// N10 — what the last enable attempt for a pid found (`AppAccessibilityOutcomeReading`).
public protocol AppAccessibilityOutcomeReading: AnyObject {
    func accessibilityOutcome(pid: Int32) -> AppAccessibilityOutcome?
}

/// The two tree switches. Kept as constants; which one to set is decided by probing (N10).
public enum AppAccessibilityKind: String, Sendable, Equatable {
    /// `AXManualAccessibility` — Electron. Harmless elsewhere.
    case electron
    /// `AXEnhancedUserInterface` — Chromium browsers, ChatGPT/Owl (and Electron). Side effects.
    case chromium
    /// Already exposes its tree.
    case native

    public static let electronAttribute = "AXManualAccessibility"
    public static let chromiumAttribute = "AXEnhancedUserInterface"

    public var attribute: String? {
        switch self {
        case .electron: return Self.electronAttribute
        case .chromium: return Self.chromiumAttribute
        case .native: return nil
        }
    }

    /// Structural only (no bundle-id lists): an Electron framework → electron, a renderer helper
    /// anywhere under `Contents/Frameworks` → chromium, else native. `nil` bundle → native.
    public static func classify(bundleURL: URL?) -> AppAccessibilityKind {
        guard let bundleURL else { return .native }
        switch AppRuntimeSniffer.classify(bundleURL: bundleURL) {
        case .electron: return .electron
        case .chromium: return .chromium
        default: return .native
        }
    }
}

/// Which switch made the focused field readable (N10 "log which switch worked").
public enum AppAccessibilitySwitch: String, Sendable, Equatable {
    /// Readable without any attribute (the manual set failed: a native app).
    case none
    /// Readable after `AXManualAccessibility`.
    case manual
    /// Readable only after `AXEnhancedUserInterface`.
    case enhanced
    /// Nothing editable after every allowed switch — use the safe defaults (N3/N4/N5).
    case unresolved
    /// The per-app off switch is on for this app: nothing was set.
    case off
}

/// One bounded read of the app's focused element.
public struct AppAccessibilityProbe: Equatable, Sendable {
    /// The focused element (or a near ancestor) is editable text.
    public var editable: Bool
    /// The focused element has an `AXWebArea` ancestor.
    public var inWebArea: Bool
    public init(editable: Bool, inWebArea: Bool) { self.editable = editable; self.inWebArea = inWebArea }
}

public struct AppAccessibilityOutcome: Equatable, Sendable {
    public var switchUsed: AppAccessibilitySwitch
    /// From the last probe; the web-content flag (⇧↩, keystrokes, URL read) when the tree is readable.
    public var inWebArea: Bool
    public var manualSet: Bool
    public var enhancedSet: Bool
    public var editable: Bool { switchUsed == .none || switchUsed == .manual || switchUsed == .enhanced }
}

/// Settings for Q2 / N10. `App` writes them; `Injection` only reads.
public extension InjectionSettingsKeys {
    /// "Expose text in Chromium browsers" — default on. Gates only the side-effect switch
    /// (`AXEnhancedUserInterface`); the harmless manual switch is always tried.
    static let exposeChromiumText = "injection.exposeChromiumText"
    /// N10 — per-app off switch: bundle ids that never get either attribute.
    static let accessibilityOffApps = "injection.accessibilityOffApps"

    static func exposeChromiumText(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: exposeChromiumText) == nil ? true : defaults.bool(forKey: exposeChromiumText)
    }

    static func accessibilityOff(bundleID: String?, _ defaults: UserDefaults = .standard) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        return (defaults.stringArray(forKey: accessibilityOffApps) ?? []).contains(bundleID)
    }
}

/// The pure part of N10. The OS calls are closures so tests drive it with fake bundles and probes.
public final class AppAccessibilityEnabler: @unchecked Sendable {
    public struct App: Equatable, Sendable {
        public var bundleID: String?
        public var bundleURL: URL?
        /// `CFBundleVersion` (or short version); part of the "once per app version" key.
        public var version: String?
        public init(bundleID: String?, bundleURL: URL?, version: String? = nil) {
            self.bundleID = bundleID
            self.bundleURL = bundleURL
            self.version = version
        }
    }

    /// pid → the running app's identity. Live: `NSRunningApplication`.
    public var lookup: (Int32) -> App?
    /// Sets `attribute` to true on the application element of `pid`. Live: `AXUIElementSetAttributeValue`.
    public var setAttribute: (Int32, String) -> Bool
    /// One bounded read of the app's focused element. `nil` = nothing focused / no tree.
    public var probe: (Int32) -> AppAccessibilityProbe?
    /// Structural check: a `… (Renderer).app` helper in the bundle. Cached per bundle path + version.
    public var hasRendererHelper: (URL) -> Bool
    /// The "Expose text in Chromium browsers" switch (gates the enhanced attribute).
    public var chromiumEnabled: () -> Bool
    /// The per-app off switch.
    public var appDisabled: (String?) -> Bool

    private let lock = NSLock()
    /// "pid|version" → whether the manual set succeeded. Tried once per key, success or not.
    private var manualTried: [String: Bool] = [:]
    /// pids that already got the enhanced attribute (never set twice; it stays until the app quits).
    private var enhancedPIDs: Set<Int32> = []
    /// "bundlePath|version" → renderer helper present.
    private var rendererCache: [String: Bool] = [:]
    private var outcomes: [Int32: AppAccessibilityOutcome] = [:]
    public private(set) var setCount = 0
    public private(set) var rendererScans = 0
    public private(set) var probeCount = 0

    public init(lookup: @escaping (Int32) -> App?,
                setAttribute: @escaping (Int32, String) -> Bool,
                probe: @escaping (Int32) -> AppAccessibilityProbe?,
                hasRendererHelper: @escaping (URL) -> Bool = {
                    AppRuntimeSniffer.hasRendererHelper(under: $0.appendingPathComponent("Contents/Frameworks"), maxDepth: 5)
                },
                chromiumEnabled: @escaping () -> Bool = { InjectionSettingsKeys.exposeChromiumText() },
                appDisabled: @escaping (String?) -> Bool = { InjectionSettingsKeys.accessibilityOff(bundleID: $0) }) {
        self.lookup = lookup
        self.setAttribute = setAttribute
        self.probe = probe
        self.hasRendererHelper = hasRendererHelper
        self.chromiumEnabled = chromiumEnabled
        self.appDisabled = appDisabled
    }

    public func outcome(pid: Int32) -> AppAccessibilityOutcome? { lock.withLock { outcomes[pid] } }

    @discardableResult
    public func enable(pid: Int32) -> Bool {
        guard pid > 0, pid != OwnProcess.pid else { return false }
        // Readable before: no more work (cheap after the first success per pid).
        if let known = lock.withLock({ outcomes[pid] }), known.editable { return true }
        guard let app = lookup(pid) else { return false }
        if appDisabled(app.bundleID) {
            record(pid, app, AppAccessibilityOutcome(switchUsed: .off, inWebArea: false, manualSet: false, enhancedSet: false))
            return false
        }
        // 1. The harmless switch, once per process + version.
        let key = "\(pid)|\(app.version ?? "?")"
        let manualOK: Bool
        if let tried = lock.withLock({ manualTried[key] }) {
            manualOK = tried
        } else {
            manualOK = setAttribute(pid, AppAccessibilityKind.electronAttribute)
            lock.withLock {
                setCount += 1
                if manualTried.count > 128 { manualTried = [:] }
                manualTried[key] = manualOK
            }
        }
        // 2. Probe.
        let first = runProbe(pid)
        if let first, first.editable {
            return record(pid, app, .init(switchUsed: manualOK ? .manual : .none, inWebArea: first.inWebArea,
                                          manualSet: manualOK, enhancedSet: false))
        }
        // 3. Enhanced only after a failed probe, only for a bundle with a renderer helper.
        let alreadyEnhanced = lock.withLock { enhancedPIDs.contains(pid) }
        guard !alreadyEnhanced, chromiumEnabled(), renderer(app) else {
            return record(pid, app, .init(switchUsed: .unresolved, inWebArea: first?.inWebArea ?? false,
                                          manualSet: manualOK, enhancedSet: alreadyEnhanced))
        }
        let enhancedOK = setAttribute(pid, AppAccessibilityKind.chromiumAttribute)
        lock.withLock {
            setCount += 1
            if enhancedOK { enhancedPIDs.insert(pid) }
        }
        let second = runProbe(pid)
        let editable = second?.editable == true
        return record(pid, app, .init(switchUsed: editable ? .enhanced : .unresolved,
                                      inWebArea: second?.inWebArea ?? first?.inWebArea ?? false,
                                      manualSet: manualOK, enhancedSet: enhancedOK))
    }

    /// Forget a pid (app quit). A relaunch is a new pid anyway; this keeps the tables small.
    public func forget(pid: Int32) {
        lock.withLock {
            outcomes[pid] = nil
            enhancedPIDs.remove(pid)
            manualTried = manualTried.filter { !$0.key.hasPrefix("\(pid)|") }
        }
    }

    private func runProbe(_ pid: Int32) -> AppAccessibilityProbe? {
        lock.withLock { probeCount += 1 }
        return probe(pid)
    }

    private func renderer(_ app: App) -> Bool {
        guard let url = app.bundleURL else { return false }
        let key = url.standardizedFileURL.path + "|" + (app.version ?? "?")
        if let hit = lock.withLock({ rendererCache[key] }) { return hit }
        let found = hasRendererHelper(url)
        lock.withLock { rendererScans += 1; rendererCache[key] = found }
        return found
    }

    @discardableResult
    private func record(_ pid: Int32, _ app: App, _ outcome: AppAccessibilityOutcome) -> Bool {
        let previous = lock.withLock { () -> AppAccessibilityOutcome? in
            let p = outcomes[pid]
            if outcomes.count > 64 { outcomes = outcomes.filter { $0.key == pid } }
            outcomes[pid] = outcome
            return p
        }
        if previous != outcome {
            Log.injection.info("N10: pid \(pid) (\(app.bundleID ?? "?")) switch=\(outcome.switchUsed.rawValue) web=\(outcome.inWebArea) manual=\(outcome.manualSet) enhanced=\(outcome.enhancedSet)")
        }
        return outcome.editable
    }
}
