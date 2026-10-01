import AppKit
import ApplicationServices
import Foundation
import Injection
import Shared

// S4 — the flight's reads of the destination. They run off the main thread (a slow app can never stall
// the pill) and never write anything: the flight subscribes to the turn, it does not take part in it.

/// Reads the focused element: identity, selection, secure flag.
protocol TapeFlightProbing: AnyObject {
    func probe() -> TapeFlightProbe
}

/// Measures the insertion point in the focused element, in AX coordinates (Quartz global: top-left of
/// the primary display, y down). Conversion to the screen happens on the main thread, where the display
/// arrangement is read.
protocol TapeFlightCaretReading: AnyObject {
    func caretRect(at index: Int) -> CGRect?
    /// The bounds of a range of the focused element's text (the destination tape cue's landed text), in
    /// AX coordinates; `nil` when the app will not measure it.
    func rangeRect(_ range: Range<Int>) -> CGRect?
    func lineRects(_ range: Range<Int>) -> [CGRect]
    func lineMeasurements(_ range: Range<Int>) -> [TapeFlightLineMeasurement]
    /// Q5 rung 2 — Chromium / WebKit: `AXSelectedTextMarkerRange` measured by
    /// `AXBoundsForTextMarkerRange`. AX coordinates; `nil` when the element has no text markers.
    func textMarkerCaretRect() -> CGRect?
    /// Q5 rung 3 — the focused element's frame (`AXPosition` + `AXSize`). AX coordinates.
    func focusedElementFrame() -> CGRect?
    /// Q5 rung 4 — the focused element's window frame. AX coordinates.
    func focusedWindowFrame() -> CGRect?
}

extension TapeFlightCaretReading {
    func textMarkerCaretRect() -> CGRect? { nil }
    func focusedElementFrame() -> CGRect? { nil }
    func focusedWindowFrame() -> CGRect? { nil }
    func lineMeasurements(_ range: Range<Int>) -> [TapeFlightLineMeasurement] {
        lineRects(range).map { TapeFlightLineMeasurement(rect: $0) }
    }
    func rangeRect(_ range: Range<Int>) -> CGRect? { nil }
    func lineRects(_ range: Range<Int>) -> [CGRect] { rangeRect(range).map { [$0] } ?? [] }
}

/// Q5 — which rung of the caret ladder a flight is aimed by. Only `.boundsForRange` is precise enough to
/// measure the landed lines and draw the destination tape cue; the others aim the ribbon and nothing more.
enum TapeFlightRung: Int, CaseIterable, Comparable, Sendable {
    /// `AXBoundsForRange` at the insertion index (`TapeFlightCaretLocator`).
    case boundsForRange
    /// Chromium / WebKit text-marker caret.
    case textMarker
    /// The focused element's frame.
    case elementFrame
    /// The focused window's frame.
    case windowFrame

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    var isPrecise: Bool { self == .boundsForRange }
}

/// One aim: where, and how it was found.
struct TapeFlightFix: Equatable, Sendable {
    var rect: CGRect
    var rung: TapeFlightRung
}

/// Q5 — the ribbon is independent of verification: it aims at the best geometry the destination will
/// give, rung by rung, and only a missing destination (no rung at all) or a contradicted one
/// (`.targetChanged`, decided by the planner) suppresses it.
enum TapeFlightTargetLadder {
    static func resolve(insertionIndex: Int?, caret: TapeFlightCaretReading) -> TapeFlightFix? {
        if let index = insertionIndex, let rect = usable(caret.caretRect(at: index)) {
            return TapeFlightFix(rect: rect, rung: .boundsForRange)
        }
        if let rect = usable(caret.textMarkerCaretRect()) { return TapeFlightFix(rect: rect, rung: .textMarker) }
        if let rect = usable(caret.focusedElementFrame()) { return TapeFlightFix(rect: rect, rung: .elementFrame) }
        if let rect = usable(caret.focusedWindowFrame()) { return TapeFlightFix(rect: rect, rung: .windowFrame) }
        return nil
    }

    /// Finite, non-negative width, positive height: anything else is not geometry.
    static func usable(_ rect: CGRect?) -> CGRect? {
        guard let rect, rect.height > 0, rect.width >= 0,
              [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite) else { return nil }
        return rect
    }
}

/// The flight's reads, confined to one serial queue: the preview's pre-insertion sample, then the
/// verification and caret measurement at insertion and on every refresh. Because the queue is serial,
/// an `.inserting` read always sees the sample its preview asked for, however late that sample ran.
final class TapeFlightReader: @unchecked Sendable {
    private let prober: TapeFlightProbing
    private let caret: TapeFlightCaretReading
    private var arming: TapeFlightArming?

    init(probe: TapeFlightProbing, caret: TapeFlightCaretReading) {
        prober = probe
        self.caret = caret
    }

    /// While the final preview is up: remember the destination and the pre-insertion caret.
    @discardableResult
    func arm() -> TapeFlightArming {
        let arming = TapeFlightPlanner.arm(prober.probe())
        self.arming = arming
        return arming
    }

    func disarm() {
        arming = nil
    }

