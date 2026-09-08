import Foundation
import Shared

/// Turns a thrown `Error` into the sentence a human should read.
///
/// This exists because of a one-word bug with a large blast radius. `RealEngine` used to publish
/// `setState(.error("\(error)"))`, and string interpolation on a Swift enum prints the *case name*,
/// never `errorDescription`. FluidAudio's `ASRError.invalidAudioData` carries the perfectly good
/// sentence "Invalid audio data provided. Must be at least 300ms of 16kHz audio." — what reached the
/// user's screen was the bare token `invalidAudioData` next to a red microphone (1.6.6 report).
///
/// Order matters and is deliberate:
/// 1. `LocalizedError.errorDescription` — the author's own sentence, when there is one.
/// 2. `EngineError` — a plain Swift enum, so bridging it to `NSError` yields the useless
///    "The operation couldn't be completed. (Shared.EngineError error 2.)". Its own mapping wins.
/// 3. A Cocoa-family error (URLError, POSIX, Core Audio) — its `localizedDescription` is real.
/// 4. `String(describing:)` — the case name, which is still more informative than the generic
///    "The operation couldn't be completed. (X error 0.)" a bare Swift enum bridges to.
public enum EngineMessage {
    public static func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let text = localized.errorDescription, !text.isEmpty {
            return text
        }
        if let engine = error as? EngineError { return engine.readable }
        let ns = error as NSError
        // Last line of defence for the 1.7.9 report. A file error naming a download scratch file
        // ("The file \u{201C}weight.bin.partial\u{201D} doesn\u{2019}t exist.") is a half-downloaded
        // model, but it reads as a bug in something the user has never heard of and suggests nothing
        // they can do. `ModelManager` now converts these at the source; this catches any that reach
        // the notch from a layer that does not know what a model is.
        if let readable = Self.incompleteModelDownload(ns) { return readable }
        // A Swift error with no NSError bridging of its own gets a synthesised domain equal to its
        // fully qualified type name; anything else (NSURLErrorDomain, NSCocoaErrorDomain, an OSStatus
        // domain) came from Cocoa and its `localizedDescription` is worth showing. Comparing the two
        // is exact and locale-independent — matching on "couldn't be completed" would not be.
        if ns.domain != String(reflecting: type(of: error)), !ns.localizedDescription.isEmpty {
            return ns.localizedDescription
        }
        return String(describing: error)
    }

    /// Scratch-file suffixes used by the two downloaders: FluidAudio's `FileDownloader`
    /// (`.partial`, plus its `.etag` resume sidecar) and our own `HFDownloader` (`.part`).
    static let downloadScratchExtensions = ["partial", "part", "etag"]

    /// A Cocoa file error whose path is download scratch → the sentence a human should read.
    static func incompleteModelDownload(_ ns: NSError) -> String? {
        guard ns.domain == NSCocoaErrorDomain else { return nil }
        let path = (ns.userInfo[NSFilePathErrorKey] as? String)
            ?? (ns.userInfo[NSURLErrorKey] as? URL)?.path
            ?? ns.localizedDescription
        let suffix = URL(fileURLWithPath: path).pathExtension
        guard downloadScratchExtensions.contains(suffix)
            || downloadScratchExtensions.contains(where: { path.contains(".\($0)") }) else { return nil }
        return "The speech model didn\u{2019}t finish downloading, so it can\u{2019}t be used yet. "
            + "Download it again from Settings \u{203A} Models."
    }
}

public extension EngineError {
    /// Plain-language form of each case. `EngineError` lives in `Shared`, which this module may not
    /// edit, so the copy lives here rather than as a retroactive `LocalizedError` conformance.
    var readable: String {
        switch self {
        case .notListening:
            return "VoicePlus wasn't recording when it was asked to stop."
        case .alreadyListening:
            return "VoicePlus is already recording."
        case .modelUnavailable(let which):
            return "No speech model is ready yet (\(which))."
        case .fixtureNotFound(let name):
            return "The test fixture “\(name)” is missing."
        case .fixtureInvalid(let name):
            return "The test fixture “\(name)” could not be read."
        }
    }
}
