import FluidAudio
import Foundation
import Shared

/// The ids of the verified design's recovery catalogue (design_v1 §10): 59 entries, `P01` … `X08`.
///
/// Declared here, in the lowest module that classifies errors, so `EngineMessage` can name an entry.
/// The entries themselves — family, trigger, headline, consequence, action, data policy and Spool
/// treatment — are `RecoveryCatalog` in the app (`App/Core/RecoveryCatalog.swift`, S9).
public enum RecoveryID: String, CaseIterable, Codable, Hashable, Sendable {
    case P01, P02, P03, P04
    case K01, K02, K03, K04, K05
    case A01, A02, A03, A04, A05, A06, A07, A08, A09
    case M01, M02, M03, M04, M05, M06, M07, M08
    case T01, T02, T03, T04, T05
    case D01, D02, D03, D04, D05, D06, D07, D08, D09, D10, D11
    case S01, S02, S03, S04, S05
    case N01, N02, N03, N04
    case X01, X02, X03, X04, X05, X06, X07, X08
}

/// Turns a thrown `Error` into the sentence a human should read — the recovery catalogue's headline.
///
/// History, because it explains the shape. `RealEngine` used to publish `setState(.error("\(error)"))`,
/// and interpolating a Swift enum prints the *case name*: the 1.6.6 pill read "invalidAudioData". The
/// 1.7.9 pill read `The file “weight.bin.partial” doesn’t exist.` — an error's own `errorDescription`
/// is not safe to show either, because authors write it for themselves (paths, OSStatus codes, model
/// ids). Since S9 the rule is the design's (§10): a headline is always catalogue copy, the error's own
/// text is a *technical detail* that goes to `Log` (and a diagnostics disclosure) only, and anything
/// unrecognised is `X08` "VoicePlus couldn’t finish this step" — never a raw token.
///
/// `classify` knows the engine layer's errors. The app's `RecoveryCatalog.entry(for:)` adds the
/// errors of the layers above (providers, sync, injection, session refusals) and falls back to this.
public enum EngineMessage {
    /// The catalogue headline for `error`. The raw description is logged, never returned.
    public static func describe(_ error: Error, log: Log = .engine) -> String {
        let id = recoveryID(for: error)
        log.error("recovery \(id.rawValue): \(technicalDetail(error))")
        return headline(for: id)
    }

    /// The catalogue entry an engine-layer error maps to; `X08` for anything unrecognised.
    public static func recoveryID(for error: Error) -> RecoveryID {
        classify(error) ?? .X08
    }

    /// The catalogue entry for an error this layer recognises, or nil so a caller that knows more
    /// types (the app's `RecoveryCatalog`) can try its own before settling on `X08`.
    public static func classify(_ error: Error) -> RecoveryID? {
        if #available(macOS 15, *), let qwen = error as? Qwen3AsrError { return recoveryID(qwen) }
        switch error {
        case let engine as EngineError: return engine.recoveryID
        case let capture as AudioCaptureError: return recoveryID(capture)
        case let model as ModelManagerError: return recoveryID(model)
        case let download as DownloadError: return recoveryID(download)
        case let asr as ASRError: return recoveryID(asr)
        case let refinement as RefinementError: return recoveryID(refinement)
        case is SpeakerError: return .X03
        case is BiasVocabulary.LoadError: return .X04
        case is UnavailableIndicBackend.NotInstalled: return .M01
        // The engine's only network traffic is model downloads (HFDownloader, FluidAudio's hub).
        case is URLError: return .M04
        default: break
        }
        let ns = error as NSError
        if isIncompleteModelDownload(ns) { return .M02 }
        if isOutOfSpace(ns) { return .M05 }
        return nil
    }

    /// The headline for an id `classify` can return. Every such id has one (asserted against the
    /// copy fixture by `RecoveryIDTests`, and against `RecoveryCatalog` by the app's tests), so the
    /// `X08` fallback is unreachable from `describe`.
    public static func headline(for id: RecoveryID) -> String {
        engineHeadline(for: id) ?? engineHeadline(for: .X08)!
    }

    /// The engine slice of the catalogue: verbatim headlines (`Fixtures/design/design_copy.json` ›
    /// `errors`) for exactly the ids an engine-layer error can map to. The app's `RecoveryCatalog`
    /// holds all 59 entries; tests keep the two identical.
    public static func engineHeadline(for id: RecoveryID) -> String? {
        switch id {
        case .K04: return "Finishing your previous dictation"
        case .A01: return "No microphone found"
        case .A03: return "Couldn’t start this microphone"
        case .A04: return "This microphone needs reconnecting"
        case .A05: return "No audio is reaching VoicePlus"
        case .A07: return "That was too short to transcribe"
        case .A09: return "Microphone is in use"
        case .M01: return "Install a speech model"
        case .M02: return "The speech model didn’t finish downloading"
        case .M03: return "The model download couldn’t be verified"
        case .M04: return "Model download paused"
        case .M05: return "Not enough space to finish setup"
        case .M06: return "This model can’t run on this Mac"
        case .M07: return "The speech model isn’t ready"
        case .M08: return "The speech model became unavailable"
        case .T01: return "Couldn’t finish this dictation"
        case .T03: return "Cleanup is unavailable"
        case .X03: return "Couldn’t finish voice setup"
        case .X04: return "Couldn’t import these words"
        case .X08: return "VoicePlus couldn’t finish this step"
        default: return nil
        }
    }

    // MARK: - Technical detail (Log and diagnostics only)

