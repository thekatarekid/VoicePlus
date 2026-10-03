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
    /// V5 K10 / Q14 — the OCR caret band (opt-in, Screen Recording): AX and the landing memory
    /// had nothing.
    case ocr
    /// Nothing answered, or the field is a password field (never read): `unknown`.
    case none
}

public struct CaretReading: Sendable, Equatable {
    public var caret: CaretState
    public var rung: CaretRung
    /// Q14 — the caret on screen (global AppKit points), when the OCR band found it (Q5's anchor).
    public var caretRect: CGRect?

    public init(caret: CaretState, rung: CaretRung, caretRect: CGRect? = nil) {
        self.caret = caret; self.rung = rung; self.caretRect = caretRect
    }
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
    /// V5 K10 / Q14 — the OCR rung (last before `unknown`). Live: `LiveOCRCaret` over a
    /// `ScreenTextService` when `system` is the live one. Asked only when `ocrOptIn()` and the
    /// app's contextual reading are both on.
    public var ocr: OCRCaretReading?
    /// The user's switch (Settings: "Read the caret from the screen", off by default).
    public var ocrOptIn: () -> Bool = { CaretOCRSettings.isEnabled() }

    /// V5 E6 — To/Cc of a mail compose, the chat title of a messenger. Live when `system` is the
    /// live one; `nil` reads no participants.
    public var participantsReader: ThreadParticipantsReading?
    /// The destination app's "contextual reading" rule (Settings › Dictionary & Apps). Off: no
    /// participants and no OCR rung — nothing more than the field itself is read.
    public var contextualReading: (String?) -> Bool = { bundleID in
        guard let bundleID, !bundleID.isEmpty else { return true }
        return AppRules.current().resolved(for: bundleID).contextualReading.value
    }

    public init(system: SystemAccess, window: Int = CaretWindow.defaultWindow,
                landingMemory: LandingMemory? = nil,
                capabilities: CaretCapabilityMemory = CaretCapabilityMemory(),
                unknownApps: UnknownApps = .shared,
                details: FocusedFieldDetailsReading? = nil,
                participants: ThreadParticipantsReading? = nil,
                ocr: OCRCaretReading? = nil) {
        self.system = system
        self.window = window
        self.landingMemory = landingMemory ?? LandingMemory.attached(to: system)
        self.capabilities = capabilities
        self.unknownApps = unknownApps
        self.details = details ?? (system as? FocusedFieldDetailsReading)
            ?? (system is LiveSystemAccess ? LiveFocusedFieldDetails() : nil)
        self.participantsReader = participants ?? (system as? ThreadParticipantsReading)
            ?? (system is LiveSystemAccess ? LiveThreadParticipants() : nil)
        self.ocr = ocr ?? (system is LiveSystemAccess ? LiveOCRCaret(service: ScreenTextService()) : nil)
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
        // N10 (4) — "web content" comes from the tree: the focused element's `AXWebArea` ancestor.
        // Only a proved `true` is written; `nil` keeps the URL fallback in `FieldContext`.
        if field.isInWebArea == nil, (system as? WebAreaProbing)?.focusedIsInWebArea() == true { field.isInWebArea = true }
        if Self.isBrowser(bundle) || field.isInWebArea == true {
            if let reader = system as? FocusedDocumentURLReading { field.documentURL = reader.focusedDocumentURL() }
            // V5 E5 — the page title routes the sub-app when the web area hides its URL.
            if field.documentURL == nil, let details, let pid {
                field.documentTitle = details.focusedDocumentTitle(pid: pid).map { String($0.prefix(200)) }
            }
        }
        resolveSurface(&field, info: info, pid: pid)
        if FieldRole.classify(field) == .spreadsheetCell, let details, let pid {
            field.columnHeader = details.focusedCellColumnHeader(pid: pid).map { String($0.prefix(80)) }
        }
        // V5 E6 — who the text is for (mail To/Cc, the chat's title), only where a thread exists.
        if let reader = participantsReader, let pid, contextualReading(bundle) {
            let category = field.subApp?.category ?? AppCategoryTable.category(for: bundle)
            if category == .mail || category == .chat {
                var observation = reader.observe(pid: pid, category: category)
                if observation.title == nil { observation.title = field.documentTitle }
                field.participants = ThreadParticipants.extract(category: category, observation: observation)
            }
        }
    }

    /// N9 — a browser per the one seed table (release-channel suffixes included). No private
    /// list: an unlisted browser's web content is found by its `AXWebArea` ancestor instead.
    public static func isBrowser(_ bundleID: String?) -> Bool {
        SeedHints.hint(for: bundleID)?.family == .browser
    }

    // MARK: N9 — AX evidence into the resolver

