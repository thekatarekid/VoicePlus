import ApplicationServices
import Foundation
import Injection
import Pipeline
import Shared

/// Which rung produced a caret reading (D1, D5, D7). Diagnostics and tests read it; nothing
/// downstream branches on it — they read the `CaretState`.
public enum CaretRung: String, Sendable, Equatable, CaseIterable {
    /// `kAXSelectedTextRange` over `kAXValue`.
    case selectedRange
    /// `AXSelectedTextMarkerRange` + `AXStringForTextMarkerRange` (WebKit / Chromium).
    case textMarkers
    /// No AX rung answered; our own last landing into this element did (D5).
    case landingMemory
    /// Nothing answered, or the field is a password field (never read): `unknown`.
    case none
}

public struct CaretReading: Sendable, Equatable {
    public var caret: CaretState
    public var rung: CaretRung
}

/// R4.2 wiring — the focused AX element → `FieldContext`, the value `Pipeline` classifies.
///
/// This is the piece that makes the headline case real rather than test-only: `FieldRole.classify`
/// decides a VS Code integrated terminal from its editor pane by the element's descriptive strings
/// (`FocusedElementInfo.hints`), and nothing was carrying them out of `Injection` before. With them
/// in hand, "terminal inside an editor" is decided by the accessibility tree instead of the bundle
/// ID, which is the whole point of the item.
///
/// D1 (V4.2, V4.3) — the caret is three-valued and read in rungs: `kAXSelectedTextRange` over
/// `kAXValue` → text markers (`TextMarkerCaretReading`) → our own last landing (D5) → `unknown`.
/// A value without a range is **not** "the end of the field": that fallback was the V3 bug.
/// D7 (V4.5) — an app whose AX rungs came back empty `CaretCapabilityMemory.threshold` landings in
/// a row stops paying for the marker round-trip; any rung answering resets it.
///
/// One `focusedElement()` call per utterance — the same one the injector's caret read already
/// makes — plus the marker reads only where the range is missing.
public final class FieldContextReader: @unchecked Sendable {
    private let system: SystemAccess

    /// How much text either side of the caret is carried, in UTF-16 units.
    public var window: Int
    /// D5 — shared with the lander that records landings (see `LandingMemory.attached(to:)`).
    public let landingMemory: LandingMemory
    /// D7 — per-app "this app never exposes a caret" counter.
    public let capabilities: CaretCapabilityMemory

    private let lock = NSLock()
    private var _lastReading: CaretReading?
    /// The last caret reading, for diagnostics and tests.
    public var lastReading: CaretReading? { lock.withLock { _lastReading } }

    /// V5 E2/E3 — form labels and the spreadsheet column header. Live: `LiveFocusedFieldDetails`
    /// when `system` is the live one; tests inject a mock; `nil` reads nothing extra.
    public var details: FocusedFieldDetailsReading?
    /// V5 E4 — where bundle IDs the category table had to guess for are noted.
    public var unknownApps: UnknownApps = .shared

    public init(system: SystemAccess, window: Int = CaretWindow.defaultWindow,
                landingMemory: LandingMemory? = nil,
                capabilities: CaretCapabilityMemory = CaretCapabilityMemory(),
                unknownApps: UnknownApps = .shared,
                details: FocusedFieldDetailsReading? = nil) {
        self.system = system
        self.window = window
        self.landingMemory = landingMemory ?? LandingMemory.attached(to: system)
        self.capabilities = capabilities
        self.unknownApps = unknownApps
        self.details = details ?? (system as? FocusedFieldDetailsReading)
            ?? (system is LiveSystemAccess ? LiveFocusedFieldDetails() : nil)
    }

    /// `nil` only when there is no readable focused element at all (no accessibility permission,
    /// nothing focused). A field that answers with a role but no hints is not nil: it is a
    /// `FieldContext` with `hints == []`, which classifies by role + app exactly as before.
    public func fieldContext(bundleID: String?) -> FieldContext? {
        // Q2 — Electron / Chromium build their AX tree only when asked: ask before the caret read.
        if let focus = system.frontmostApp(), !OwnProcess.owns(focus) {
            (system as? AppAccessibilityEnabling)?.enableAppAccessibility(pid: focus.pid)
        }
        guard let info = try? system.focusedElement() else { return nil }
        let reading = readCaret(info: info, bundleID: bundleID)
        var field = Self.fieldContext(from: info, bundleID: bundleID, caret: reading.caret)
        enrich(&field, info: info)
        return field
    }