    /// Verify the destination against the sample, then measure the pre-insertion caret. AX coordinates.
    func locate(insertedLength: Int) -> Result<CGRect, TapeFlightSuppression> {
        locateFix(insertedLength: insertedLength).map(\.rect)
    }

    /// Q5 — verify, then aim by the caret ladder (`TapeFlightTargetLadder`).
    func locateFix(insertedLength: Int) -> Result<TapeFlightFix, TapeFlightSuppression> {
        switch TapeFlightPlanner.verify(arming, now: prober.probe(), insertedLength: insertedLength) {
        case .failure(let reason):
            return .failure(reason)
        case .success(let target):
            guard let fix = TapeFlightTargetLadder.resolve(insertionIndex: target.insertionIndex, caret: caret) else {
                return .failure(.caretUnavailable)
            }
            if case .failure(let reason) = TapeFlightPlanner.verify(arming, now: prober.probe(), insertedLength: insertedLength) {
                return .failure(reason)
            }
            return .success(fix)
        }
    }

    /// After the write: the same element, the caret inside what this write put there, and the bounds of
    /// that landed text (the destination tape cue's line). AX coordinates.
    func landedRect(insertedLength: Int) -> Result<CGRect, TapeFlightSuppression> {
        switch TapeFlightPlanner.verify(arming, now: prober.probe(), insertedLength: insertedLength) {
        case .failure(let reason):
            return .failure(reason)
        case .success(let target):
            guard let start = target.insertionIndex else { return .failure(.caretUnavailable) }
            guard insertedLength > 0, let rect = caret.rangeRect(start ..< start + insertedLength) else {
                return .failure(.caretUnavailable)
            }
            return .success(rect)
        }
    }
    /// Only measured after acknowledged delivery; never infer line widths from the transcript.
    func landedLines(insertedLength: Int) -> Result<[CGRect], TapeFlightSuppression> {
        landedMeasurements(insertedLength: insertedLength).map { $0.map(\.rect) }
    }

    func landedMeasurements(insertedLength: Int) -> Result<[TapeFlightLineMeasurement], TapeFlightSuppression> {
        switch TapeFlightPlanner.verify(arming, now: prober.probe(), insertedLength: insertedLength) {
        case .failure(let reason): return .failure(reason)
        case .success(let target):
            guard insertedLength > 0, let start = target.insertionIndex else { return .failure(.caretUnavailable) }
            let rects = caret.lineMeasurements(start ..< start + insertedLength)
            if case .failure(let reason) = TapeFlightPlanner.verify(arming, now: prober.probe(), insertedLength: insertedLength) {
                return .failure(reason)
            }
            guard !rects.isEmpty else { return .failure(.caretUnavailable) }
            return .success(rects)
        }
    }

}

// MARK: - Live Accessibility reads

/// The focused element through Accessibility, with a short messaging timeout so an unresponsive app
/// costs the flight a quarter second, not AX's default six.
enum TapeFlightAX {
    static let messagingTimeout: Float = 0.25

    static func focusedElement() -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXGuard.systemWide()   // K18
        AXUIElementSetMessagingTimeout(system, messagingTimeout)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        // Never perform synchronous AX requests back into our own main-thread TextKit editor.
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        return element
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}

/// Live probe: the focused element's process, identity (`CFHash`, as `LiveSystemAccess` tokens it), role
/// and subrole (a password field by either), and selected range.
final class AXTapeFlightProbe: TapeFlightProbing {
    init() {}

    func probe() -> TapeFlightProbe {
        guard let element = TapeFlightAX.focusedElement() else { return TapeFlightProbe(focus: nil, selection: nil) }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return TapeFlightProbe(focus: nil, selection: nil) }
        let app = NSRunningApplication(processIdentifier: pid)
        let focus = FocusSnapshot(pid: pid, bundleID: app?.bundleIdentifier ?? "unknown", appName: app?.localizedName ?? "",
                                  elementToken: String(CFHash(element)))
        let secure = [TapeFlightAX.string(element, kAXRoleAttribute), TapeFlightAX.string(element, kAXSubroleAttribute)]
            .contains(FocusedElementInfo.secureRole)
        // A password field's caret is never measured.
        guard !secure else { return TapeFlightProbe(focus: focus, selection: nil, isSecure: true) }
        var selection: Range<Int>?
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
           let value, CFGetTypeID(value) == AXValueGetTypeID() {
            var range = CFRange()
            // swiftlint:disable:next force_cast
            if AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0 {
                selection = range.location ..< range.location + range.length
            }
        }
        return TapeFlightProbe(focus: focus, selection: selection)
    }
}

/// Live caret: `kAXBoundsForRangeParameterizedAttribute` on the focused element, located per
/// `TapeFlightCaretLocator`. Unlike `AXWordRectProvider` it keeps zero-width caret rects and leaves the
/// result in AX coordinates (its conversion reads `NSScreen`, which belongs to the main thread).
final class AXTapeFlightCaret: TapeFlightCaretReading {
    init() {}

    func caretRect(at index: Int) -> CGRect? {
        guard let element = TapeFlightAX.focusedElement() else { return nil }
        return TapeFlightCaretLocator.locate(at: index) { range in Self.bounds(of: range, in: element) }
    }

