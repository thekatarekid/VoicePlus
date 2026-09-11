import Combine
import Engine
import Foundation

/// R4.3 — the *learned* half of the Dictionary tab.
///
/// `DictionaryViewModel` (in `SettingsViewModels.swift`) is the user-typed term list —
/// term / spoken forms / add / edit / delete / Contacts import (`DESIGN.md` §9.3). This view model
/// is the other list `VoicePlus_Improvements_V3.md` §7.5 asks for: entries `AdaptationLoop` learned
/// on its own from corrections, each showing the corrected **spelling**, every **"heard as"** form
/// that respells it, and its **origin** — with a **Forget** action.
///
/// Forgetting takes effect on the very next utterance because it mutates
/// `AdaptationLoop.lexicon` in place (see `AdaptationLoop.forget`), which is the exact stored
/// value `RegressionGuardStage` re-reads fresh on every call
/// (`App/Services/AppContainer.swift:157`) and `LearnedLexiconSource` re-harvests fresh on every
/// biasing pass — there is no separate "live" copy to invalidate.
///
/// `LexiconSanity` (`Engine/Adapt/TrainingPairStore.swift`) already refuses document-sized or
/// ambiguous pairs at store, ingest and use time; this view only lists and removes what already
/// passed that gate, and never re-implements or loosens it.
@MainActor
public final class LearnedDictionaryViewModel: ObservableObject {
    /// One row: a spelling this Mac learned, what it used to hear instead, and where the
    /// correction came from.
    public struct Entry: Identifiable, Equatable, Sendable {
        public var id: String { spelling.lowercased() }
        public var spelling: String
        /// Every misheard form on record that this spelling corrects, sorted for stable display.
        public var heardAs: [String]
        /// Human label for `TrainingPair.source` of the most recent pair that taught this entry,
        /// or a generic fallback when no matching pair survives (e.g. `Term`-only entities pulled
        /// out of a multi-word correction).
        public var origin: String
        public var corrections: Int

        public init(spelling: String, heardAs: [String], origin: String, corrections: Int) {
            self.spelling = spelling; self.heardAs = heardAs; self.origin = origin; self.corrections = corrections
        }
    }

    @Published public private(set) var entries: [Entry] = []
    @Published public var filter = ""
    private let loop: AdaptationLoop?
    private let store: TrainingPairStore?

    public init(loop: AdaptationLoop?, store: TrainingPairStore?) {
        self.loop = loop; self.store = store
        reload()
    }

    public var filtered: [Entry] {
        filter.isEmpty ? entries : entries.filter {
            $0.spelling.localizedCaseInsensitiveContains(filter) || $0.heardAs.contains { $0.localizedCaseInsensitiveContains(filter) }
        }
    }

    public func reload() {
        guard let loop else { entries = []; return }
        let lexicon = loop.lexicon
        let pairs = (store?.all() ?? []).sorted { $0.createdAt < $1.createdAt }

        var originBySpelling: [String: String] = [:]
        for p in pairs {
            let key = p.corrected.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { continue }
            originBySpelling[key] = Self.describe(source: p.source) // last write wins → most recent
        }
        var heardBySpelling: [String: Set<String>] = [:]
        for v in lexicon.variants.values {
            let key = v.corrected.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            heardBySpelling[key, default: []].insert(v.heard)
        }

        entries = lexicon.terms.values
            .sorted { $0.lastSeen > $1.lastSeen }
            .map { term in
                let key = term.text.lowercased()
                return Entry(spelling: term.text,
                            heardAs: (heardBySpelling[key] ?? []).sorted(),
                            origin: originBySpelling[key] ?? "learned automatically",
                            corrections: term.corrections)
            }
    }

    /// Removes the entry (and any "heard as" variants of it) from the live lexicon and from the
    /// training pairs that could resurrect it on the next retrain.
    public func forget(_ entry: Entry) {
        guard let loop else { return }
        _ = loop.forget(spelling: entry.spelling)
        reload()
    }

    static func describe(source: String) -> String {
        switch source {
        case "voiceRepair": return "voice repair"
        case "keyboardEdit": return "keyboard edit"
        case "dualPath": return "dual-path correction"
        case "postDictationEdit": return "post-dictation edit"
        case "trainByVoice": return "trained by voice"
        default: return source.isEmpty ? "learned automatically" : source
        }
    }
}