    /// V5 E2/E3/E4 — what the role and the four hint attributes do not say.
    ///
    /// * E3: a web form field's label (`AXTitleUIElement`), placeholder and help join `hints`,
    ///   so `FieldRules` sees "Email", "Phone", "Search", "Password" however the page labels it.
    /// * E2: the browser document's URL (a Google Sheets cell) and, for a cell, its column header.
    /// * E4: a bundle ID the category table only guessed for is noted for the next revision.
    /// Nothing is read from our own process, and a password field gets no extra reads at all.
    public func enrich(_ field: inout FieldContext, info: FocusedElementInfo) {
        let frontmost = system.frontmostApp()
        let bundle = field.appBundleID ?? frontmost?.bundleID
        if let bundle, !bundle.isEmpty { _ = AppCategoryTable.categoryNotingUnknown(for: bundle, log: unknownApps) }
        guard !info.isSecure, !OwnProcess.owns(frontmost) else { return }
        let pid = frontmost?.pid
        if FieldRole.textEntryRoles.contains(info.role), let details, let pid {
            let labels = details.focusedFieldLabels(pid: pid)
            if !labels.isEmpty { field.hints = FocusedElementInfo.hints(from: (field.hints + labels).map { Optional($0) }) }
        }
        if Self.isBrowser(bundle), let reader = system as? FocusedDocumentURLReading {
            field.documentURL = reader.focusedDocumentURL()
        }
        if FieldRole.classify(field) == .spreadsheetCell, let details, let pid {
            field.columnHeader = details.focusedCellColumnHeader(pid: pid).map { String($0.prefix(80)) }
        }
    }

    /// Browsers whose web area carries the document URL (release-channel suffixes included).
    public static let browserBundleIDs: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "com.brave.Browser",
        "com.microsoft.edgemac", "org.mozilla.firefox", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
        "com.kagi.kagimacOS", "app.zen-browser.zen", "com.apple.SafariTechnologyPreview", "org.chromium.Chromium",
    ]

    public static func isBrowser(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return browserBundleIDs.contains(bundleID) || browserBundleIDs.contains { bundleID.hasPrefix($0 + ".") }
    }

    /// The caret rungs for the element `info` describes.
    public func readCaret(info: FocusedElementInfo, bundleID: String?) -> CaretReading {
        let reading = computeCaret(info: info, bundleID: bundleID)
        lock.withLock { _lastReading = reading }
        return reading
    }

    private func computeCaret(info: FocusedElementInfo, bundleID: String?) -> CaretReading {
        // A password field is refused by its role; nothing around its caret is ever read.
        if info.isSecure { return CaretReading(caret: .unknown, rung: .none) }
        let frontmost = system.frontmostApp()
        let bundle = bundleID ?? frontmost?.bundleID ?? ""

        // Rung 1 — free: `focusedElement()` already carried the value and the range.
        if let caret = info.caretFromSelectedRange(window: window) {
            capabilities.note(bundleID: bundle, answered: true)
            return CaretReading(caret: caret, rung: .selectedRange)
        }
        // Rung 2 — the marker round-trip, unless this app has never answered it (D7).
        if !capabilities.shouldSkipAXRoundTrip(bundleID: bundle),
           let markers = system as? TextMarkerCaretReading,
           let read = markers.caretByTextMarkers() {
            capabilities.note(bundleID: bundle, answered: true)
            return CaretReading(caret: read.caretState(window: window), rung: .textMarkers)
        }
        capabilities.note(bundleID: bundle, answered: false)
        // Rung 3 — our own last landing into this very element (D5).
        if let element = LandedElement(focus: frontmost, role: info.role),
           let caret = landingMemory.caret(for: element) {
            return CaretReading(caret: caret, rung: .landingMemory)
        }
        return CaretReading(caret: .unknown, rung: .none)
    }

    public static func fieldContext(from info: FocusedElementInfo, bundleID: String?,
                                    caret: CaretState) -> FieldContext {
        FieldContext(appBundleID: bundleID,
                     axRole: info.role,
                     axSubrole: info.subrole,
                     hints: info.hints,
                     caret: caret)
    }

    /// Splits the field value at the caret, bounded to `window` UTF-16 units either side.
    /// `nil` when there is no range, or it does not fit the value: no caret is not "the end".
    static func textAroundCaret(value: String?, range: Range<Int>?, window: Int) -> (String, String)? {
        guard let value, let range, let split = CaretWindow.split(value: value, range: range, window: window) else { return nil }
        return (split.before, split.after)
    }
}

/// D7 (V4.5) — per-app memory of "the caret could not be read here".
///
/// After `threshold` landings in a row in one app where every AX rung came back empty, the
/// text-marker round-trip is skipped for that app (the landing memory still answers). The first
/// read in which a rung answers resets the app's count. In memory only, like `MethodRouter`'s
/// per-app method table: an app update may fix its accessibility, so nothing is persisted.
public final class CaretCapabilityMemory: @unchecked Sendable {
    public static let defaultThreshold = 5

    public let threshold: Int
    private let lock = NSLock()
    private var misses: [String: Int] = [:]