    func rangeRect(_ range: Range<Int>) -> CGRect? {
        guard range.lowerBound >= 0, !range.isEmpty, let element = TapeFlightAX.focusedElement() else { return nil }
        return Self.bounds(of: range, in: element)
    }

    // MARK: Q5 — the coarser rungs

    func textMarkerCaretRect() -> CGRect? {
        guard let element = TapeFlightAX.focusedElement() else { return nil }
        var marker: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &marker) == .success,
              let marker else { return nil }
        var bounds: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, "AXBoundsForTextMarkerRange" as CFString,
                                                         marker, &bounds) == .success else { return nil }
        return Self.rect(bounds)
    }

    func focusedElementFrame() -> CGRect? {
        guard let element = TapeFlightAX.focusedElement() else { return nil }
        return Self.frame(of: element)
    }

    func focusedWindowFrame() -> CGRect? {
        guard let element = TapeFlightAX.focusedElement() else { return nil }
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast
        return Self.frame(of: window as! AXUIElement)
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        // swiftlint:disable force_cast
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        // swiftlint:enable force_cast
        return CGRect(origin: origin, size: extent)
    }

    static func rect(_ value: CFTypeRef?) -> CGRect? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        // swiftlint:disable:next force_cast
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    /// AX line/range APIs preserve real wrapping. Unsupported geometry simply omits the flourish.
    /// Limit work to the visible prefix and a short read budget; never scroll another app for decoration.
    func lineRects(_ range: Range<Int>) -> [CGRect] {
        lineMeasurements(range).map(\.rect)
    }

    func lineMeasurements(_ range: Range<Int>) -> [TapeFlightLineMeasurement] {
        guard range.lowerBound >= 0, !range.isEmpty, let element = TapeFlightAX.focusedElement() else { return [] }
        let deadline = Date().addingTimeInterval(0.12)
        var visible = range
        var visibleValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXVisibleCharacterRangeAttribute as CFString, &visibleValue) == .success,
           let value = visibleValue, CFGetTypeID(value) == AXValueGetTypeID() {
            var r = CFRange()
            if AXValueGetValue(value as! AXValue, .cfRange, &r), r.location >= 0, r.length >= 0 {
                let lower = max(range.lowerBound, r.location), upper = min(range.upperBound, r.location + r.length)
                guard upper > lower else { return [] }
                visible = lower ..< upper
            }
        }
        var index = visible.lowerBound, result: [TapeFlightLineMeasurement] = []
        while index < visible.upperBound, result.count < 32, Date() < deadline {
            var lineValue: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(element, kAXLineForIndexParameterizedAttribute as CFString,
                    NSNumber(value: index), &lineValue) == .success, let line = lineValue as? NSNumber else { break }
            var rangeValue: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(element, kAXRangeForLineParameterizedAttribute as CFString,
                    line, &rangeValue) == .success, let value = rangeValue, CFGetTypeID(value) == AXValueGetTypeID() else { break }
            var lineRange = CFRange()
            guard AXValueGetValue(value as! AXValue, .cfRange, &lineRange), lineRange.location >= 0,
                  lineRange.length > 0 else { break }
            let end = min(visible.upperBound, lineRange.location + lineRange.length)
            guard end > index else { break }
            guard let rect = Self.bounds(of: index ..< end, in: element), rect.width > 0, rect.height > 0 else { return [] }
            do {
                let startCaret = Self.bounds(of: index ..< index, in: element)
                let endCaret = Self.bounds(of: end ..< end, in: element)
                result.append(TapeFlightLineMeasurement(rect: rect,
                    rightToLeft: TapeFlightLineMeasurement.measuredRTL(rect: rect, start: startCaret, end: endCaret)))
            }
            index = end
        }
        // A timeout/unsupported later line must not masquerade as a complete measured paragraph.
        return index == visible.upperBound ? result : []
    }

    static func bounds(of range: Range<Int>, in element: AXUIElement) -> CGRect? {
        var cfRange = CFRange(location: range.lowerBound, length: range.count)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var bounds: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         rangeValue, &bounds) == .success,
              let bounds, CFGetTypeID(bounds) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        // swiftlint:disable:next force_cast
        guard AXValueGetValue(bounds as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }
}

/// Logical endpoint carets identify a pure RTL line only when they match its visual edges.
/// Wrapped/newline or mixed-direction caret geometry is not used to guess a direction.
struct TapeFlightLineMeasurement: Equatable, Sendable {
    var rect: CGRect
    var rightToLeft = false

    static func measuredRTL(rect: CGRect, start: CGRect?, end: CGRect?) -> Bool {
        guard let start, let end,
              [rect.minX, rect.maxX, rect.midY, start.midX, start.midY, end.midX, end.midY].allSatisfy(\.isFinite),
              start.width <= 2, end.width <= 2, start.height > 0, end.height > 0,
              abs(start.midY - rect.midY) <= 2, abs(end.midY - rect.midY) <= 2,
              abs(start.midX - rect.maxX) <= 2, abs(end.midX - rect.minX) <= 2 else { return false }
        return rect.width > 2
    }
}