    /// What the error says about itself, for `Log` and a diagnostics disclosure — never a headline.
    ///
    /// Order: 1. `LocalizedError.errorDescription`; 2. `EngineError`'s own wording (a plain Swift
    /// enum bridges to the contentless "The operation couldn't be completed."); 3. a Cocoa-family
    /// error's `localizedDescription` (URLError, POSIX, Core Audio); 4. `String(describing:)`.
    public static func technicalDetail(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let text = localized.errorDescription, !text.isEmpty {
            return text
        }
        if let engine = error as? EngineError { return engine.technicalDetail }
        let ns = error as NSError
        // A Swift error with no NSError bridging of its own gets a synthesised domain equal to its
        // fully qualified type name; anything else came from Cocoa and its description is real.
        if ns.domain != String(reflecting: type(of: error)), !ns.localizedDescription.isEmpty {
            return ns.localizedDescription
        }
        return String(describing: error)
    }

    // MARK: - Classification of engine-layer errors

    private static func recoveryID(_ error: AudioCaptureError) -> RecoveryID {
        switch error {
        case .noInputDevice: return .A01
        case .formatMismatch: return .A04
        case .noAudio: return .A05
        case .busy: return .A09
        // `.engineStartFailed`, `.deviceSelectionFailed`, and any later way of failing to open it.
        default: return .A03
        }
    }

    private static func recoveryID(_ error: ModelManagerError) -> RecoveryID {
        switch error {
        case .unsupported: return .M06
        // Design evidence for M08 is `ModelManager.notPresent`: the model was expected and is gone.
        case .notPresent: return .M08
        case .verificationFailed: return .M03
        // `.incomplete` (an interrupted download left scratch files), and any later "not usable yet".
        default: return .M02
        }
    }

    private static func recoveryID(_ error: DownloadError) -> RecoveryID {
        switch error {
        case .checksumMismatch, .sizeMismatch: return .M03
        case .incompleteDownload: return .M02
        // `.httpStatus`, `.cancelled`, `.noRemoteFiles`: the download stopped; resume or retry it.
        default: return .M04
        }
    }

    private static func recoveryID(_ error: ASRError) -> RecoveryID {
        switch error {
        // The 1.6.6 report: FluidAudio's floor is 300 ms of 16 kHz audio.
        case .invalidAudioData: return .A07
        case .unsupportedPlatform: return .M06
        case .notInitialized, .modelLoadFailed, .modelCompilationFailed, .encoderInstantiationFailed: return .M07
        // `.processingFailed`, `.streamingConversionFailed`, `.fileAccessFailed`: the decoder threw.
        default: return .T01
        }
    }

    private static func recoveryID(_ error: RefinementError) -> RecoveryID {
        switch error {
        case .unavailableOnThisSystem: return .M06
        case .emptyAudio: return .A07
        // Missing or incomplete weights, a blown deadline, a backend throw: the first-pass text stands.
        default: return .T03
        }
    }

    /// The Qwen3-ASR refinement backend (second pass). Unless the hardware rules it out, a failure
    /// here only means the first-pass text stands (V3 §5.3).
    @available(macOS 15, *)
    private static func recoveryID(_ error: Qwen3AsrError) -> RecoveryID {
        switch error {
        case .unsupportedHardware: return .M06
        default: return .T03
        }
    }

    /// Scratch-file suffixes used by the two downloaders: FluidAudio's `FileDownloader`
    /// (`.partial`, plus its `.etag` resume sidecar) and our own `HFDownloader` (`.part`).
    static let downloadScratchExtensions = ["partial", "part", "etag"]

    /// A Cocoa file error naming download scratch ("The file “weight.bin.partial” doesn’t exist.", the
    /// 1.7.9 report) is a half-downloaded model. `ModelManager` converts these at the source; this
    /// catches any that reach the surface from a layer that does not know what a model is.
    static func isIncompleteModelDownload(_ ns: NSError) -> Bool {
        guard ns.domain == NSCocoaErrorDomain else { return false }
        let path = (ns.userInfo[NSFilePathErrorKey] as? String)
            ?? (ns.userInfo[NSURLErrorKey] as? URL)?.path
            ?? ns.localizedDescription
        let suffix = URL(fileURLWithPath: path).pathExtension
        return downloadScratchExtensions.contains(suffix)
            || downloadScratchExtensions.contains(where: { path.contains(".\($0)") })
    }

    /// Disk full or a read-only volume (design M05: "Disk is full or files cannot be written").
    static func isOutOfSpace(_ ns: NSError) -> Bool {
        switch ns.domain {
        case NSCocoaErrorDomain:
            if ns.code == NSFileWriteOutOfSpaceError || ns.code == NSFileWriteVolumeReadOnlyError { return true }
        case NSPOSIXErrorDomain:
            if ns.code == Int(ENOSPC) || ns.code == Int(EROFS) || ns.code == Int(EDQUOT) { return true }
        default:
            break
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError { return isOutOfSpace(underlying) }
        return false
    }
}

public extension EngineError {
    /// The catalogue entry this case maps to.
    var recoveryID: RecoveryID {
        switch self {
        // A start while a session is already open (design K04: "Start while processing").
        case .alreadyListening: return .K04
        // No usable recognizer resolved (design M01: "No usable recognizer installed").
        case .modelUnavailable: return .M01
        // A stop with nothing recording, or a missing test fixture: nothing the user can act on.
        case .notListening, .fixtureNotFound, .fixtureInvalid: return .X08
        }
    }

    /// The headline to show for this case — catalogue copy, routed like every other error.
    var readable: String { EngineMessage.headline(for: recoveryID) }

    /// The case in words, for `Log` and diagnostics. May name a model id or fixture; never a headline.
    var technicalDetail: String {
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