    /// N9 — the field's own evidence (`FieldContext.surfaceEvidence`) plus what only the live
    /// tree knows: whether the element accepts text, and how the app is built (bundle sniff,
    /// N5/N10). Secure input is deliberately *not* fed here: it is a write-time check (N4), and a
    /// terminal with Secure Keyboard Entry holds it all day without being a password field.
    public static func surfaceEvidence(field: FieldContext, info: FocusedElementInfo,
                                       runtime: SurfaceRuntime?) -> SurfaceEvidence {
        var evidence = field.surfaceEvidence
        evidence.isEditable = CanvasFocus.isEditableText(info) ? true : (CanvasFocus.isCanvasElement(info) ? false : nil)
        if let runtime, runtime != .unknown { evidence.runtime = runtime }
        return evidence
    }

    /// N9 — resolves with the AX evidence. When it changes the field-only answer (a canvas the
    /// role says is not editable, an unlisted Chromium/Electron app's composer) the richer answer
    /// is pinned as `upstreamSurface`, so every reader of `field.surface` agrees with the injector.
    public func resolveSurface(_ field: inout FieldContext, info: FocusedElementInfo, pid: Int32?) {
        guard field.upstreamSurface == nil, !info.isSecure else { return }
        let runtime = pid.flatMap { (system as? AppRuntimeReading)?.appRuntime(pid: $0) }
        let full = SurfaceResolver.resolve(Self.surfaceEvidence(field: field, info: info, runtime: runtime))
        if full.kind != field.surface.kind { field.upstreamSurface = full.kind }
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
            // Hands-free fix (RC6) — our own landing went into this element moments ago and nothing
            // has touched it since, yet the AX value/range does not show it before the caret yet
            // (Claude / Electron refresh AX after a keystroke write lazily). That reading is stale:
            // join onto what we typed instead, or the next piece loses its space, capital and stop.
            // Web content only: a native text view's AX is current the moment the write returns.
            if let focus = frontmost, !OwnProcess.owns(focus),
               (system as? AppRuntimeReading)?.appRuntime(pid: focus.pid).isWebContent == true,
               let element = LandedElement(focus: focus, role: info.role),
               let remembered = landingMemory.caret(for: element),
               Self.readingMissesLanding(caret, landed: landingMemory.last?.text) {
                capabilities.note(bundleID: bundle, rung: .landingMemory, answered: true)
                return CaretReading(caret: remembered, rung: .landingMemory)
            }
            capabilities.note(bundleID: bundle, answered: true)
            capabilities.note(bundleID: bundle, rung: .selectedRange, answered: true)
            return CaretReading(caret: caret, rung: .selectedRange)
        }
        // Rung 2 — the marker round-trip, unless this app has never answered it (D7).
        if !capabilities.shouldSkipAXRoundTrip(bundleID: bundle),
           let markers = system as? TextMarkerCaretReading,
           let read = markers.caretByTextMarkers() {
            capabilities.note(bundleID: bundle, answered: true)
            capabilities.note(bundleID: bundle, rung: .textMarkers, answered: true)
            return CaretReading(caret: read.caretState(window: window), rung: .textMarkers)
        }
        capabilities.note(bundleID: bundle, answered: false)
        // Rung 3 — our own last landing into this very element (D5).
        if let element = LandedElement(focus: frontmost, role: info.role),
           let caret = landingMemory.caret(for: element) {
            capabilities.note(bundleID: bundle, rung: .landingMemory, answered: true)
            return CaretReading(caret: caret, rung: .landingMemory)
        }
        // Rung 4 (K10 / Q14) — the OCR band: only with the switch on and contextual reading
        // allowed for this app, and not in an app whose band has never answered.
        if let ocr, let focus = frontmost, !OwnProcess.owns(focus), ocrOptIn(), contextualReading(bundle),
           !capabilities.shouldSkip(.ocr, bundleID: bundle) {
            let band = ocr.caretBand(pid: focus.pid, bundleID: bundle, lastLanded: landingMemory.last?.text)
            capabilities.note(bundleID: bundle, rung: .ocr, answered: band != nil)
            if let band { return CaretReading(caret: band.caretState(window: window), rung: .ocr, caretRect: band.caretRect) }
        }
        capabilities.note(bundleID: bundle, rung: .none, answered: true)
        return CaretReading(caret: .unknown, rung: .none)
    }

    /// RC6 — does an AX caret reading fail to show our last landing just before the caret? Compared
    /// on the last characters of what we typed, whitespace-trimmed on both sides.
    static func readingMissesLanding(_ caret: CaretState, landed: String?) -> Bool {
        guard let landed, let before = caret.textBefore else { return false }
        let ours = landed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ours.isEmpty else { return false }
        // Smart quotes and dashes an editor substitutes are still our text.
        func plain(_ s: String) -> String {
            s.replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "\u{2018}", with: "'")
                .replacingOccurrences(of: "\u{201C}", with: "\"").replacingOccurrences(of: "\u{201D}", with: "\"")
                .replacingOccurrences(of: "\u{2014}", with: "-").replacingOccurrences(of: "\u{2013}", with: "-")
        }
        let tail = String(plain(ours).suffix(16))
        let shown = plain(before.trimmingCharacters(in: .whitespacesAndNewlines))
        return !shown.hasSuffix(tail)
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

    // MARK: K10 — the ladder per app

    private var rungMisses: [String: [CaretRung: Int]] = [:]
    private var answering: [String: CaretRung] = [:]

    /// K10 — skip `rung` in `bundleID`: it came back empty `threshold` times in a row. The text
    /// markers keep D7's own counter (`shouldSkipAXRoundTrip`); `selectedRange` is free and the
    /// landing memory is in-process, so neither is ever skipped.
    public func shouldSkip(_ rung: CaretRung, bundleID: String) -> Bool {
        switch rung {
        case .textMarkers: return shouldSkipAXRoundTrip(bundleID: bundleID)
        case .ocr: return lock.withLock { (rungMisses[bundleID]?[rung] ?? 0) >= threshold }
        case .selectedRange, .landingMemory, .none: return false
        }
    }

    /// K10 — record one read of `rung` in `bundleID`. `answered` resets its count and records the
    /// rung as the one this app answers on (`.none` = nothing answered).
    public func note(bundleID: String, rung: CaretRung, answered: Bool) {
        lock.withLock {
            if answered {
                rungMisses[bundleID]?[rung] = nil
                answering[bundleID] = rung
            } else {
                rungMisses[bundleID, default: [:]][rung] = min((rungMisses[bundleID]?[rung] ?? 0) + 1, threshold)
            }
        }
    }

    /// K10 — the rung that last produced this app's caret (`.none`: the ladder ran dry), for
    /// diagnostics. `nil` before the first read.
    public func lastRung(for bundleID: String) -> CaretRung? {
        lock.withLock { answering[bundleID] }
    }

    /// K10 — consecutive empty reads of `rung` in `bundleID`.
    public func misses(for bundleID: String, rung: CaretRung) -> Int {
        if rung == .textMarkers { return misses(for: bundleID) }
        return lock.withLock { rungMisses[bundleID]?[rung] ?? 0 }
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
    /// V5 E5 — the title of the web document holding the focused element (its `AXWebArea`'s
    /// `AXTitle`), else the focused window's title. `nil` when neither is exposed.
    func focusedDocumentTitle(pid: Int32) -> String?
}

