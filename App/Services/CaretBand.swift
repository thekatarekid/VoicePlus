import ApplicationServices
import CoreGraphics
import Foundation
import Pipeline
import Shared

// V5 Q14 + K9 — the OCR caret band (opt-in).
//
// For canvas editors (Google Docs, Figma, game-engine text) the accessibility tree has no caret
// and no text. With the user's switch on and Screen Recording granted, the focused field (or
// window) is captured, a three-line band around the caret is recognised, and the caret is found
// by the text we last landed or, failing that, by the caret's blink (two frames, diffed). The
// band fills `textBefore` / `textAfter` — the last rung of K10's ladder — and its caret rect is
// what Q5's ribbon anchors to. Frames live in memory for the read only; nothing is written.

/// What one band read found.
public struct CaretBandReading: Equatable, Sendable {
    public enum Method: String, Sendable, Equatable { case landedText, blink }
    public var before: String
    public var after: String
    /// The caret in global AppKit points (Q5 anchors the ribbon here).
    public var caretRect: CGRect
    public var method: Method

    public init(before: String, after: String, caretRect: CGRect, method: Method) {
        self.before = before; self.after = after; self.caretRect = caretRect; self.method = method
    }

    public func caretState(window: Int) -> CaretState {
        .known(before: String(before.suffix(window)), after: String(after.prefix(window)))
    }
}

/// The opt-in switch. Off by default; nothing on the band path runs while it is off.
public enum CaretOCRSettings {
    public static let enabledKey = "context.ocrCaretBand"
    public static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: enabledKey) }
}

// MARK: - Mapping math (pure)

public enum CaretBandGeometry {
    /// Lines in the band: the caret's, one above, one below.
    public static let bandLines = 3

    /// The band: `lines` line-heights tall, centred on the caret's line, as wide as `container`,
    /// clipped to it.
    public static func band(around caret: CGRect, lineHeight: CGFloat, lines: Int = bandLines, within container: CGRect) -> CGRect {
        let h = max(lineHeight, 1) * CGFloat(max(lines, 1))
        let band = CGRect(x: container.minX, y: caret.midY - h / 2, width: container.width, height: h)
        let clipped = band.intersection(container)
        return clipped.isNull ? .zero : clipped
    }

    /// x of the caret after the first `n` characters of `line` (characters assumed equal width —
    /// OCR boxes carry no per-glyph geometry).
    public static func caretX(in line: ScreenTextLine, afterCharacters n: Int) -> CGFloat {
        let count = max(line.text.count, 1)
        let k = min(max(n, 0), line.text.count)
        return line.box.minX + line.box.width * CGFloat(k) / CGFloat(count)
    }

    /// The character index nearest `x` in `line` (inverse of `caretX`).
    public static func characterIndex(in line: ScreenTextLine, atX x: CGFloat) -> Int {
        guard line.box.width > 0 else { return 0 }
        let f = (x - line.box.minX) / line.box.width
        return min(max(Int((f * CGFloat(line.text.count)).rounded()), 0), line.text.count)
    }

    /// The caret rect at character `n` of `line`: a 2-pt bar the line's height.
    public static func caretRect(in line: ScreenTextLine, afterCharacters n: Int) -> CGRect {
        CGRect(x: caretX(in: line, afterCharacters: n) - 1, y: line.box.minY, width: 2, height: line.box.height)
    }
}

// MARK: - Locating the caret in recognised lines (pure)

public enum CaretBandLocator {
    /// Lines ordered top to bottom (AppKit: larger y is higher), then left to right.
    static func ordered(_ lines: [ScreenTextLine]) -> [ScreenTextLine] {
        lines.sorted { a, b in
            abs(a.box.midY - b.box.midY) > min(a.box.height, b.box.height) / 2 ? a.box.midY > b.box.midY : a.box.minX < b.box.minX
        }
    }

