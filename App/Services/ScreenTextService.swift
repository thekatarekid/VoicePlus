import Actions
import AppKit
import CoreGraphics
import Foundation
import Pipeline
import ScreenCaptureKit
import Shared
import Vision

// G2 — screen capture + text recognition behind `ScreenTextReader` (V4.53, V4.29).
//
// One permission (Screen Recording, optional), one code path, two consumers: the deixis box now,
// the caret band later (V4.54). The captured frame is held in memory for the turn and never
// written anywhere; recognised text leaves this file only as `ScreenTextLine`s.

// MARK: - Point ↔ pixel mapping

/// Maps between global screen points (AppKit: origin bottom-left of the main display, y up) and the
/// pixels of an image captured of `pointRect` at `scale` pixels per point (CGImage: origin top-left,
/// y down). Pure, so the conversion every OCR box goes through is a unit test.
public struct ScreenPixelMapping: Equatable, Sendable {
    /// What the image shows, in global points.
    public var pointRect: CGRect
    /// Backing scale: pixels per point.
    public var scale: CGFloat

    public init(pointRect: CGRect, scale: CGFloat) {
        self.pointRect = pointRect
        self.scale = max(scale, 0.01)
    }

    public var pixelSize: CGSize {
        CGSize(width: (pointRect.width * scale).rounded(), height: (pointRect.height * scale).rounded())
    }

    /// A global point rect → the image's pixel rect (top-left origin), outward to whole pixels and
    /// clipped to the image.
    public func pixelRect(forPoints rect: CGRect) -> CGRect {
        let local = rect.intersection(pointRect)
        guard !local.isNull, !local.isEmpty else { return .zero }
        let x0 = ((local.minX - pointRect.minX) * scale).rounded(.down)
        let x1 = ((local.maxX - pointRect.minX) * scale).rounded(.up)
        // Flip: the top of the rect (maxY) is the smaller pixel y.
        let y0 = ((pointRect.maxY - local.maxY) * scale).rounded(.down)
        let y1 = ((pointRect.maxY - local.minY) * scale).rounded(.up)
        let size = pixelSize
        let r = CGRect(x: max(0, x0), y: max(0, y0), width: min(size.width, x1) - max(0, x0),
                       height: min(size.height, y1) - max(0, y0))
        return r.width > 0 && r.height > 0 ? r : .zero
    }

    /// An image pixel rect (top-left origin) → global points.
    public func pointRect(forPixels rect: CGRect) -> CGRect {
        CGRect(x: pointRect.minX + rect.minX / scale,
               y: pointRect.maxY - rect.maxY / scale,
               width: rect.width / scale, height: rect.height / scale)
    }

    /// A Vision bounding box (normalised 0…1 over `crop`, origin bottom-left) → global points.
    /// `crop` is the pixel rect (top-left origin) the recogniser was run over.
    public func pointRect(forNormalized box: CGRect, inPixelCrop crop: CGRect) -> CGRect {
        let px = CGRect(x: crop.minX + box.minX * crop.width,
                        y: crop.minY + (1 - box.maxY) * crop.height,
                        width: box.width * crop.width, height: box.height * crop.height)
        return pointRect(forPixels: px)
    }

    /// The mapping of a sub-image cut out at `pixelCrop`.
    public func cropped(to pixelCrop: CGRect) -> ScreenPixelMapping {
        ScreenPixelMapping(pointRect: pointRect(forPixels: pixelCrop), scale: scale)
    }
}

// MARK: - Seams

/// A frame of the screen under a box, held in memory for one turn.
public struct CapturedRegion: @unchecked Sendable {
    public let id: UUID
    /// The pixels of the box (cropped from the window under it), at backing scale.
    public let image: CGImage
    /// How `image` maps back to global points.
    public let mapping: ScreenPixelMapping
    /// The window the pixels came from (`kCGWindowNumber`), nil for a display-region capture.
    public let windowID: CGWindowID?

    public init(id: UUID = UUID(), image: CGImage, mapping: ScreenPixelMapping, windowID: CGWindowID?) {
        self.id = id; self.image = image; self.mapping = mapping; self.windowID = windowID
    }
}

