import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// N27 (round-1 P2-4, F31) — the ribbon's opt-in OCR caret-band rung. Canvas editors (Google Docs, Figma)
// give no AX caret and, in Docs, an off-display hidden textarea; with the user's Q14 switch on
// (Settings › Insertion "Confirm in apps that hide their text", Screen Recording) the ribbon may aim at
// the caret the band read finds. Geometry only: the band's recognised text is dropped here and never
// reaches the context reader, the rubric, the formatter or diagnostics — this rung NEVER feeds context.

/// Where the OCR rung's caret comes from. AppKit global points (as `CaretBandReading.caretRect`).
protocol TapeFlightOCRCaretSource: AnyObject {
    /// The caret in `pid`'s focused field, or `nil` (switch off, no permission, no caret, timed out).
    func caretRect(pid: Int32) -> CGRect?
}

/// The live source over K9's band read (`LiveOCRCaret`). Gated on the opt-in switch before any capture;
/// asks with no landed text (the ribbon aims at the pre-insertion caret, so the blink finds it) and a
/// short deadline — the ribbon is decoration and must not linger.
final class OCRBandRibbonSource: TapeFlightOCRCaretSource, @unchecked Sendable {
    private let band: OCRCaretReading
    private let isEnabled: () -> Bool

    init(band: OCRCaretReading, isEnabled: @escaping () -> Bool = { CaretOCRSettings.isEnabled() }) {
        self.band = band
        self.isEnabled = isEnabled
    }

    /// Live: K9's band reader with the ribbon's tighter deadline.
    static func live() -> OCRBandRibbonSource {
        let reader = LiveOCRCaret(service: ScreenTextService())
        reader.deadline = deadline
        return OCRBandRibbonSource(band: reader)
    }
    static let deadline: TimeInterval = 0.8

    func caretRect(pid: Int32) -> CGRect? {
        guard isEnabled(), pid > 0, pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        // Only the rect leaves this scope; `before` / `after` are discarded with the reading.
        guard let rect = band.caretBand(pid: pid, bundleID: "", lastLanded: nil)?.caretRect else { return nil }
        return rect
    }
}

enum TapeFlightOCRRung {
    /// AppKit global points (y up, origin bottom-left of the primary display) to AX (y down from the
    /// primary display's top).
    static func axRect(fromAppKit rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}

extension AXTapeFlightCaret {
    /// N27 — the focused element's process, then the OCR source, converted to AX coordinates.
    func ocrBandCaretRect() -> CGRect? {
        guard let ocr, let element = TapeFlightAX.focusedElement() else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, let rect = ocr.caretRect(pid: pid) else { return nil }
        return TapeFlightOCRRung.axRect(fromAppKit: rect, primaryScreenHeight: CGDisplayBounds(CGMainDisplayID()).height)
    }
}
