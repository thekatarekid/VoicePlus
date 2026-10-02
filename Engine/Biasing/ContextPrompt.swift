import Foundation
import Shared

// V5 B2 + E1 — the ranked context, as a bounded prompt, handed to the cleanup stage (D2).
//
// `ContextSession` already owns the list's lifetime (rebuild per utterance, discard per session).
// This file adds the one thing that was missing (V5 X2): something that *calls* it on the landing
// path and puts `PromptBuilder`'s output where the cleanup prompt reads it —
// `StageContext.extra[ContextPromptKeys.prompt]`.
//
// Privacy is unchanged (V3 §7.3): the prompt string travels only inside a `StageContext` for one
// run; nothing here logs, persists or serialises a term. `PromptBuilder` still drops instruction-
// shaped screen text and caps the prompt at 1 000 characters.

/// Keys this path writes into `StageContext.extra`.
public enum ContextPromptKeys {
    /// `PromptBuilder.prompt(for:)` of the utterance's `RankedContext`. Absent when empty.
    /// D2's `CleanupStage` reads it into the `<context>…</context>` block (D4).
    public static let prompt = "context.prompt"
    /// N14 — the rubric's "spell exactly" list (`RankedContext.spellList`), newline-separated.
    /// Same string as `Pipeline.CleanupPrompt.spellListKey`.
    public static let spell = "context.spell"
    /// N14 — the rubric's top screen terms (`RankedContext.promptTerms`), newline-separated.
    /// Same string as `Pipeline.CleanupPrompt.screenTermsKey`.
    public static let terms = "context.terms"

    /// N14 — writes (or removes) the rubric's two cleanup lists. A tier-ranked list has none, so
    /// both keys are removed and cleanup falls back to the Dictionary and `context.prompt`.
    public static func writeRubricLists(_ ranked: RankedContext?, into context: inout StageContext) {
        let spellList = ranked?.spellList ?? [], promptTerms = ranked?.promptTerms ?? []
        let hasRubric = ranked.map { !$0.stableLayer.isEmpty || !$0.perTurnLayer.isEmpty || !spellList.isEmpty || !promptTerms.isEmpty } ?? false
        guard hasRubric else {
            context.extra.removeValue(forKey: spell)
            context.extra.removeValue(forKey: terms)
            return
        }
        func clean(_ xs: [String]) -> String {
            xs.compactMap { PromptBuilder.sanitized($0) }.joined(separator: "\n")
        }
        context.extra[spell] = clean(spellList)
        context.extra[terms] = clean(promptTerms)
    }
}

/// Additive seam for consumers that want the ranked list itself rather than the string (D2's
/// cleanup stage, Lab). The live conformer is `ContextPromptSession`.
public protocol RankedContextProviding: AnyObject, Sendable {
    /// The list built for the current utterance; `.empty` before the first build and after discard.
    var currentRankedContext: RankedContext { get }
    /// The bounded prompt for the current utterance; `""` when nothing survived.
    var currentContextPrompt: String { get }
}

/// One `ContextSession` + one `PromptBuilder`, driven per utterance.
///
/// * `prepareUtterance()` — rebuild the ranked list from every source and build the prompt. Call at
///   the start of each landing: screen text one utterance old is stale.
/// * `discard()` — forget the list, the prompt and the harvester's cached entries.
/// * A gap longer than `sessionGap` between utterances is a new session: the previous one's list is
///   discarded before the rebuild, so nothing harvested survives into an unrelated session.
/// * `idleDiscardAfter` (live only) discards the list that long after the last utterance, so screen
///   text does not sit in memory while the user is away.
public final class ContextPromptSession: RankedContextProviding, @unchecked Sendable {
    public let session: ContextSession
    public var builder: PromptBuilder
    public let sessionGap: TimeInterval
    public let idleDiscardAfter: TimeInterval?
    /// N14 — the turn's rubric ranking (`ContextRubric`), when the app wired one. Its spell list
    /// and screen terms go to the cleanup prompt (`ContextPromptKeys.spell` / `.terms`).
    public var rubric: (@Sendable (Date) -> RankedContext?)?

    private let lock = NSLock()
    private var prompt = ""
    private var lastPrepared: Date?
    private var discards = 0
    private var idleWork: DispatchWorkItem?

    public init(session: ContextSession, builder: PromptBuilder = PromptBuilder(),
                sessionGap: TimeInterval = 120, idleDiscardAfter: TimeInterval? = nil) {
        self.session = session
        self.builder = builder
        self.sessionGap = max(0, sessionGap)
        self.idleDiscardAfter = idleDiscardAfter
    }

    public convenience init(harvester: ContextHarvester, builder: PromptBuilder = PromptBuilder(),
                            sessionGap: TimeInterval = 120, idleDiscardAfter: TimeInterval? = nil) {
        self.init(session: ContextSession(harvester: harvester), builder: builder,
                  sessionGap: sessionGap, idleDiscardAfter: idleDiscardAfter)
    }

    public var currentRankedContext: RankedContext { session.current }
    public var currentContextPrompt: String { lock.withLock { prompt } }
    /// How many times the list was discarded (explicitly, by the session gap, or idle).
    public var discardCount: Int { lock.withLock { discards } }

    /// Rebuild + build for one utterance. Returns the prompt (`""` when nothing survived).
    @discardableResult
    public func prepareUtterance(now: Date = Date()) -> String {
        let stale = lock.withLock { () -> Bool in
            guard let last = lastPrepared else { return false }
            return now.timeIntervalSince(last) > sessionGap
        }
        if stale { discard() }
        let ranked = session.rebuild(now: now)
        let built = builder.prompt(for: ranked)
        lock.withLock {
            prompt = built
            lastPrepared = now
        }
        scheduleIdleDiscard()
        return built
    }

    /// Prepare and write the prompt into `context` (or remove a stale key when empty).
    public func write(into context: inout StageContext, now: Date = Date()) {
        let built = prepareUtterance(now: now)
        if built.isEmpty {
            context.extra.removeValue(forKey: ContextPromptKeys.prompt)
        } else {
            context.extra[ContextPromptKeys.prompt] = built
        }
        ContextPromptKeys.writeRubricLists(rubric?(now), into: &context)
    }

    /// End of session: list, prompt and the harvest behind them are dropped.
    public func discard() {
        session.discard()
        lock.withLock {
            prompt = ""
            lastPrepared = nil
            discards += 1
            idleWork?.cancel()
            idleWork = nil
        }
    }

    private func scheduleIdleDiscard() {
        guard let delay = idleDiscardAfter else { return }
        let work = DispatchWorkItem { [weak self] in self?.discard() }
        lock.withLock {
            idleWork?.cancel()
            idleWork = work
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: work)
    }
}