public enum ScreenTextError: Error, Equatable {
    /// Screen Recording is not granted: no screenshot, no OCR.
    case permissionDenied
    /// Nothing capturable under the rect (no window, off every display).
    case nothingUnderRect
    case captureFailed(String)
    case recognitionFailed(String)
}

/// The Screen Recording TCC check. Live: `CGPreflightScreenCaptureAccess` /
/// `CGRequestScreenCaptureAccess`.
public protocol ScreenRecordingAccess: AnyObject {
    func preflight() -> Bool
    /// Shows the system alert the first time only; returns the current state immediately.
    @discardableResult func request() -> Bool
}

public final class SystemScreenRecordingAccess: ScreenRecordingAccess {
    public init() {}
    public func preflight() -> Bool { CGPreflightScreenCaptureAccess() }
    @discardableResult public func request() -> Bool { CGRequestScreenCaptureAccess() }
}

/// The ScreenCaptureKit seam: the window under `rect`, cropped to it.
public protocol ScreenFrameCapturing: AnyObject {
    func capture(_ rect: CGRect, display: CGDirectDisplayID) async throws -> CapturedRegion
}

/// One recognised line before conversion: Vision's normalised box over the image it was given.
public struct RecognizedLine: Equatable, Sendable {
    public var text: String
    /// Normalised 0…1 over the recognised image, origin bottom-left (Vision's convention).
    public var normalizedBox: CGRect
    public var confidence: Float
    public init(text: String, normalizedBox: CGRect, confidence: Float) {
        self.text = text; self.normalizedBox = normalizedBox; self.confidence = confidence
    }
}

/// How to run the recogniser for one request.
public struct TextRecognitionOptions: Equatable, Sendable {
    /// Always `.accurate` for the box; kept as a flag for the caret band's cheaper pass later.
    public var accurate: Bool
    public var usesLanguageCorrection: Bool
    public var customWords: [String]
    public var languages: [String]

    public init(accurate: Bool = true, usesLanguageCorrection: Bool = true, customWords: [String] = [],
                languages: [String] = ["en-US"]) {
        self.accurate = accurate; self.usesLanguageCorrection = usesLanguageCorrection
        self.customWords = customWords; self.languages = languages
    }

    /// Most custom words handed to the recogniser (a learned lexicon can be large).
    public static let customWordLimit = 256

    /// The rule table (V4.55):
    /// * language correction off where words are not prose — terminals, code, secure fields;
    /// * custom words from the learned lexicon, de-duplicated, capped;
    /// * languages: English first, then the configured ones the recogniser supports.
    public static func policy(role: FieldRole, customWords: [String], configuredLanguages: [String],
                              supportedLanguages: [String]) -> TextRecognitionOptions {
        let correction: Bool
        switch role {
        case .terminal, .codeEditor, .secure: correction = false
        case .singleLineText, .multilineText, .unknown: correction = true
        }
        var seen = Set<String>()
        let words = customWords.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        var langs = ["en-US"]
        for raw in configuredLanguages {
            let tag = raw.replacingOccurrences(of: "_", with: "-").lowercased()
            let base = tag.split(separator: "-").first.map(String.init) ?? tag
            let match = supportedLanguages.first { $0.lowercased() == tag }
                ?? supportedLanguages.first { $0.lowercased() == base || $0.lowercased().hasPrefix(base + "-") }
            guard let lang = match, !langs.contains(where: { $0.lowercased() == lang.lowercased() }) else { continue }
            langs.append(lang)
        }
        return TextRecognitionOptions(accurate: true, usesLanguageCorrection: correction,
                                      customWords: Array(words.prefix(customWordLimit)), languages: langs)
    }
}

/// The Vision seam.
public protocol TextRecognizing: AnyObject {
    func recognize(_ image: CGImage, options: TextRecognitionOptions) throws -> [RecognizedLine]
    var supportedLanguages: [String] { get }
}

// MARK: - The service

