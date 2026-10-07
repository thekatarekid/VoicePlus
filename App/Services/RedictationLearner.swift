import Engine
import Foundation
import Shared

/// C1 — re-dictation is a correction (investigation 2026-10-06 §4 Tier C; Context Writer plan §8).
///
/// The strongest correction signal the user gives is saying it again: "fan out sub variance" lands,
/// the user deletes it and says "fan out subagents". Nothing captured that. This learner watches
/// consecutive landings and, when the second one is a re-dictation of the first — same app, within
/// `window` (30 s), the earlier text no longer in the field (AX readback) or replaced by the new one,
/// and the two phonetically alike with a differing region — learns the alias `heard → written` for
/// the differing words through the existing adaptation loop (`TrainingPairStore` pair with source
/// `TrainingPair.redictationSource` → `AdaptationLoop.retrain()` → `PersonalLexicon.variants`),
/// where the regression guard, the Biasing ranker and the vocabulary matcher already read.
///
/// Privacy: the log carries counts and reason codes only — never the heard or written words.
///
/// `undoCorrection(heard:written:)` is the reverse hook for the wave-2 UX: the user put a corrected
/// word back, so that written form is never proposed for that heard form again (a negative alias,
/// `TrainingPair.negativeAliasSource` → `PersonalLexicon.negatives`).
///
/// Wired by `WriterWiring`: every landed, non-secure, non-own-process dictation reaches `observe`
/// (`UtteranceLander.onInjected` → `WriterWiring.observeLanded`, with an AX `fieldReadback`), and the
/// landed row's Undo of the writer's changes reaches `undoCorrection` (`TurnController.onUndoCorrection`
/// → `WriterWiring.connectUndo(to:)`), both on the writer's learning queue. Screen text is data here,
/// never instructions, and nothing is read from secure fields: the caller must not observe those turns.
public final class RedictationLearner: @unchecked Sendable {
    public struct Landing: Equatable, Sendable {
        public var text: String
        public var app: String?
        public var at: Date
        public init(text: String, app: String?, at: Date) { self.text = text; self.app = app; self.at = at }
    }

    /// One alias learned from a re-dictation.
    public struct Alias: Equatable, Sendable {
        public var heard: String
        public var written: String
        public init(heard: String, written: String) { self.heard = heard; self.written = written }
    }

    /// A re-dictation lands within this long of the landing it replaces.
    public let window: TimeInterval
    /// The two landings as a whole must sound at least this alike (0…1).
    public var minSimilarity: Double = 0.6
    /// Each differing region must sound at least this alike to be a respelling, not a rewording.
    public var minRegionSimilarity: Double = 0.45

    private let store: TrainingPairStore
    private let loop: AdaptationLoop
    private let fieldReadback: (@Sendable () -> String?)?
    private let lock = NSLock()
    private var previous: Landing?

    public init(store: TrainingPairStore, loop: AdaptationLoop, window: TimeInterval = 30,
                fieldReadback: (@Sendable () -> String?)? = nil) {
        self.store = store
        self.loop = loop
        self.window = window
        self.fieldReadback = fieldReadback
    }

    public convenience init(adaptation: AdaptationService, window: TimeInterval = 30,
                            fieldReadback: (@Sendable () -> String?)? = nil) {
        self.init(store: adaptation.store, loop: adaptation.loop, window: window, fieldReadback: fieldReadback)
    }

    /// The landing this learner would compare the next one against.
    public var lastLanding: Landing? { lock.lock(); defer { lock.unlock() }; return previous }

    /// Forget the previous landing (focus moved to another app, the machine slept, a turn was undone).
    public func reset() { lock.lock(); previous = nil; lock.unlock() }

