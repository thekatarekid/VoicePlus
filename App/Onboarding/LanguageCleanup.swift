import Foundation
import Pipeline
import Providers
import Shared

// V5 LANG1 — the cleanup model follows the languages. An English-only turn keeps D2's English
// cleanup specialist (SpeakoFlow, its own prompt); a turn in any other chosen language (Hindi /
// Hinglish included) goes to CU8's shared multilingual instruct model (Qwen3.5) with the generic
// delimited prompt plus one line naming the languages, so it never "corrects" romanised Hindi into
// English. Everything still goes through `RoutingTable` (§10) and the shared model is loaded only
// through `ModelResidency` (CU8's provider does that).
//
// With LANG1 unanswered, or the shared GGUF not on this Mac, or a provider pinned for `cleanup`,
// nothing changes: the English path runs exactly as before.

/// Which cleanup model a turn uses.
public enum CleanupModelChoice: String, Sendable, Equatable {
    /// D2's English cleanup specialist.
    case english
    /// CU8's shared multilingual model.
    case multilingual
}

public extension LanguagePreferences {
    /// The cleanup model for a turn whose language is known (per-app memory) or not (nil).
    func cleanupModel(turnLanguage: String? = nil) -> CleanupModelChoice {
        if let turnLanguage { return Self.base(turnLanguage) == "en" ? .english : .multilingual }
        return isEnglishOnly ? .english : .multilingual
    }
}

/// `StageContext.extra` keys the LANG augmenter writes for the turn.
public enum LanguageTurnKeys {
    /// `CleanupModelChoice` raw value.
    public static let cleanupModel = "lang.cleanupModel"
    /// The turn's languages, comma-separated (the chosen ones, narrowed by per-app memory).
    public static let languages = "lang.languages"
    /// The app's remembered language for this turn, when there is one.
    public static let appLanguage = "lang.appLanguage"
}

/// CU8's shared model as the `cleanup` stage's multilingual route. It has no `.pipeline`
/// capability, so it is never in an Auto or local chain: only the cleanup generator reaches it, by
/// pinning it for the one call.
public final class MultilingualCleanupProvider: Provider, @unchecked Sendable {
    public static let providerID: ProviderID = "local.llamacpp.cleanup.multilingual"

    public let id: ProviderID = MultilingualCleanupProvider.providerID
    public let capabilities: ProviderCapabilities = []
    public let costClass: CostClass = .free
    public let privacyClass: PrivacyClass = .onDevice
    private let shared: @Sendable () -> (any TextGenerator)?

    /// `shared`: CU8's provider (`SharedLocalLLM.shared.installedProvider`), resolved per call.
    public init(shared: @escaping @Sendable () -> (any TextGenerator)? = { SharedLocalLLM.shared.installedProvider }) {
        self.shared = shared
    }

    public var displayName: String { "Multilingual cleanup on this Mac" }

    public func isAvailable() async -> Bool {
        guard let shared = shared() else { return false }
        return await shared.isAvailable()
    }

    public func complete(stage: StageID, spans: [TranscriptSpan], context: StageContext) async throws -> ProviderCompletion {
        guard stage == .cleanup else { throw ProviderError.unavailable("multilingual cleanup serves cleanup only") }
        guard let shared = shared() else { throw ProviderError.unavailable("no shared local model") }
        // CU8 serves "Hinglish/style cleanup" under its `.style` stage name.
        let out = try await shared.generate(prompt: PromptBuilder.prompt(stage: stage, spans: spans, context: context),
                                            system: PromptBuilder.system(stage: stage, context: context), stage: .style)
        return ProviderCompletion(spans: SpanRewriter.apply(text: out.text, to: spans, by: stage),
                                  bytesOut: out.bytesOut, bytesIn: out.bytesIn, host: out.host)
    }
}

