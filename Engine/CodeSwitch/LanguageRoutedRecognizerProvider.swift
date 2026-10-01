import Foundation
import Shared

// V5 G1/G2 — which ASR a dictation turn uses, from the LANG1 languages. Routing, not guessing: the
// user said which languages they speak, so the final recognizer follows that answer and nothing
// else (the P6.3 preview-driven `CodeSwitchRouter` is not consulted here).
//
//   Hindi chosen                         → Hinglish (G1), else Nemotron with the `hi` prompt, else Parakeet
//   a language Parakeet v3 lacks chosen  → Nemotron (G2), else Parakeet
//   otherwise                            → Parakeet (inner provider, unchanged)
//
// A route whose model is not installed falls through to the next, so choosing Hindi can never make
// dictation stop working while the model downloads.

public enum ASRRouteKind: String, CaseIterable, Sendable, Equatable {
    case parakeet, hinglish, multilingual
}

public struct ASRRoutePlan: Equatable, Sendable {
    /// Routes to try, best first. Parakeet (the inner provider) is always the last resort.
    public var preferred: [ASRRouteKind]
    /// Nemotron prompt language (`NemotronMultilingualFiles.promptLanguage`); nil = automatic.
    public var nemotronLanguage: String?

    public init(preferred: [ASRRouteKind], nemotronLanguage: String? = nil) {
        self.preferred = preferred.filter { $0 != .parakeet }
        self.nemotronLanguage = nemotronLanguage
    }

    public static let parakeetOnly = ASRRoutePlan(preferred: [])

    /// Stable across processes (`RecognizerProvider.revision` must not use `hashValue`).
    var signature: Int {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in (preferred.map(\.rawValue).joined(separator: ",") + "|" + (nemotronLanguage ?? "auto")).utf8 {
            h = (h ^ UInt64(b)) &* 0x100_0000_01b3
        }
        return Int(truncatingIfNeeded: h & 0x7fff_ffff)
    }
}

public final class LanguageRoutedRecognizerProvider: RecognizerProvider, @unchecked Sendable {
    public typealias HinglishFactory = @Sendable () async -> FinalRecognizer?
    /// Nemotron final + preview for a prompt language, or nil when not installed.
    public typealias MultilingualFactory = @Sendable (_ language: String?) async -> (final: FinalRecognizer, preview: PreviewRecognizer?)?

    private let inner: RecognizerProvider
    private let plan: @Sendable () -> ASRRoutePlan
    private let hinglish: HinglishFactory
    private let multilingual: MultilingualFactory
    private let lock = NSLock()
    private var _lastRoute: ASRRouteKind = .parakeet

    public init(inner: RecognizerProvider, plan: @escaping @Sendable () -> ASRRoutePlan,
                hinglish: @escaping HinglishFactory, multilingual: @escaping MultilingualFactory) {
        self.inner = inner; self.plan = plan; self.hinglish = hinglish; self.multilingual = multilingual
    }

    /// The route the last `resolve()` took (diagnostics, Settings, tests).
    public var lastRoute: ASRRouteKind { lock.withLock { _lastRoute } }

    public func resolve() async throws -> (final: FinalRecognizer, preview: PreviewRecognizer?) {
        let p = plan()
        for route in p.preferred {
            switch route {
            case .hinglish:
                guard let final = await hinglish() else { continue }
                // Preview: Nemotron's streaming pass in Hindi when it is installed (it reads Hindi);
                // otherwise the usual Parakeet preview — the final pass replaces it either way.
                var preview = await multilingual(p.nemotronLanguage ?? "hi")?.preview
                if preview == nil { preview = try? await inner.resolve().preview }
                record(.hinglish)
                return (final, preview)
            case .multilingual:
                guard let pair = await multilingual(p.nemotronLanguage) else { continue }
                record(.multilingual)
                return (pair.final, pair.preview)
            case .parakeet:
                continue
            }
        }
        record(.parakeet)
        return try await inner.resolve()
    }

    /// Changes when the models on disk change (inner) or the user's languages change (plan), so
    /// `RealEngine` re-resolves at the next utterance in either case.
    public func revision() async -> Int {
        let base = await inner.revision()
        let p = plan()
        return p.preferred.isEmpty ? base : base ^ (p.signature << 1)
    }

    private func record(_ r: ASRRouteKind) {
        lock.withLock { _lastRoute = r }
        Log.engine.info("asr route: \(r.rawValue)")
    }
}
