import CoreGraphics
import Foundation
import Shared

// S5 — marks in the destination (design §7 "Destination support ladder").
//
// 1. VoicePlus-owned fields draw their own attributed marks.
// 2. A validated app integration gets a transparent, non-activating overlay anchored to accessible
//    word rectangles; it follows scrolling, zoom, wrapping, window moves and display changes by
//    revalidating, never modifies the target's text, is hidden when the app leaves the front and is
//    restored only after revalidation.
// 3. Anything else — or any moment geometry or range validity cannot be verified — gets no overlay:
//    "Word marks aren't available in this app" (D09), and the marks stay in Review / Today.

/// Which rung of the ladder a destination is on.
public enum WordMarkTier: String, Equatable, Sendable {
    /// VoicePlus's own field: native attributed decoration.
    case native
    /// A validated adapter: the overlay, while it validates.
    case overlay
    /// No trustworthy geometry: D09, marks retained in VoicePlus.
    case unavailable
}

/// The ladder: which apps get which rung.
public struct WordMarkLadder: Equatable, Sendable {
    /// The first validation matrix (build doc S5): the apps whose text views expose trustworthy
    /// `kAXBoundsForRangeParameterizedAttribute` word rectangles. Each is still validated per bundle at
    /// runtime before the Apps pane promises marks for it (`RecordedWordMarkCapability`).
    public static let firstMatrix: [String] = ["com.apple.Notes", "com.apple.TextEdit", "com.apple.mail", "com.apple.Safari"]

    public var ownBundleID: String?
    public var adapters: Set<String>

    public init(ownBundleID: String? = Bundle.main.bundleIdentifier, adapters: Set<String> = Set(Self.firstMatrix)) {
        self.ownBundleID = ownBundleID
        self.adapters = adapters
    }

    public func tier(for bundleID: String?, secure: Bool = false) -> WordMarkTier {
        guard let bundleID, !bundleID.isEmpty, !secure else { return .unavailable }
        if let own = ownBundleID, own == bundleID { return .native }
        return adapters.contains(bundleID) ? .overlay : .unavailable
    }
}

/// The destination field, as the overlay reads it. Live: `AXElementMarkGeometry` over the element the
/// text landed in; tests: a scripted field.
public protocol MarkGeometrySource: AnyObject {
    /// The field's whole text now, or nil when it cannot be read.
    func currentValue() -> String?
    /// The on-screen line box (AppKit screen coordinates) of a UTF-16 range that does not cross a line,
    /// or nil when the app gives no trustworthy rectangle.
    func rect(for range: Range<Int>) -> CGRect?
    /// The field's visible frame (its scroll clip) in AppKit screen coordinates, when known.
    func visibleFrame() -> CGRect?
    /// The destination app is frontmost.
    var isFrontmost: Bool { get }
    /// The field still exists (its window was not closed).
    var isAlive: Bool { get }
}

/// Why a session's marks were taken off the destination for good (they stay in Review / Today).
public enum MarkClearReason: String, Equatable, Sendable {
    /// Corrected: the replacement landed in the verified range.
    case corrected
    /// The user kept the word as it was.
    case kept
    /// Undo removed the turn's text.
    case undone
    /// The text no longer reads as landed and cannot be found unambiguously (an edit we cannot verify).
    case textChanged
    /// The field or its window went away.
    case destinationClosed
    /// The field's value cannot be read.
    case unreadable
    /// The app gives no trustworthy word rectangles (D09).
    case noGeometry
    /// A newer landing took the overlay.
    case replaced
}

/// Why marks are off screen for now; revalidation brings them back.
public enum MarkHideReason: String, Equatable, Sendable {
    /// The destination app left the front.
    case appInactive
    /// Every marked word is scrolled out of the field's visible area.
    case scrolledAway
}

/// One underline to draw in the destination: the mark it belongs to and its screen rect (AppKit).
public struct DestinationMarkFragment: Equatable, Sendable {
    public var markID: Int
    /// The word's line box.
    public var box: CGRect
    /// The 2 px underline 3 px below the baseline.
    public var underline: CGRect
}

