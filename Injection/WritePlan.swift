import Foundation
import Shared

// MARK: - N5 — line breaks by structure, not by app list

/// N5 — what the injector knows about the surface before the first write: the resolver's kind
/// (N9, when the caller has one), whether the focused element sits inside an `AXWebArea`, and how
/// the app is built. Any one of the last two is enough to treat the field as web content.
public struct SurfaceWriteContext: Equatable, Sendable {
    public var kind: SurfaceKind?
    public var isInWebArea: Bool
    public var runtime: SurfaceRuntime?
    /// The focused element's descriptive strings (`FocusedElementInfo.hints`).
    public var hints: [String]

    public init(kind: SurfaceKind? = nil, isInWebArea: Bool = false, runtime: SurfaceRuntime? = nil, hints: [String] = []) {
        self.kind = kind; self.isInWebArea = isInWebArea; self.runtime = runtime; self.hints = hints
    }

    /// Return may send, submit or run here: ⇧↩ for a line break, never a bare ↩.
    public var isWebContent: Bool {
        isInWebArea || (runtime?.isWebContent ?? false) || kind == .chatComposer
    }

    /// A shell on a pty: the resolver said so, or the field names itself a terminal (the VS Code /
    /// Cursor integrated terminal is an `AXTextArea` described "Terminal input"; xterm.js fields).
    public var isTerminal: Bool {
        if kind == .terminal { return true }
        return hints.contains { hint in
            let h = hint.lowercased()
            return h == "terminal" || h.contains("terminal input") || h.contains("xterm")
        }
    }
}

/// N5 — the focused element has an `AXWebArea` ancestor (Safari/WebKit and Chromium web content,
/// every Electron app's DOM). Additive protocol so existing conformers compile unchanged.
public protocol WebAreaProbing: AnyObject {
    func focusedIsInWebArea() -> Bool
}

/// N5 / N10 — how the app is built, from its bundle on disk (cached per bundle path + version).
public protocol AppRuntimeReading: AnyObject {
    func appRuntime(pid: Int32) -> SurfaceRuntime
}

/// N5 / N10 — structural runtime sniffing: no bundle-id lists.
/// * `Contents/Frameworks/Electron Framework.framework` → electron;
/// * any `… (Renderer).app` helper under `Contents/Frameworks` (Chrome, Brave, ChatGPT/Owl,
///   Dia/ArcCore, Comet, CEF wrappers) → chromium;
/// * otherwise native.
public final class AppRuntimeSniffer: @unchecked Sendable {
    public static let shared = AppRuntimeSniffer()
    private let lock = NSLock()
    private var cache: [String: SurfaceRuntime] = [:]
    public private(set) var scans = 0

    public init() {}

    public func runtime(bundleURL: URL?) -> SurfaceRuntime {
        guard let bundleURL else { return .unknown }
        let key = bundleURL.standardizedFileURL.path + "|" + (Self.version(of: bundleURL) ?? "?")
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()
        let found = Self.classify(bundleURL: bundleURL)
        lock.lock(); cache[key] = found; scans += 1; lock.unlock()
        return found
    }

    public static func classify(bundleURL: URL) -> SurfaceRuntime {
        let frameworks = bundleURL.appendingPathComponent("Contents/Frameworks")
        let fm = FileManager.default
        if fm.fileExists(atPath: frameworks.appendingPathComponent("Electron Framework.framework").path) { return .electron }
        return hasRendererHelper(under: frameworks, maxDepth: 5) ? .chromium : .native
    }

    /// Bounded walk of `Contents/Frameworks` for a directory named `… (Renderer).app`. It does not
    /// descend into `.app` bundles it finds (a helper's own contents are irrelevant).
    public static func hasRendererHelper(under dir: URL, maxDepth: Int) -> Bool {
        guard maxDepth >= 0,
              let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        else { return false }
        for item in items {
            let name = item.lastPathComponent
            if name.hasSuffix("(Renderer).app") { return true }
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true, !name.hasSuffix(".app") else { continue }
            if hasRendererHelper(under: item, maxDepth: maxDepth - 1) { return true }
        }
        return false
    }

    static func version(of bundleURL: URL) -> String? {
        guard let info = NSDictionary(contentsOf: bundleURL.appendingPathComponent("Contents/Info.plist")) else { return nil }
        return (info["CFBundleVersion"] as? String) ?? (info["CFBundleShortVersionString"] as? String)
    }
}

/// N5 — web content with no dedicated adapter (Safari's Gemini, an unnamed Electron or Chromium
/// wrapper, an unreadable tree): keystrokes, ⇧↩ for a line break (⌥↩ in a spreadsheet cell),
/// paste for the rare throw-before-post. Never an AX value write (it desyncs the page's editor).
public final class WebContentAdapter: NewlineSafeAdapter {
    public let id = "webContent"
    public let spreadsheetCell: Bool
    public init(spreadsheetCell: Bool = false) { self.spreadsheetCell = spreadsheetCell }
    public func matches(bundleID: String) -> Bool { false }
    public var methodOrder: [InjectionMethod] { [.keystroke, .paste] }
    public func newlineCombo(focused: FocusedElementInfo?) -> KeyCombo {
        spreadsheetCell || NewlineSafety.isSpreadsheetDocument(focused?.documentURL) ? .optionReturn : .shiftReturn
    }
    public func prepare(_ text: String, focused: FocusedElementInfo?) -> String { NewlineSafety.normalize(text) }
    public func verifyReadback(text: String, before: FocusedElementInfo?, after: FocusedElementInfo?) -> ReadbackVerdict {
        Readback.byValueOrCaret(text: text, before: before, after: after)
    }
}

/// N5 — picks the write plan from structure. The bundle-id adapter is the starting point; the
/// surface can only move it toward a *safer* plan:
/// * a terminal surface (any app) → `TerminalAdapter` (bracketed paste, never Return);
/// * web content under a plan that could post a bare ↩ or write AX values → `WebContentAdapter`.
public enum WritePlanner {
    public static func adapter(base: AppAdapter, context: SurfaceWriteContext) -> AppAdapter {
        if base is OwnProcessAdapter { return base }
        if context.isTerminal { return base is TerminalAdapter ? base : TerminalAdapter() }
        if base is NewlineSafeAdapter || base is TerminalAdapter || base is SpreadsheetAdapter { return base }
        if context.kind == .spreadsheetCell { return WebContentAdapter(spreadsheetCell: true) }
        // Figma keeps its own order (keystrokes, paste last); its line breaks are made safe below.
        if context.isWebContent, base is DefaultAdapter { return WebContentAdapter() }
        return base
    }

    /// N5 — the key a typed line break becomes on the keystroke path. Never a bare ↩: a
    /// newline-safe adapter names its combo; anything else gets ⇧↩ (a line break in native text
    /// views, a soft break in web composers, never a send).
    public static func newlineCombo(adapter: AppAdapter, focused: FocusedElementInfo?) -> KeyCombo {
        (adapter as? NewlineSafeAdapter)?.newlineCombo(focused: focused) ?? .shiftReturn
    }
}
