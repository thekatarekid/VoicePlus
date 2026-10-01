import Engine
import Foundation
import Pipeline

/// V5 D1 + K7 — wires the one ITN implementation at launch:
/// - `ITNStage.backend` ← `NemoITN` (FluidAudio's NeMo grammars), the residual pass after the Swift rules;
/// - `ITNStage.defaultLocale` ← LANG (`VOICEPLUS_ITN_LOCALE` overrides, then `LANG`, then the system
///   locale — a Finder-launched app has no `LANG`), so `en_IN` gets lakh/crore, `₹` and day-first dates;
/// - `PreviewFormatter` ← `ITNStage.normalize(text:)`, so the pill shows the digits that will land.
enum ITNWiring {
    static func install(environment: [String: String] = ProcessInfo.processInfo.environment,
                        systemLocale: String = Locale.current.identifier) {
        ITNStage.defaultLocale = locale(environment: environment, systemLocale: systemLocale)
        let nemo = NemoITN.shared
        ITNStage.backend = nemo.isAvailable
            ? ClosureITNBackend(supports: { nemo.supports($0) }, normalize: { nemo.normalizeSentence($0, language: $1) })
            : nil
        PreviewFormatter.install(normalizer: { ITNStage.normalize(text: $0) })
    }

    static func locale(environment: [String: String], systemLocale: String) -> ITNLocale {
        for key in ["VOICEPLUS_ITN_LOCALE", "LANG"] {
            if let raw = environment[key], !raw.isEmpty, raw != "C", raw != "POSIX" {
                return ITNLocale(tag: String(raw.split(separator: ".").first ?? ""))
            }
        }
        return ITNLocale(tag: systemLocale)
    }
}