/// The marks of one landing in one field, and their validation state.
public final class DestinationMarkSession {
    public enum Phase: Equatable, Sendable {
        case shown([DestinationMarkFragment])
        case hidden(MarkHideReason)
        case cleared(MarkClearReason)

        public var isCleared: Bool { if case .cleared = self { return true }; return false }
        public var fragments: [DestinationMarkFragment] { if case .shown(let f) = self { return f }; return [] }
    }

    public let bundleID: String
    public let tier: WordMarkTier
    /// Where the landed text sits in the field (UTF-16), as last verified.
    public private(set) var landed: Range<Int>
    /// The landed text as it should read now (updated by our own corrections).
    public private(set) var landedText: String
    /// The unresolved marks; ranges relative to `landedText`.
    public private(set) var marks: [UncertainMark]
    public private(set) var phase: Phase
    /// The first validation that drew marks (the per-bundle capability record keys on it).
    public private(set) var validatedOnce = false

    public init(bundleID: String, tier: WordMarkTier, landed: Range<Int>, text: String, marks: [UncertainMark]) {
        self.bundleID = bundleID
        self.tier = tier
        self.landed = landed
        self.landedText = text
        self.marks = marks
        phase = marks.isEmpty ? .cleared(.kept) : .hidden(.appInactive)
    }

    /// Absolute field range of a mark.
    public func fieldRange(of mark: UncertainMark) -> Range<Int> {
        (landed.lowerBound + mark.range.lowerBound)..<(landed.lowerBound + mark.range.upperBound)
    }

    /// Re-reads the field and places the marks again. Called on every AX notification, on app
    /// activation, on display changes and on a short tick while shown (scrolling has no notification).
    @discardableResult
    public func revalidate(_ field: MarkGeometrySource) -> Phase {
        guard !phase.isCleared else { return phase }
        guard tier == .overlay else { return clear(.noGeometry) }
        guard field.isAlive else { return clear(.destinationClosed) }
        guard field.isFrontmost else { return set(.hidden(.appInactive)) }
        guard let value = field.currentValue() else { return clear(.unreadable) }
        guard relocate(in: value) else { return clear(.textChanged) }
        var fragments: [DestinationMarkFragment] = []
        let visible = field.visibleFrame()
        for mark in marks {
            let words = MarkWords.words(in: landedText).filter { $0.core.overlaps(mark.range) }
            var boxes: [CGRect] = []
            for word in words {
                let lo = max(word.core.lowerBound, mark.range.lowerBound), hi = min(word.core.upperBound, mark.range.upperBound)
                guard lo < hi else { continue }
                guard let box = field.rect(for: (landed.lowerBound + lo)..<(landed.lowerBound + hi)), Self.plausible(box) else {
                    // Once the app has given trustworthy rectangles, a missing one is a word scrolled
                    // out of view; before that, the app cannot be trusted with marks at all (D09).
                    if validatedOnce { continue }
                    return clear(.noGeometry)
                }
                boxes.append(box)
            }
            for box in Self.lineFragments(boxes) where visible.map({ $0.intersects(box) }) ?? true {
                fragments.append(DestinationMarkFragment(markID: mark.id, box: box, underline: MarkStyle.underline(below: box)))
            }
        }
        guard !fragments.isEmpty else { return set(.hidden(.scrolledAway)) }
        validatedOnce = true
        return set(.shown(fragments))
    }

    /// The landed text still reads where it landed, or — after an edit elsewhere in the field — can be
    /// found exactly once. Anything else is an edit we cannot verify.
    func relocate(in value: String) -> Bool {
        if MarkWords.slice(value, landed) == landedText { return true }
        let haystack = value as NSString
        let first = haystack.range(of: landedText)
        guard first.location != NSNotFound, !landedText.isEmpty else { return false }
        let after = first.location + max(1, first.length)
        let second = haystack.range(of: landedText, options: [], range: NSRange(location: after, length: haystack.length - after))
        guard second.location == NSNotFound else { return false }
        landed = first.location..<(first.location + first.length)
        return true
    }

