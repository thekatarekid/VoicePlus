import Actions
import Engine
import Foundation
import Shared

// MARK: - V5 CU4 · Layer 2 wiring for the act router
//
// Catalogue retrieval embeds with the same on-device sentence encoder as the meeting Ask index
// (M16: `NLSentenceEmbedder`, Apple's NaturalLanguage sentence embedding, hashing fallback). The
// index is built once, in the background, when the act session is created. The CUA-S1 chooser is
// resolved lazily on the first single-step goal (never on an 8 GB plan).

/// `Engine.SentenceEmbedding` as the act router's `ActPhraseEmbedding`.
public struct SentencePhraseEmbedding: ActPhraseEmbedding {
    public let inner: any SentenceEmbedding
    public init(_ inner: any SentenceEmbedding = NLSentenceEmbedder()) { self.inner = inner }
    public var name: String { inner.name }
    public func embed(_ texts: [String]) async -> [[Float]] { await inner.embed(texts) }
}

public enum ComputerUseLayer2 {
    /// Give `router` its retrieval index and chooser source unless something already did.
    /// Returns true when it installed them.
    @discardableResult
    public static func install(on router: ActRouter,
                               embedder: any ActPhraseEmbedding = SentencePhraseEmbedding(),
                               chooser: (@Sendable () async -> (any SingleStepChoosing)?)? = { await ComputerUseChooserWiring.singleStep() },
                               prepare: Bool = true) -> Bool {
        guard router.retrieval == nil, router.chooserProvider == nil, router.chooser == nil else { return false }
        let index = CatalogRetrievalIndex(catalog: router.parser.catalog, embedder: embedder)
        router.retrieval = index
        router.chooserProvider = chooser
        if prepare { Task.detached(priority: .utility) { await index.prepare() } }
        return true
    }
}