    /// A dictation landed. Returns the aliases learned when this landing was a re-dictation of the
    /// previous one; empty otherwise. `fieldText` is the focused field's value after the landing
    /// (AX readback) when the caller has it; it overrides `fieldReadback`.
    @discardableResult
    public func observe(landing text: String, app: String?, at now: Date = Date(), fieldText: String? = nil) -> [Alias] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let current = Landing(text: trimmed, app: app, at: now)
        lock.lock()
        let earlier = previous
        previous = current
        lock.unlock()
        guard let earlier, let app, earlier.app == app else { return [] }
        let gap = now.timeIntervalSince(earlier.at)
        guard gap >= 0, gap <= window else { return [] }
        guard earlier.text.lowercased() != trimmed.lowercased() else { return [] }

        // The earlier text still sitting in the field means the user *added* to it: not a re-dictation.
        if let field = fieldText ?? fieldReadback?(), Self.contains(field: field, landing: earlier.text) { return [] }

        let heard = RedictationAlignment.words(earlier.text)
        let written = RedictationAlignment.words(trimmed)
        guard !heard.isEmpty, !written.isEmpty else { return [] }
        let whole = RedictationAlignment.similarity(heard: heard, written: written)
        guard whole >= minSimilarity else { return [] }

        let lexicon = loop.lexicon
        var learned: [Alias] = []
        for region in RedictationAlignment.regions(heard: heard, written: written) {
            guard region.similarity >= minRegionSimilarity,
                  region.heard.lowercased() != region.written.lowercased(),
                  !RedictationAlignment.isFunctionWordsOnly(region.heard),
                  !RedictationAlignment.isFunctionWordsOnly(region.written),
                  !lexicon.isBlocked(heard: region.heard, written: region.written) else { continue }
            if record(original: region.heard, corrected: region.written, source: TrainingPair.redictationSource, at: now) {
                learned.append(Alias(heard: region.heard, written: region.written))
            }
        }
        guard !learned.isEmpty else { return [] }
        loop.retrain()
        // Counts and reason codes only (Q13): never the heard or written words, never the app's text.
        Log.app.info("redictation: learned \(learned.count) alias(es) after \(Int(gap)) s (whole similarity \(String(format: "%.2f", whole)))")
        return learned
    }

    /// The user put `heard` back where the app had written `written`: never write it again for that
    /// heard form. Stored as a negative alias; any positive alias for the pair is dropped on retrain.
    /// Returns false when nothing could be stored (empty input, or not a respelling at all).
    @discardableResult
    public func undoCorrection(heard: String, written: String, app: String? = nil, at now: Date = Date()) -> Bool {
        let h = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let w = written.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty, !w.isEmpty, h.lowercased() != w.lowercased() else { return false }
        guard record(original: h, corrected: w, source: TrainingPair.negativeAliasSource, at: now) else { return false }
        loop.retrain()
        // Counts only (Q13): the words are the user's dictation and never reach the log.
        Log.app.info("redictation: undo stored 1 negative alias (heard \(Self.wordCount(h)) word(s), written \(Self.wordCount(w)) word(s))")
        return true
    }

    // MARK: - Helpers

    /// True when the stored pair count grew: `TrainingPairStore.add` silently refuses implausible pairs.
    private func record(original: String, corrected: String, source: String, at now: Date) -> Bool {
        let before = store.count
        do {
            try store.add(TrainingPair(utteranceID: "\(source):\(UUID().uuidString)", createdAt: now, original: original,
                                       corrected: corrected, audioRange: 0...0, source: source))
        } catch {
            Log.app.error("redictation: store failed (\(String(describing: type(of: error))))")
            return false
        }
        return store.count > before
    }

    static func wordCount(_ text: String) -> Int { text.split(whereSeparator: \.isWhitespace).count }

    /// Whitespace- and case-insensitive containment of a landing in a field readback.
    static func contains(field: String, landing: String) -> Bool {
        let f = RedictationAlignment.words(field).map { $0.lowercased() }.joined(separator: " ")
        let l = RedictationAlignment.words(landing).map { $0.lowercased() }.joined(separator: " ")
        guard !l.isEmpty else { return false }
        return (" " + f + " ").contains(" " + l + " ")
    }
}