/// G2 — `ScreenTextReader` over ScreenCaptureKit + Vision, plus the per-turn frame store the
/// deixis chip reads its crop from.
public final class ScreenTextService: ScreenTextReader, @unchecked Sendable {
    public let access: ScreenRecordingAccess
    private let capturer: ScreenFrameCapturing
    private let recognizer: TextRecognizing
    /// Learned-lexicon words for `customWords` (V4.55).
    public var customWords: () -> [String]
    /// Configured recognition languages besides English.
    public var configuredLanguages: () -> [String]
    private var frames: [UUID: CapturedRegion] = [:]
    private let lock = NSLock()

    public init(access: ScreenRecordingAccess = SystemScreenRecordingAccess(),
                capturer: ScreenFrameCapturing = WindowScreenCapturer(),
                recognizer: TextRecognizing = VisionTextRecognizer(),
                customWords: @escaping () -> [String] = { [] },
                configuredLanguages: @escaping () -> [String] = { Locale.preferredLanguages }) {
        self.access = access
        self.capturer = capturer
        self.recognizer = recognizer
        self.customWords = customWords
        self.configuredLanguages = configuredLanguages
    }

    /// `ScreenTextReader`: capture the window under `rect` and recognise its text, for a field of
    /// unknown role. The frame is kept for the turn like any other capture.
    public func lines(in rect: CGRect, display: CGDirectDisplayID) async throws -> [ScreenTextLine] {
        let frame = try await capture(rect, display: display)
        return try await recognize(frame, role: .unknown)
    }

    /// Screenshot of the box (the window under it, at backing scale), held until `discardFrames`.
    public func capture(_ rect: CGRect, display: CGDirectDisplayID) async throws -> CapturedRegion {
        guard access.preflight() else { throw ScreenTextError.permissionDenied }
        let frame = try await capturer.capture(rect, display: display)
        lock.lock(); frames[frame.id] = frame; lock.unlock()
        return frame
    }

    /// Recognise the text of a captured frame; boxes come back in global points.
    public func recognize(_ frame: CapturedRegion, role: FieldRole) async throws -> [ScreenTextLine] {
        let options = TextRecognitionOptions.policy(role: role, customWords: customWords(),
                                                    configuredLanguages: configuredLanguages(),
                                                    supportedLanguages: recognizer.supportedLanguages)
        let recognizer = self.recognizer
        let raw = try await Task.detached(priority: .userInitiated) {
            try recognizer.recognize(frame.image, options: options)
        }.value
        return Self.lines(from: raw, frame: frame)
    }

    /// Recogniser output → `ScreenTextLine`s in global points, top-to-bottom then left-to-right.
    public static func lines(from raw: [RecognizedLine], frame: CapturedRegion) -> [ScreenTextLine] {
        let crop = CGRect(x: 0, y: 0, width: frame.image.width, height: frame.image.height)
        let mapping = frame.mapping
        return raw
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { ScreenTextLine(text: $0.text, box: mapping.pointRect(forNormalized: $0.normalizedBox, inPixelCrop: crop),
                                  confidence: $0.confidence) }
            .sorted { a, b in
                abs(a.box.midY - b.box.midY) > min(a.box.height, b.box.height) / 2 ? a.box.midY > b.box.midY : a.box.minX < b.box.minX
            }
    }

    /// The crop for a region's chip, while its turn lasts.
    public func image(for id: UUID) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        return frames[id]?.image
    }

    public var heldFrameCount: Int { lock.lock(); defer { lock.unlock() }; return frames.count }

    /// Turn over: drop every frame. Nothing was ever written.
    public func discardFrames() {
        lock.lock(); frames.removeAll(); lock.unlock()
    }
}

// MARK: - Live ScreenCaptureKit capture

/// Captures the frontmost ordinary window under the box's centre (not ours) with a
/// desktop-independent-window filter — so the overlay's orange box and anything floating above
/// the window are not in the shot — at the filter's backing scale, then crops to the box.
/// Falls back to the display region when no window is under the box. Untested here: needs a
/// window server and the Screen Recording grant (§5 item 6).
public final class WindowScreenCapturer: ScreenFrameCapturing {
    private let normalizer: () -> DisplayNormalizer

    public init(normalizer: @escaping () -> DisplayNormalizer = { DisplayNormalizer.current() }) {
        self.normalizer = normalizer
    }