    /// A word we replaced in the verified range: the mark goes, the text and the later marks shift.
    public func corrected(_ markID: Int, with replacement: String) {
        guard let index = marks.firstIndex(where: { $0.id == markID }) else { return }
        let mark = marks.remove(at: index)
        let delta = replacement.utf16.count - mark.range.count
        var units = Array(landedText.utf16)
        units.replaceSubrange(mark.range, with: Array(replacement.utf16))
        landedText = String(decoding: units, as: UTF16.self)
        landed = landed.lowerBound..<(landed.upperBound + delta)
        marks = marks.map { m in
            guard m.range.lowerBound >= mark.range.upperBound else { return m }
            var shifted = m
            shifted.range = (m.range.lowerBound + delta)..<(m.range.upperBound + delta)
            return shifted
        }
        if marks.isEmpty { phase = .cleared(.corrected) }
    }

    /// The user kept the word: only its mark goes.
    public func kept(_ markID: Int) {
        marks.removeAll { $0.id == markID }
        if marks.isEmpty { phase = .cleared(.kept) }
    }

    @discardableResult
    public func clear(_ reason: MarkClearReason) -> Phase {
        phase = .cleared(reason)
        return phase
    }

    private func set(_ next: Phase) -> Phase {
        phase = next
        return next
    }

    /// A rectangle AX may report for a word: non-empty, a text-like height, not the zero origin some
    /// apps return for off-screen or unsupported ranges.
    public static func plausible(_ box: CGRect) -> Bool {
        box.width > 0.5 && box.height >= 4 && box.height <= 400 && !(box.origin == .zero)
    }

    /// Consecutive word boxes on one line merge into one fragment (the underline runs under the
    /// spaces of a phrase); a wrapped phrase yields one fragment per line.
    public static func lineFragments(_ boxes: [CGRect]) -> [CGRect] {
        var out: [CGRect] = []
        for box in boxes {
            if let last = out.last, abs(last.midY - box.midY) < min(last.height, box.height) / 2, box.minX >= last.minX {
                out[out.count - 1] = last.union(box)
            } else {
                out.append(box)
            }
        }
        return out
    }
}

/// Where the landed text sits in the field right after the insert: just before the caret, verified by
/// reading it back; else its one occurrence in the field. Nil when neither can be verified.
public enum LandedRangeLocator {
    public static func locate(text: String, value: String, caret: Int?) -> Range<Int>? {
        let length = text.utf16.count
        guard length > 0 else { return nil }
        if let caret, caret >= length {
            let range = (caret - length)..<caret
            if MarkWords.slice(value, range) == text { return range }
        }
        let haystack = value as NSString
        let first = haystack.range(of: text)
        guard first.location != NSNotFound else { return nil }
        let after = first.location + first.length
        let second = haystack.range(of: text, options: [], range: NSRange(location: after, length: haystack.length - after))
        guard second.location == NSNotFound else { return nil }
        return first.location..<(first.location + first.length)
    }
}

/// Records per bundle whether the overlay validated (Settings › Apps "Word marks" / "No overlay").
public protocol WordMarkCapabilityRecording: AnyObject {
    func record(_ bundleID: String, supported: Bool)
}

/// Live: `RecordedWordMarkCapability` in `UserDefaults` (`apps.wordMarks.validated`), which the Apps
/// pane reads.
public final class DefaultsWordMarkCapabilityRecorder: WordMarkCapabilityRecording {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func record(_ bundleID: String, supported: Bool) {
        let current = RecordedWordMarkCapability(defaults: defaults).wordMarks(for: bundleID) == .supported
        guard current != supported else { return }
        RecordedWordMarkCapability.record(bundleID, supported: supported, defaults: defaults)
    }
}

/// What a session's validation means for the per-bundle record: a validated overlay records the app
/// as supported; an app of the matrix whose rectangles cannot be trusted records it as not. A
/// transient state (app in the background, text scrolled away, the user's own edit) records nothing.
public enum WordMarkCapabilityPolicy {
    public static func verdict(for phase: DestinationMarkSession.Phase, tier: WordMarkTier) -> Bool? {
        guard tier == .overlay else { return nil }
        switch phase {
        case .shown: return true
        case .cleared(.noGeometry): return false
        default: return nil
        }
    }
}