    /// By what we last landed: the last line whose text contains the landed text's tail; the caret
    /// sits right after it. Matching is case-insensitive over collapsed whitespace, on the last
    /// `probe` characters (OCR rarely gets a long run perfect).
    public static func locate(lines: [ScreenTextLine], lastLanded: String, probe: Int = 24) -> CaretBandReading? {
        let tail = normalize(String(lastLanded.trimmingCharacters(in: .whitespacesAndNewlines).suffix(probe)))
        guard tail.count >= 3 else { return nil }
        let rows = ordered(lines)
        for (i, line) in rows.enumerated().reversed() {
            let text = normalize(line.text)
            guard let r = text.range(of: tail, options: [.caseInsensitive, .backwards]) else { continue }
            let n = text.distance(from: text.startIndex, to: r.upperBound)
            return reading(rows: rows, index: i, split: n, method: .landedText)
        }
        return nil
    }

    /// By a caret rect (from the blink diff): the line it overlaps vertically, split at its x.
    public static func locate(lines: [ScreenTextLine], caret: CGRect) -> CaretBandReading? {
        let rows = ordered(lines)
        guard let i = rows.indices.min(by: { abs(rows[$0].box.midY - caret.midY) < abs(rows[$1].box.midY - caret.midY) }),
              abs(rows[i].box.midY - caret.midY) <= max(rows[i].box.height, caret.height) else { return nil }
        let n = CaretBandGeometry.characterIndex(in: rows[i], atX: caret.midX)
        var out = reading(rows: rows, index: i, split: n, method: .blink)
        out.caretRect = caret
        return out
    }

    /// Before = the line above + the line's prefix; after = the line's suffix + the line below
    /// (the 3-line band).
    static func reading(rows: [ScreenTextLine], index i: Int, split n: Int, method: CaretBandReading.Method) -> CaretBandReading {
        let line = rows[i]
        let text = normalize(line.text)
        let cut = text.index(text.startIndex, offsetBy: min(n, text.count))
        var before = String(text[..<cut]), after = String(text[cut...])
        if i > 0 { before = normalize(rows[i - 1].text) + "\n" + before }
        if i + 1 < rows.count { after += "\n" + normalize(rows[i + 1].text) }
        let rect = CaretBandGeometry.caretRect(in: ScreenTextLine(text: text, box: line.box, confidence: line.confidence),
                                               afterCharacters: n)
        return CaretBandReading(before: before, after: after, caretRect: rect, method: method)
    }

