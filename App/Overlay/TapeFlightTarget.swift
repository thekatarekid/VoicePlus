import AppKit
import ApplicationServices
import Foundation
import Injection

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
        switch TapeFlightPlanner.verify(arming, now: prober.probe(), insertedLength: insertedLength) {
        case .failure(let reason):
            return .failure(reason)
        case .success(let target):
            guard let rect = caret.caretRect(at: target.insertionIndex) else { return .failure(.caretUnavailable) }
            return .success(rect)
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
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, messagingTimeout)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
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
