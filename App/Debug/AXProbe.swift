import ApplicationServices
import AppKit
import CryptoKit
import Foundation

// T-probe (Round 4 Q4, stage S0; "Tooling this needs") — the read-only accessibility probe.
//
// `VoicePlusApp --ax-probe [--delay s] [--watch s] [--out file.jsonl] [--allow-switch]`
//
// Debug-only and outside the product path. For the focused field of the frontmost app it records
// the role, subrole, label, placeholder, page id and class, its editable ancestor, whether it sits
// in an `AXWebArea`, that web area's URL **host**, the caret rectangle, and which accessibility
// switch was needed (none / manual / enhanced). It never types, never posts an event, never writes a
// value and never reads text into its output: a field's value appears only as a length and a short
// SHA-256 prefix, and a secure field's value is not read at all. Its only possible change to an app
// is the accessibility switch, and only with `--allow-switch` (the enhanced switch is put back the
// way it was afterwards). Output is JSON Lines.

// MARK: - Node seam (tests use a mock tree)

public protocol AXProbeNode {
    func string(_ attribute: String) -> String?
    var parentNode: AXProbeNode? { get }
    /// True when `AXValue` is settable (an editable text element).
    var isValueSettable: Bool { get }
    /// `AXNumberOfCharacters`, else the value's length. Nil for a secure field (never read).
    func valueLength() -> Int?
    /// The value, used only to compute a hash inside the probe; never stored or printed.
    func valueForHash() -> String?
    /// The caret's screen rectangle, from `AXSelectedTextRange` + `AXBoundsForRange`.
    func caretRect() -> CGRect?
    /// `AXURL` of this element (web areas), as a string.
    func urlString() -> String?
}

public enum AXProbeSwitch: String, Codable, Sendable {
    /// The focused field was readable with no switch.
    case none
    /// Readable after `AXManualAccessibility`.
    case manual
    /// Readable only after `AXEnhancedUserInterface` (Chromium with a renderer helper).
    case enhanced
    /// Still nothing editable after every allowed switch.
    case unresolved
    /// Nothing editable and `--allow-switch` was not given.
    case notTried = "not-tried"
}

public struct AXProbeRecord: Codable, Equatable, Sendable {
    public struct Rect: Codable, Equatable, Sendable { public var x, y, w, h: Double }
    public var at: Date
    public var bundleID: String?
    public var appName: String?
    public var pid: Int32?
    public var focused: Bool
    public var role: String?
    public var subrole: String?
    public var roleDescription: String?
    public var label: String?
    public var placeholder: String?
    public var identifier: String?
    public var domIdentifier: String?
    public var domClasses: String?
    public var secure: Bool
    public var editable: Bool
    /// Role of the nearest editable element at or above the focus, and how many levels up (0 = self).
    public var editableAncestorRole: String?
    public var editableAncestorDepth: Int?
    public var inWebArea: Bool
    public var webAreaDepth: Int?
    /// Host only (`docs.google.com`) — never a path or a query.
    public var urlHost: String?
    public var caret: Rect?
    public var valueLength: Int?
    public var valueHash: String?
    public var rendererHelper: Bool
    public var switchNeeded: AXProbeSwitch

    /// What `--watch` compares to decide a new line is worth writing.
    var signature: String {
        [bundleID, role, subrole, label, identifier, domIdentifier, editableAncestorRole, urlHost,
         switchNeeded.rawValue, String(inWebArea)].map { $0 ?? "-" }.joined(separator: "|")
    }
}

public enum AXProbe {
    static let editableRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
    static let maxAncestors = 24

    /// One record for `focused` (nil = no focused element). Pure apart from `node` reads.
    public static func record(focused: AXProbeNode?, bundleID: String?, appName: String?, pid: Int32?,
                              rendererHelper: Bool, switchNeeded: AXProbeSwitch, at: Date = Date()) -> AXProbeRecord {
        var r = AXProbeRecord(at: at, bundleID: bundleID, appName: appName, pid: pid, focused: focused != nil,
                              secure: false, editable: false, inWebArea: false, rendererHelper: rendererHelper,
                              switchNeeded: switchNeeded)
        guard let node = focused else { return r }
        r.role = node.string("AXRole")
        r.subrole = node.string("AXSubrole")
        r.roleDescription = node.string("AXRoleDescription")
        r.label = [node.string("AXTitle"), node.string("AXDescription"), node.string("AXLabel")]
            .compactMap { $0 }.first { !$0.isEmpty }
        r.placeholder = node.string("AXPlaceholderValue")
        r.identifier = node.string("AXIdentifier")
        r.domIdentifier = node.string("AXDOMIdentifier")
        r.domClasses = node.string("AXDOMClassList")
        r.secure = r.subrole == "AXSecureTextField"
        if let (role, depth) = editableAncestor(of: node) {
            r.editable = true
            r.editableAncestorRole = role
            r.editableAncestorDepth = depth
        }
        if let (area, depth) = webArea(of: node) {
            r.inWebArea = true
            r.webAreaDepth = depth
            r.urlHost = host(of: area.urlString())
        }
        if let rect = node.caretRect() {
            r.caret = .init(x: rect.origin.x, y: rect.origin.y, w: rect.size.width, h: rect.size.height)
        }
        if !r.secure {
            r.valueLength = node.valueLength()
            r.valueHash = node.valueForHash().map(hash)
        }
        return r
    }