/// The cleanup stage's generator: the English one, or the multilingual route for a non-English turn.
public final class LanguageAwareCleanupGenerator: CleanupGenerating, @unchecked Sendable {
    public let english: any CleanupGenerating
    private let table: RoutingTable
    private let settings: SettingsStore?
    /// The current turn's choice (the LANG augmenter's), nil = unanswered.
    private let turnChoice: @Sendable () -> CleanupModelChoice?
    /// CU8's GGUF on this Mac (synchronous: the prompt style is picked before the call).
    private let multilingualReady: @Sendable () -> Bool

    public init(english: any CleanupGenerating, table: RoutingTable, settings: SettingsStore?,
                turnChoice: @escaping @Sendable () -> CleanupModelChoice? = { LanguageRuntime.current?.turnCleanupChoice },
                multilingualReady: @escaping @Sendable () -> Bool = { SharedLocalLLM.shared.isModelOnDisk }) {
        self.english = english
        self.table = table
        self.settings = settings
        self.turnChoice = turnChoice
        self.multilingualReady = multilingualReady
    }

    /// The route a turn takes. A provider the user pinned for `cleanup` wins (the English generator
    /// handles pins); the multilingual route needs the shared model on disk.
    public func route(context: StageContext? = nil) -> CleanupModelChoice {
        if case .provider? = settings?.string(SettingsKeys.routingPrefix + StageID.cleanup.rawValue).flatMap(ProviderChoice.init(rawValue:)) {
            return .english
        }
        let wanted = context?.extra[LanguageTurnKeys.cleanupModel].flatMap(CleanupModelChoice.init(rawValue:)) ?? turnChoice()
        guard wanted == .multilingual, multilingualReady() else { return .english }
        return .multilingual
    }

    public var promptStyle: CleanupPromptStyle { route() == .multilingual ? .delimited : english.promptStyle }

    public func cleanup(_ prompt: CleanupPrompt, context: StageContext) async throws -> String {
        // A prompt rendered for the specialist never goes to the generic model (and vice versa).
        guard route(context: context) == .multilingual, prompt.style == .delimited else {
            return try await english.cleanup(prompt, context: context)
        }
        var ctx = context
        ctx.extra[PromptBuilder.systemOverrideKey] = prompt.system + Self.languageLine(context.extra[LanguageTurnKeys.languages])
        ctx.extra[PromptBuilder.userOverrideKey] = prompt.user
        table.setChoice(.provider(MultilingualCleanupProvider.providerID), for: .cleanup)
        let span = TranscriptSpan(text: prompt.user, confidence: 1, audioRange: 0...0, provenance: [.asr])
        let outcome = try await table.complete(stage: .cleanup, spans: [span], context: ctx, purpose: "pipeline:cleanup:multilingual")
        // Anything else answering got a prompt it was not built for: no cleanup this turn.
        guard outcome.provider == MultilingualCleanupProvider.providerID else {
            throw ProviderError.unavailable("multilingual cleanup model did not answer")
        }
        return outcome.completion.spans.map(\.text).joined(separator: " ")
    }

    /// "\n- The speaker uses Hindi and English. Romanised Hindi is Hindi, not misspelt English; keep
    /// every word in the language and script it was spoken in."
    public static func languageLine(_ codes: String?) -> String {
        let names = (codes ?? "").split(separator: ",").map { LanguagePreferences.option(for: String($0)).name }
        guard !names.isEmpty else { return "" }
        let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!
        var line = "\n- The speaker uses \(list)."
        if names.contains("Hindi") { line += " Romanised Hindi is Hindi, not misspelt English." }
        return line + " Keep every word in the language and script it was spoken in."
    }
}

/// Composition-root glue, called from `CleanupWiring.stage`.
public enum LanguageCleanupWiring {
    /// Registers the multilingual route in `routing` and wraps the English generator.
    public static func wrap(_ english: any CleanupGenerating, routing: RoutingTable, settings: SettingsStore?) -> any CleanupGenerating {
        routing.register(MultilingualCleanupProvider())
        return LanguageAwareCleanupGenerator(english: english, table: routing, settings: settings)
    }
}