    public init(threshold: Int = CaretCapabilityMemory.defaultThreshold) {
        self.threshold = max(1, threshold)
    }

    public func shouldSkipAXRoundTrip(bundleID: String) -> Bool {
        lock.withLock { (misses[bundleID] ?? 0) >= threshold }
    }

    /// Records one read in `bundleID`: `answered` resets the count, otherwise it grows (capped).
    public func note(bundleID: String, answered: Bool) {
        lock.withLock {
            if answered { misses[bundleID] = nil }
            else { misses[bundleID] = min((misses[bundleID] ?? 0) + 1, threshold) }
        }
    }

    public func misses(for bundleID: String) -> Int {
        lock.withLock { misses[bundleID] ?? 0 }
    }
}

// MARK: - V5 E2/E3 · labels and column headers

/// The two reads `FocusedElementInfo` does not carry. Additive: `SystemAccess` is unchanged.
public protocol FocusedFieldDetailsReading: AnyObject {
    /// The focused element's label (`AXTitleUIElement` → its title / value / description), its
    /// placeholder (`AXPlaceholderValue`) and help (`AXHelp`). `[]` when none.
    func focusedFieldLabels(pid: Int32) -> [String]
    /// The column header over the focused cell (`AXColumnHeaderUIElements`), when there is one.
    func focusedCellColumnHeader(pid: Int32) -> String?
}

/// Live AX reads, addressed through the app element for `pid` (never the system-wide element,
/// so a call can never land in our own process — `FieldContextReader` skips our pid as well).
/// Every element gets a short messaging timeout: a hung app costs at most a fraction of a second.
public final class LiveFocusedFieldDetails: FocusedFieldDetailsReading, @unchecked Sendable {
    public var timeout: Float = 0.15
    public init() {}

    public func focusedFieldLabels(pid: Int32) -> [String] {
        guard let element = focused(pid: pid) else { return [] }
        var out: [String?] = []
        if let label = child(element, "AXTitleUIElement") {
            out.append(string(label, kAXTitleAttribute))
            out.append(string(label, kAXValueAttribute))
            out.append(string(label, kAXDescriptionAttribute))
        }
        out.append(string(element, "AXPlaceholderValue"))
        out.append(string(element, kAXHelpAttribute))
        return FocusedElementInfo.hints(from: out.map { $0.map { String($0.prefix(120)) } })
    }

    public func focusedCellColumnHeader(pid: Int32) -> String? {
        guard let element = focused(pid: pid) else { return nil }
        // The cell itself, or the in-cell editor's nearest AXCell ancestor.
        var cell: AXUIElement? = element
        var hops = 0
        while let current = cell, string(current, kAXRoleAttribute) != "AXCell", hops < 6 {
            cell = child(current, kAXParentAttribute); hops += 1
        }
        guard let cell, string(cell, kAXRoleAttribute) == "AXCell" else { return nil }
        if let header = children(cell, "AXColumnHeaderUIElements").lazy.compactMap(title(of:)).first { return header }
        guard let column = range(cell, "AXColumnIndexRange")?.location else { return nil }
        var table: AXUIElement? = child(cell, kAXParentAttribute)
        hops = 0
        while let current = table, !["AXTable", "AXGrid", "AXOutline"].contains(string(current, kAXRoleAttribute) ?? ""), hops < 6 {
            table = child(current, kAXParentAttribute); hops += 1
        }
        guard let table else { return nil }
        let headers = children(table, "AXColumnHeaderUIElements")
        guard column >= 0, column < headers.count else { return nil }
        return title(of: headers[column])
    }

    // MARK: AX plumbing

    private func focused(pid: Int32) -> AXUIElement? {
        guard pid != getpid() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        let element = child(app, kAXFocusedUIElementAttribute)
        if let element { AXUIElementSetMessagingTimeout(element, timeout) }
        return element
    }

    private func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &out) == .success else { return nil }
        return out
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        let text = (value(element, attribute) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty ?? true) ? nil : text
    }

    private func child(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let raw = value(element, attribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast
        return (raw as! AXUIElement)
    }

    private func children(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        guard let raw = value(element, attribute) as? [AnyObject] else { return [] }
        return raw.compactMap { item in
            CFGetTypeID(item) == AXUIElementGetTypeID() ? (item as! AXUIElement) : nil // swiftlint:disable:this force_cast
        }
    }

    private func range(_ element: AXUIElement, _ attribute: String) -> CFRange? {
        guard let raw = value(element, attribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var out = CFRange()
        // swiftlint:disable:next force_cast
        return AXValueGetValue(raw as! AXValue, .cfRange, &out) ? out : nil
    }

    private func title(of element: AXUIElement) -> String? {
        (string(element, kAXTitleAttribute) ?? string(element, kAXValueAttribute) ?? string(element, kAXDescriptionAttribute))
            .map { String($0.prefix(80)) }
    }
}