    public static func isEditable(_ node: AXProbeNode) -> Bool {
        if let role = node.string("AXRole"), editableRoles.contains(role) { return true }
        return node.isValueSettable && node.string("AXRole") != "AXStaticText"
    }

    static func editableAncestor(of node: AXProbeNode) -> (String?, Int)? {
        var cur: AXProbeNode? = node
        var depth = 0
        while let n = cur, depth <= maxAncestors {
            if isEditable(n) { return (n.string("AXRole"), depth) }
            cur = n.parentNode
            depth += 1
        }
        return nil
    }

    static func webArea(of node: AXProbeNode) -> (AXProbeNode, Int)? {
        var cur: AXProbeNode? = node
        var depth = 0
        while let n = cur, depth <= maxAncestors {
            if n.string("AXRole") == "AXWebArea" { return (n, depth) }
            cur = n.parentNode
            depth += 1
        }
        return nil
    }

    public static func host(of url: String?) -> String? {
        guard let url, let host = URLComponents(string: url)?.host, !host.isEmpty else { return nil }
        return host.lowercased()
    }

    /// First 12 hex characters of SHA-256 — enough to tell two values apart, useless to read one.
    public static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// Which switch made the field readable. Tries only what is allowed, in order: nothing, the
    /// harmless manual switch, then — only for an app with a renderer helper — the enhanced one.
    public static func decideSwitch(readableNow: Bool, allowSwitch: Bool, hasRendererHelper: Bool,
                                    afterManual: () -> Bool, afterEnhanced: () -> Bool) -> AXProbeSwitch {
        if readableNow { return .none }
        guard allowSwitch else { return .notTried }
        if afterManual() { return .manual }
        if hasRendererHelper, afterEnhanced() { return .enhanced }
        return .unresolved
    }

    /// One cached structural check, no app lists: a `… (Renderer).app` helper inside the bundle.
    public static func hasRendererHelper(bundleURL: URL?, maxDepth: Int = 5) -> Bool {
        guard let bundleURL else { return false }
        let frameworks = bundleURL.appendingPathComponent("Contents/Frameworks")
        guard let e = FileManager.default.enumerator(at: frameworks, includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles]) else { return false }
        for case let url as URL in e {
            if e.level > maxDepth { e.skipDescendants(); continue }
            let name = url.lastPathComponent
            if name.hasSuffix("(Renderer).app") { return true }
            if name.hasSuffix(".app") { e.skipDescendants() }
        }
        return false
    }
}

// MARK: - Live AX

final class LiveAXProbeNode: AXProbeNode {
    let element: AXUIElement
    init(_ element: AXUIElement) { self.element = element }

    private func copy(_ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    func string(_ attribute: String) -> String? {
        guard let v = copy(attribute) else { return nil }
        if let s = v as? String { return s }
        if let a = v as? [String] { return a.joined(separator: " ") }
        return nil
    }

    var parentNode: AXProbeNode? {
        guard let p = copy(kAXParentAttribute), CFGetTypeID(p) == AXUIElementGetTypeID() else { return nil }
        return LiveAXProbeNode(p as! AXUIElement)
    }

    var isValueSettable: Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
    }

    func valueLength() -> Int? {
        if let n = copy(kAXNumberOfCharactersAttribute) as? Int { return n }
        return valueForHash().map { $0.count }
    }

    func valueForHash() -> String? { copy(kAXValueAttribute) as? String }

    func caretRect() -> CGRect? {
        guard let rv = copy(kAXSelectedTextRangeAttribute), CFGetTypeID(rv) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rv as! AXValue, .cfRange, &range) else { return nil }
        for length in [0, 1] {
            var r = CFRange(location: range.location, length: length)
            guard let param = AXValueCreate(.cfRange, &r) else { continue }
            var out: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                             param, &out) == .success,
                  let o = out, CFGetTypeID(o) == AXValueGetTypeID() else { continue }
            var rect = CGRect.zero
            if AXValueGetValue(o as! AXValue, .cgRect, &rect), rect.height > 0 { return rect }
        }
        return nil
    }

    func urlString() -> String? {
        guard let v = copy(kAXURLAttribute) else { return nil }
        if let u = v as? URL { return u.absoluteString }
        return v as? String
    }
}