    public func capture(_ rect: CGRect, display: CGDirectDisplayID) async throws -> CapturedRegion {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            throw ScreenTextError.captureFailed("\(error)")
        }
        let n = normalizer()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let centre = n.quartzPoint(fromCocoa: CGPoint(x: rect.midX, y: rect.midY))
        if let windowID = Self.frontWindowID(at: centre, excludingPID: ownPID),
           let window = content.windows.first(where: { $0.windowID == windowID }) {
            let filter = SCContentFilter(desktopIndependentWindow: window)
            // SCWindow.frame is Quartz global (top-left origin); the mapping wants AppKit points.
            let windowPoints = Self.cocoa(quartzRect: window.frame, n)
            return try await Self.shoot(filter: filter, covering: windowPoints, box: rect, windowID: windowID)
        }
        guard let scDisplay = content.displays.first(where: { $0.displayID == display }) else {
            throw ScreenTextError.nothingUnderRect
        }
        let filter = SCContentFilter(display: scDisplay, excludingApplications:
                                        content.applications.filter { $0.processID == ownPID }, exceptingWindows: [])
        let displayPoints = Self.cocoa(quartzRect: scDisplay.frame, n)
        return try await Self.shoot(filter: filter, covering: displayPoints, box: rect, windowID: nil)
    }

    private static func shoot(filter: SCContentFilter, covering pointRect: CGRect, box: CGRect,
                              windowID: CGWindowID?) async throws -> CapturedRegion {
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        let mapping = ScreenPixelMapping(pointRect: pointRect, scale: scale)
        config.width = Int(mapping.pixelSize.width)
        config.height = Int(mapping.pixelSize.height)
        config.showsCursor = false
        config.scalesToFit = false
        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            throw ScreenTextError.captureFailed("\(error)")
        }
        let full = ScreenPixelMapping(pointRect: pointRect, scale: CGFloat(image.width) / max(pointRect.width, 0.01))
        let crop = full.pixelRect(forPoints: box)
        guard crop.width > 0, crop.height > 0, let cut = image.cropping(to: crop) else {
            throw ScreenTextError.nothingUnderRect
        }
        return CapturedRegion(image: cut, mapping: full.cropped(to: crop), windowID: windowID)
    }

    /// A Quartz global rect (top-left origin, as `SCWindow.frame` / `SCDisplay.frame` report) in
    /// AppKit global points.
    static func cocoa(quartzRect r: CGRect, _ n: DisplayNormalizer) -> CGRect {
        let bottomLeft = n.cocoaPoint(fromQuartz: CGPoint(x: r.minX, y: r.maxY))
        return CGRect(origin: bottomLeft, size: r.size)
    }

    /// Frontmost on-screen, layer-0 window containing the Quartz point, not owned by `pid`.
    /// `CGWindowListCopyWindowInfo` lists front to back and needs no permission for bounds.
    static func frontWindowID(at quartz: CGPoint, excludingPID pid: pid_t) -> CGWindowID? {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for w in info {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) != pid,
                  let boundsDict = w[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.contains(quartz),
                  let number = w[kCGWindowNumber as String] as? Int else { continue }
            return CGWindowID(number)
        }
        return nil
    }
}

// MARK: - Live Vision recognition

/// `VNRecognizeTextRequest`, `.accurate`. Runs on the Neural Engine; nothing leaves the Mac.
public final class VisionTextRecognizer: TextRecognizing {
    public init() {}

    public var supportedLanguages: [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        return (try? request.supportedRecognitionLanguages()) ?? ["en-US"]
    }

    public func recognize(_ image: CGImage, options: TextRecognitionOptions) throws -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = options.accurate ? .accurate : .fast
        request.usesLanguageCorrection = options.usesLanguageCorrection
        request.customWords = options.customWords
        request.recognitionLanguages = options.languages
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { throw ScreenTextError.recognitionFailed("\(error)") }
        return (request.results ?? []).compactMap { observation in
            guard let best = observation.topCandidates(1).first else { return nil }
            return RecognizedLine(text: best.string, normalizedBox: observation.boundingBox, confidence: best.confidence)
        }
    }
}
