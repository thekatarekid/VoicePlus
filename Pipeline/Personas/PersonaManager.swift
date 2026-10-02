import Foundation
import Shared

/// What applies to one utterance: the app persona plus any override for who you're talking to.
public struct ResolvedPersona: Equatable, Sendable {
    public var base: Persona
    public var recipient: String?
    public var override: String?
    /// The single instruction string fed to Providers (`StageContext.extra["persona"]`).
    public var promptText: String {
        guard let override, !override.isEmpty else { return base.text }
        let who = recipient.map { " (for \($0))" } ?? ""
        return "\(base.text) For this recipient\(who): \(override)"
    }
}

/// P2.5 — owns personas: auto-drafts from `StyleProfile` learnings, keeps user edits, applies
/// per-recipient overrides keyed by thread participants, and assembles the prompt text.
public struct PersonaManager: Sendable {
    public let store: any PersonaStoring
    public let styles: any StyleProfileStore
    public let participants: any ContextParticipants
    /// V5 F2 — the user's Dictionary for prompts. nil → the persona store's own database when it
    /// has one (`DatabasePersonaStore`), so the app's existing composition needs no extra wiring.
    public var dictionary: (any PersonalDictionarySource)?
    /// `StageContext.extra` key read by `PromptBuilder` in Providers.
    public static let promptKey = "persona"

    public init(store: any PersonaStoring = InMemoryPersonaStore(),
                styles: any StyleProfileStore = InMemoryStyleProfileStore(),
                participants: any ContextParticipants = StageContextParticipants()) {
        self.store = store; self.styles = styles; self.participants = participants
    }

    // MARK: Drafting / editing

    /// Stored persona, or a fresh auto-draft (persisted) when none exists. Auto-drafts are
    /// re-drafted from the latest learnings on every call; edited text is returned as is.
    public func persona(for bundleID: String, register: Utterance.Register = .unknown) throws -> Persona {
        let draft = try draftText(for: bundleID, register: register)
        if var existing = try store.persona(for: bundleID) {
            if existing.isAutoDrafted, existing.text != draft {
                existing.text = draft; existing.updatedAt = Date()
                try store.save(existing)
            }
            return existing
        }
        let p = Persona(appBundleID: bundleID, text: draft, isAutoDrafted: true)
        try store.save(p)
        return p
    }

    public func draftText(for bundleID: String, register: Utterance.Register = .unknown) throws -> String {
        let profile = try styles.profile(for: bundleID)
            ?? StyleProfile.coldStart(appBundleID: bundleID,
                                      category: register == .unknown ? AppCategoryTable.category(for: bundleID)
                                                                     : AppCategoryTable.category(for: register))
        return PersonaDrafter.draft(from: profile)
    }

    /// User edit. Empty text reverts to auto-drafting.
    @discardableResult
    public func setText(_ text: String, for bundleID: String) throws -> Persona {
        var p = try store.persona(for: bundleID) ?? Persona(appBundleID: bundleID, text: "")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { p.isAutoDrafted = true; p.text = try draftText(for: bundleID) }
        else { p.isAutoDrafted = false; p.text = trimmed }
        p.updatedAt = Date()
        try store.save(p)
        return p
    }

    @discardableResult
    public func setRecipientOverride(_ text: String?, recipient: String, for bundleID: String) throws -> Persona {
        var p = try persona(for: bundleID)
        let key = PersonaRecipient.key(recipient)
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        p.recipientOverrides[key] = trimmed.isEmpty ? nil : trimmed
        p.updatedAt = Date()
        try store.save(p)
        return p
    }

    /// N9 — apps whose stored auto persona and cold-start style came from a wrong category guess
    /// (the old `"code"` substring made `com.openai.codex` a code editor). Deletes an
    /// auto-drafted persona (an edited one is the user's and is kept) and resets a style profile
    /// whose category no longer matches the table, so the next draft starts from the right
    /// category. Returns the bundle ids that changed. Idempotent.
    @discardableResult
    public func resetMiscategorized(_ bundleIDs: Set<String> = SeedHints.personaResets) throws -> [String] {
        var changed: [String] = []
        for id in bundleIDs.sorted() {
            var did = false
            if let p = try store.persona(for: id), p.isAutoDrafted { try store.delete(bundleID: id); did = true }
            let category = AppCategoryTable.category(for: id)
            if let profile = try styles.profile(for: id), profile.category != category {
                try styles.save(StyleProfile.coldStart(appBundleID: id, category: category)); did = true
            }
            if did { changed.append(id) }
        }
        return changed
    }

    // MARK: Resolution / prompt assembly

    /// Persona for this context: base for the app, override for the first thread participant
    /// that has one. Without an app there is no persona.
    public func resolve(context: StageContext) throws -> ResolvedPersona? {
        guard let bundle = context.appBundleID, !bundle.isEmpty else { return nil }
        let base = try persona(for: bundle, register: context.register)
        for who in participants.participants(context: context) {
            if let o = base.recipientOverrides[PersonaRecipient.key(who)] {
                return ResolvedPersona(base: base, recipient: who, override: o)
            }
        }
        return ResolvedPersona(base: base, recipient: nil, override: nil)
    }

    /// Same context with `extra["persona"]` filled in, ready for `PromptBuilder`/providers, plus the
    /// V5 F2 personalisation keys (`personal.dictionary`, `personal.style`; see
    /// `Personalisation`). Values already present in `extra` (e.g. set by a test or the Lab) are kept.
    public func decorate(_ context: StageContext) -> StageContext {
        var c = context
        if c.extra[Self.promptKey] == nil, let r = try? resolve(context: context) { c.extra[Self.promptKey] = r.promptText }
        return personalisation(for: c).apply(to: c)
    }

    /// V5 F2 — persona + Dictionary + learned style for this context, for D2 cleanup and CU8 planner
    /// prompts. The persona is whatever `decorate` resolved (or a caller set) in `extra["persona"]`.
    public func personalisation(for context: StageContext) -> Personalisation {
        let persona = context.extra[Self.promptKey] ?? (try? resolve(context: context))?.promptText
        let source = dictionary ?? (store as? any PersonalDictionarySource)
        var terms: [String] = []
        if let source, let t = try? source.personalTerms() { terms = t }
        var style: [String] = []
        if let bundle = context.appBundleID, !bundle.isEmpty, let profile = try? styles.profile(for: bundle) {
            style = Personalisation.styleHints(from: profile)
        }
        return Personalisation(persona: persona, dictionary: terms, style: style)
    }
}
