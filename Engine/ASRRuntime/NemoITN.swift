import Foundation
import FluidAudio
#if canImport(CNemoTextProcessing)
import CNemoTextProcessing
#endif

/// V5 D1 — NeMo inverse text normalisation (`FluidAudio.TextNormalizer`, Apache-2.0, backed by the
/// bundled `text-processing-rs` FST grammars; no model download, nothing loaded at runtime).
///
/// `Pipeline.ITNStage` cannot import FluidAudio, so `App` (`ITNWiring`) hands these two functions to
/// it as an `ITNBackend`. English goes through `TextNormalizer.normalizeSentence`, which masks the
/// ambiguous words ("period", "dash") NLTagger reads as ordinary language; other languages call the
/// native `nemo_normalize_sentence_lang` directly, because the Swift wrapper has no language parameter.
public final class NemoITN: @unchecked Sendable {
    public static let shared = NemoITN()

    /// Languages the linked grammar set claims (`nemo_text_processing.h`).
    public static let nativeLanguages: Set<String> = ["en", "fr", "es", "de", "zh", "hi", "ja"]

    private let normalizer = TextNormalizer.shared

    public init() {}

    /// The native library is linked (it is, unless FluidAudio's `NemoTextProcessing` trait is off).
    public var isAvailable: Bool { normalizer.isNativeAvailable }

    /// Non-English grammars are reachable only when the C module is visible to this target.
    public var hasLanguageEntryPoint: Bool {
        #if canImport(CNemoTextProcessing)
        return isAvailable
        #else
        return false
        #endif
    }

    public var version: String? { normalizer.version }

    public func supports(_ language: String) -> Bool {
        guard isAvailable else { return false }
        if language == "en" { return true }
        return hasLanguageEntryPoint && Self.nativeLanguages.contains(language)
    }

    /// Spoken → written for a whole clause, or `nil` when the language is not available (the caller
    /// keeps its Swift-rule output).
    public func normalizeSentence(_ text: String, language: String) -> String? {
        guard supports(language) else { return nil }
        if language == "en" { return normalizer.normalizeSentence(text) }
        #if canImport(CNemoTextProcessing)
        guard let ptr = nemo_normalize_sentence_lang(text, language) else { return nil }
        defer { nemo_free_string(ptr) }
        return String(cString: ptr)
        #else
        return nil
        #endif
    }
}