    static func normalize(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

// MARK: - Blink diff (pure over pixels)

public enum CaretBlink {
    /// Largest caret, in points: a bar is narrow and about a line tall.
    public static let maxWidthPoints: CGFloat = 4
    public static let minHeightPoints: CGFloat = 6
    public static let maxHeightPoints: CGFloat = 72
    /// Per-channel difference that counts as changed (ignores compression / subpixel noise).
    public static let threshold = 48

    /// The changed region between two frames of the same rect, in global points, when it is
    /// caret-shaped (narrow, about a line tall). `nil` for no change, a size mismatch, or a
    /// change that is not a caret (typing, scrolling, a video).
    public static func caretRect(_ a: CGImage, _ b: CGImage, mapping: ScreenPixelMapping) -> CGRect? {
        guard a.width == b.width, a.height == b.height, a.width > 0, a.height > 0,
              let pa = rgba(a), let pb = rgba(b) else { return nil }
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        let w = a.width
        for y in 0..<a.height {
            for x in 0..<w {
                let o = (y * w + x) * 4
                if abs(Int(pa[o]) - Int(pb[o])) > threshold || abs(Int(pa[o + 1]) - Int(pb[o + 1])) > threshold
                    || abs(Int(pa[o + 2]) - Int(pb[o + 2])) > threshold {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= 0 else { return nil }
        let px = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        let pt = mapping.pointRect(forPixels: px)
        guard pt.width <= maxWidthPoints, pt.height >= minHeightPoints, pt.height <= maxHeightPoints else { return nil }
        return pt
    }

    static func rgba(_ image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? buf : nil
    }
}

// MARK: - The service

extension ScreenTextService {
    /// Q14 / K9 — the caret band around `anchor` (the focused field, else its window; global
    /// points). Throws `permissionDenied` without Screen Recording — it never asks. Callers gate
    /// on `CaretOCRSettings` (the reader does); this method is the capture itself.
    ///
    /// 1. One frame of `anchor`. With `lastLanded`, recognise it and find the line our text ends.
    /// 2. Otherwise a second frame after `blinkInterval`; the diff is the caret; recognise the
    ///    three-line band around it and split its line at the caret's x.
    public func caretBand(around anchor: CGRect, display: CGDirectDisplayID, lastLanded: String?,
                          role: FieldRole = .unknown, blinkInterval: TimeInterval = 0.55) async throws -> CaretBandReading? {
        let first = try await capture(anchor, display: display)
        defer { discardFrame(first.id) }
        if let lastLanded, !lastLanded.isEmpty {
            let lines = try await recognize(first, role: role)
            if let hit = CaretBandLocator.locate(lines: lines, lastLanded: lastLanded) { return hit }
        }
        try await Task.sleep(nanoseconds: UInt64(max(0, blinkInterval) * 1_000_000_000))
        let second = try await capture(anchor, display: display)
        defer { discardFrame(second.id) }
        guard let caret = CaretBlink.caretRect(first.image, second.image, mapping: first.mapping) else { return nil }
        let band = CaretBandGeometry.band(around: caret, lineHeight: caret.height * 1.3, within: first.mapping.pointRect)
        let crop = first.mapping.pixelRect(forPoints: band)
        guard crop.width > 0, let cut = first.image.cropping(to: crop) else { return nil }
        let bandFrame = CapturedRegion(image: cut, mapping: first.mapping.cropped(to: crop), windowID: first.windowID)
        let lines = try await recognize(bandFrame, role: role)
        return CaretBandLocator.locate(lines: lines, caret: caret)
    }
}

// MARK: - K10's OCR rung

/// K10 — the OCR rung of the caret ladder, synchronous because the ladder is. Additive protocol;
/// tests inject a mock.
public protocol OCRCaretReading: AnyObject {
    func caretBand(pid: Int32, bundleID: String, lastLanded: String?) -> CaretBandReading?
}

/// Live rung: the focused element's frame (else its window's) via AX, then
/// `ScreenTextService.caretBand`, waited for at most `deadline` (the landing is waiting). Gated
/// twice on the switch: the reader asks only when it is on, and this checks again before any
/// capture. Untested here: needs Screen Recording, a window server and a canvas editor (T1).
public final class LiveOCRCaret: OCRCaretReading, @unchecked Sendable {
    public let service: ScreenTextService
    public var isEnabled: () -> Bool
    public var deadline: TimeInterval = 1.2
    public var timeout: Float = 0.1

    public init(service: ScreenTextService, isEnabled: @escaping () -> Bool = { CaretOCRSettings.isEnabled() }) {
        self.service = service
        self.isEnabled = isEnabled
    }

    public func caretBand(pid: Int32, bundleID: String, lastLanded: String?) -> CaretBandReading? {
        guard isEnabled(), pid != getpid(), service.access.preflight(), let anchor = anchorRect(pid: pid) else { return nil }
        let service = self.service
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        let task = Task.detached(priority: .userInitiated) {
            box.value = try? await service.caretBand(around: anchor, display: CGMainDisplayID(), lastLanded: lastLanded)
            done.signal()
        }
        if done.wait(timeout: .now() + deadline) == .timedOut { task.cancel(); return nil }
        return box.value
    }

    private final class ResultBox: @unchecked Sendable { var value: CaretBandReading? }

    /// Focused element frame, else focused window frame, in AppKit global points.
    func anchorRect(pid: Int32) -> CGRect? {
        guard let app = AXGuard.application(pid: pid) else { return nil }
        AXUIElementSetMessagingTimeout(app, timeout)
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        for attribute in [kAXFocusedUIElementAttribute, kAXFocusedWindowAttribute] {
            var raw: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, attribute as CFString, &raw) == .success, let raw,
                  CFGetTypeID(raw) == AXUIElementGetTypeID() else { continue }
            let element = raw as! AXUIElement // swiftlint:disable:this force_cast
            AXUIElementSetMessagingTimeout(element, timeout)
            if let ax = frame(of: element), ax.width >= 20, ax.height >= 10 {
                return CGRect(x: ax.minX, y: primaryHeight - ax.maxY, width: ax.width, height: ax.height)
            }
        }
        return nil
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        var pos: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let pos, let size, CFGetTypeID(pos) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(pos as! AXValue, .cgPoint, &p), AXValueGetValue(size as! AXValue, .cgSize, &s) else { return nil } // swiftlint:disable:this force_cast
        return CGRect(origin: p, size: s)
    }
}