public extension FocusedFieldDetailsReading {
    func focusedDocumentTitle(pid: Int32) -> String? { nil }
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

    public func focusedDocumentTitle(pid: Int32) -> String? {
        guard let element = focused(pid: pid) else { return nil }
        var current: AXUIElement? = element
        var hops = 0
        while let node = current, hops < 25 {
            if string(node, kAXRoleAttribute) == "AXWebArea", let title = string(node, kAXTitleAttribute) { return title }
            current = child(node, kAXParentAttribute); hops += 1
        }
        guard let app = AXGuard.application(pid: pid) else { return nil }
        AXUIElementSetMessagingTimeout(app, timeout)
        return child(app, kAXFocusedWindowAttribute).flatMap { string($0, kAXTitleAttribute) }
    }

    // MARK: AX plumbing

    private func focused(pid: Int32) -> AXUIElement? {
        guard pid != getpid() else { return nil }
        guard let app = AXGuard.application(pid: pid) else { return nil }
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

// MARK: - V5 E5 / E6 · persona keyed by `bundle|host`, overrides by thread participant

/// The lander decorates the context with the app's persona before the field is read. Once the
/// field is known, two things can change which persona applies:
///
/// * E5 — the field is inside a browser sub-app (Gmail in Chrome): the persona is keyed
///   `bundle|host` (`com.google.Chrome|mail.google.com`), auto-drafted from the sub-app's category.
/// * E6 — the thread's participants were read (To/Cc, the chat title): a per-recipient override
///   on that persona applies.
///
/// Neither: nothing changes. A persona set by a caller before decoration (the Lab, a test) is
/// replaced only when the field says something new.
public enum FieldPersonaRedecoration {
    public static func apply(_ field: FieldContext, to context: inout StageContext, manager: PersonaManager?) {
        guard let manager else { return }
        let bundle = context.appBundleID
        let key = field.personaKey ?? bundle
        let keyed = key != nil && key != bundle
        guard keyed || !field.participants.isEmpty else { return }
        var probe = context
        probe.appBundleID = key
        probe.extra[StageContextParticipants.key] = context.extra[StageContextParticipants.key]
        guard let resolved = try? manager.resolve(context: probe) else { return }
        guard keyed || resolved.override != nil else { return }
        context.extra[PersonaManager.promptKey] = resolved.promptText
    }
}