// MARK: - CLI

public enum AXProbeCLI {
    public struct Options: Equatable {
        public var delay: Double = 3
        public var watch: Double?
        public var out: String?
        public var allowSwitch = false
    }

    public static func parse(_ args: [String]) -> Options? {
        guard args.contains("--ax-probe") else { return nil }
        var o = Options()
        func value(_ flag: String) -> String? {
            guard let j = args.firstIndex(of: flag), j + 1 < args.count else { return nil }
            return args[j + 1]
        }
        if let d = value("--delay").flatMap(Double.init) { o.delay = max(0, d) }
        o.watch = value("--watch").flatMap(Double.init)
        o.out = value("--out")
        o.allowSwitch = args.contains("--allow-switch")
        return o
    }

    /// Exit code: 0 ok, 3 Accessibility not granted to this process.
    public static func run(_ o: Options) -> Int32 {
        guard AXIsProcessTrusted() else {
            FileHandle.standardError.write(Data("ax-probe: this process has no Accessibility permission\n".utf8))
            return 3
        }
        let sink = o.out.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        if let sink { FileManager.default.createFile(atPath: sink.path, contents: nil) }
        let handle = sink.flatMap { try? FileHandle(forWritingTo: $0) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        func emit(_ r: AXProbeRecord) {
            guard let data = try? encoder.encode(r) else { return }
            if let handle { handle.write(data + Data("\n".utf8)) } else { print(String(decoding: data, as: UTF8.self)) }
        }
        if o.delay > 0 {
            FileHandle.standardError.write(Data("ax-probe: focus the field — probing in \(Int(o.delay)) s\n".utf8))
            Thread.sleep(forTimeInterval: o.delay)
        }
        var rendererCache: [String: Bool] = [:]
        var switched = Set<Int32>()
        if let watch = o.watch, watch > 0 {
            let end = Date().addingTimeInterval(watch)
            var last = ""
            while Date() < end {
                let r = probeOnce(allowSwitch: o.allowSwitch, rendererCache: &rendererCache, switched: &switched)
                if r.signature != last { emit(r); last = r.signature }
                Thread.sleep(forTimeInterval: 0.5)
            }
        } else {
            emit(probeOnce(allowSwitch: o.allowSwitch, rendererCache: &rendererCache, switched: &switched))
        }
        try? handle?.close()
        return 0
    }

    static func probeOnce(allowSwitch: Bool, rendererCache: inout [String: Bool], switched: inout Set<Int32>) -> AXProbeRecord {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return AXProbe.record(focused: nil, bundleID: nil, appName: nil, pid: nil, rendererHelper: false, switchNeeded: .unresolved)
        }
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        func focused() -> LiveAXProbeNode? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &value) == .success,
                  let v = value, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
            return LiveAXProbeNode(v as! AXUIElement)
        }
        func readable() -> Bool { focused().map { AXProbe.editableAncestor(of: $0) != nil } ?? false }
        let key = "\(app.bundleIdentifier ?? "?")|\(app.bundleURL?.path ?? "")"
        let renderer = rendererCache[key] ?? AXProbe.hasRendererHelper(bundleURL: app.bundleURL)
        rendererCache[key] = renderer
        func snapshot(_ d: AXProbeSwitch) -> AXProbeRecord {
            AXProbe.record(focused: focused(), bundleID: app.bundleIdentifier, appName: app.localizedName, pid: pid,
                           rendererHelper: renderer, switchNeeded: d)
        }
        var whileEnhanced: AXProbeRecord?
        let decision = AXProbe.decideSwitch(
            readableNow: readable(), allowSwitch: allowSwitch && !switched.contains(pid), hasRendererHelper: renderer,
            afterManual: {
                AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
                Thread.sleep(forTimeInterval: 0.3)
                return readable()
            },
            afterEnhanced: {
                var before: CFTypeRef?
                _ = AXUIElementCopyAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, &before)
                AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
                Thread.sleep(forTimeInterval: 0.5)
                let ok = readable()
                if ok { whileEnhanced = snapshot(.enhanced) }   // read before the switch goes back
                if (before as? Bool) != true {   // put the enhanced switch back the way it was
                    AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
                }
                return ok
            })
        if decision != .none && decision != .notTried { switched.insert(pid) }
        return whileEnhanced ?? snapshot(decision)
    }
}
