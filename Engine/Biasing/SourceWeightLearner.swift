import Foundation
import Shared

// N28 — the learning loop (Investigation R3 §E3 "These weights are starting points", §F N28).
//
// After each landed turn the app reports which rubric terms were offered, the raw and final text,
// and any corrections (heard → written). The learner:
//   • counts, per surface and source, how many offered terms matched the final text, and how many
//     were corrected away (a boosted swap the user undid);
//   • turns those counts into bounded per-surface source multipliers (`RubricWeights`, 0.5…1.5),
//     relative to the surface's pooled hit rate and smoothed toward 1 until there is enough data;
//   • keeps heard aliases from corrections (globally and per app) so later turns carry them.
// Persisted as a small JSON file under `AppPaths.supportDirectory()` (no Shared DB change). Only
// counts, terms and aliases are stored — never the dictated text. Secure surfaces are never recorded.

/// A user correction: what the recogniser produced → what the user wrote.
public struct HeardCorrection: Sendable, Equatable, Codable {
    public var heard: String
    public var written: String
    public init(heard: String, written: String) { self.heard = heard; self.written = written }
}

/// One landed turn, as the learner sees it.
public struct TurnContextOutcome: Sendable {
    public var surfaceID: String
    public var app: String?
    /// The terms the rubric offered this turn (stable + per-turn layers, spell list terms).
    public var offered: [RubricTerm]
    /// Recogniser output before cleanup (N6); used to spot boosted swaps the user corrected away.
    public var rawText: String?
    public var finalText: String
    public var corrections: [HeardCorrection]

    public init(surfaceID: String, app: String? = nil, offered: [RubricTerm], rawText: String? = nil,
                finalText: String, corrections: [HeardCorrection] = []) {
        self.surfaceID = surfaceID
        self.app = app
        self.offered = offered
        self.rawText = rawText
        self.finalText = finalText
        self.corrections = corrections
    }

    public init(surface: SurfaceKind, app: String? = nil, ranked: RankedContext, rawText: String? = nil,
                finalText: String, corrections: [HeardCorrection] = []) {
        var seen = Set<String>()
        let terms = (ranked.stableLayer + ranked.perTurnLayer).filter { seen.insert($0.text.lowercased()).inserted }
        self.init(surfaceID: surface.id, app: app, offered: terms, rawText: rawText,
                  finalText: finalText, corrections: corrections)
    }
}

/// Counts for one (surface, source) pair.
public struct SourceStats: Sendable, Equatable, Codable {
    public var offered: Double = 0
    public var matched: Double = 0
    public var correctedAway: Double = 0
    public init(offered: Double = 0, matched: Double = 0, correctedAway: Double = 0) {
        self.offered = offered; self.matched = matched; self.correctedAway = correctedAway
    }
}

/// The persisted state (versioned JSON).
public struct LearnedContextState: Sendable, Equatable, Codable {
    public var version = 1
    /// surface id → source raw value → stats.
    public var stats: [String: [String: SourceStats]] = [:]
    /// lowercased written term → heard forms.
    public var aliases: [String: [String]] = [:]
    /// app → lowercased written term → heard forms.
    public var appAliases: [String: [String: [String]]] = [:]
    public init() {}
}

public final class SourceWeightLearner: @unchecked Sendable {
    public struct Config: Sendable, Equatable {
        /// Offers per (surface, source) before its multiplier moves away from 1.
        public var minOffers: Double = 10
        /// Pseudo-offers pulling a source's rate toward its surface's pooled rate.
        public var smoothing: Double = 20
        /// A correction that undid an offered term counts this many misses.
        public var correctionPenalty: Double = 2
        /// When a pair's offers exceed this, all its counts are halved (recent turns matter more).
        public var decayAt: Double = 400
        public var maxAliasesPerTerm = 8
        public var maxAliasCharacters = 48
        public init() {}
    }

    public static let fileName = "context-learning.json"
    public static func defaultURL() -> URL { AppPaths.supportDirectory().appendingPathComponent(fileName) }

    /// The app-wide learner, persisted under the support directory. Wiring: pass
    /// `{ SourceWeightLearner.shared.weights() }` as `BoostingWiring`'s `weights`, and call
    /// `record(_:)` after each landed turn.
    public static let shared = SourceWeightLearner(fileURL: defaultURL())

    public let fileURL: URL?
    public let config: Config
    private let lock = NSLock()
    private var state: LearnedContextState
    private var cachedWeights: RubricWeights?

    /// `fileURL == nil` → in-memory only (tests). An unreadable or corrupt file starts fresh.
    public init(fileURL: URL?, config: Config = Config()) {
        self.fileURL = fileURL
        self.config = config
        if let url = fileURL, let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(LearnedContextState.self, from: data), decoded.version == 1 {
            state = decoded
        } else {
            state = LearnedContextState()
        }
    }

    public var snapshot: LearnedContextState { lock.withLock { state } }

    // MARK: recording

    /// Records one landed turn and persists. Secure surfaces are ignored.
    public func record(_ turn: TurnContextOutcome) {
        guard turn.surfaceID != SurfaceKind.secure.id else { return }
        lock.withLock {
            apply(turn)
            cachedWeights = nil
        }
        save()
    }

    private func apply(_ turn: TurnContextOutcome) {
        let final = turn.finalText
        let fixes = turn.corrections.filter {
            let h = $0.heard.trimmingCharacters(in: .whitespacesAndNewlines)
            let w = $0.written.trimmingCharacters(in: .whitespacesAndNewlines)
            return !h.isEmpty && !w.isEmpty && h != w
        }
        var seen = Set<String>()
        for term in turn.offered {
            let key = term.text.lowercased()
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            // Undone: the recogniser wrote it and the user corrected it to something else.
            // Also undone: it was in the raw text (e.g. a boosted swap) but did not survive to the final text.
            // Case-sensitive on the corrected side: "Bucket" → "bucket" undoes the capitalised swap.
            let undone = fixes.contains { Self.contains($0.heard, term.text, caseSensitive: true) && !Self.contains($0.written, term.text, caseSensitive: true) }
                || (turn.rawText.map { Self.contains($0, term.text, caseSensitive: true) } == true
                    && !Self.contains(final, term.text, caseSensitive: true))
            // Needed: the user wrote it via a correction (the term was right; recognition missed it).
            let needed = fixes.contains { Self.contains($0.written, term.text) && !Self.contains($0.heard, term.text) }
            let matched = !undone && (needed || Self.contains(final, term.text))
            for source in term.sources {
                var s = state.stats[turn.surfaceID, default: [:]][source.rawValue, default: SourceStats()]
                s.offered += 1
                if matched { s.matched += 1 }
                if undone { s.correctedAway += 1 }
                if s.offered > config.decayAt {
                    s.offered /= 2; s.matched /= 2; s.correctedAway /= 2
                }
                state.stats[turn.surfaceID, default: [:]][source.rawValue] = s
            }
        }
        for fix in fixes where Self.norm(fix.heard) != Self.norm(fix.written) { addAlias(heard: fix.heard, written: fix.written, app: turn.app) }
    }

    private func addAlias(heard: String, written: String, app: String?) {
        let h = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = Self.norm(written)
        guard !h.isEmpty, h.count <= config.maxAliasCharacters, key.count <= config.maxAliasCharacters,
              !h.contains(where: \.isNewline) else { return }
        func merged(_ list: [String]) -> [String] {
            var l = list.filter { $0.lowercased() != h.lowercased() }
            l.append(h)
            return Array(l.suffix(config.maxAliasesPerTerm))
        }
        state.aliases[key] = merged(state.aliases[key] ?? [])
        if let app, !app.isEmpty {
            state.appAliases[app, default: [:]][key] = merged(state.appAliases[app]?[key] ?? [])
        }
    }

    // MARK: outputs

    /// Bounded per-surface source multipliers for `ContextRubric`.
    public func weights() -> RubricWeights {
        lock.withLock {
            if let w = cachedWeights { return w }
            let w = computeWeights()
            cachedWeights = w
            return w
        }
    }

    private func computeWeights() -> RubricWeights {
        var out: [String: [String: Double]] = [:]
        for (surface, bySource) in state.stats {
            let offered = bySource.values.reduce(0) { $0 + $1.offered }
            let hits = bySource.values.reduce(0) { $0 + max(0, $1.matched - config.correctionPenalty * $1.correctedAway) }
            guard offered > 0 else { continue }
            let baseline = max(0.02, hits / offered)
            for (source, s) in bySource where s.offered >= config.minOffers {
                let eff = max(0, s.matched - config.correctionPenalty * s.correctedAway)
                let rate = (eff + baseline * config.smoothing) / (s.offered + config.smoothing)
                let m = min(max(rate / baseline, RubricWeights.bounds.lowerBound), RubricWeights.bounds.upperBound)
                if abs(m - 1) > 0.001 { out[surface, default: [:]][source] = (m * 1000).rounded() / 1000 }
            }
        }
        return RubricWeights(surfaceMultipliers: out)
    }

    /// Heard forms for a term (per-app first, then global), newest last, deduplicated.
    public func aliases(for term: String, app: String? = nil) -> [String] {
        lock.withLock {
            let key = Self.norm(term)
            var out: [String] = []
            if let app { out += state.appAliases[app]?[key] ?? [] }
            for a in state.aliases[key] ?? [] where !out.contains(where: { $0.lowercased() == a.lowercased() }) { out.append(a) }
            return out
        }
    }

    /// Candidates with their heard aliases attached (the rubric carries them; the booster may use them).
    public func attachingAliases(_ candidates: [ContextCandidate], app: String? = nil) -> [ContextCandidate] {
        candidates.map { c in
            var c = c
            for a in aliases(for: c.text, app: app) where !c.heardAliases.contains(a) { c.heardAliases.append(a) }
            return c
        }
    }

    /// Forget everything learned (Settings → reset); removes the file.
    public func reset() {
        lock.withLock { state = LearnedContextState(); cachedWeights = nil }
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: persistence

    private func save() {
        guard let url = fileURL else { return }
        let data: Data? = lock.withLock {
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            return try? enc.encode(state)
        }
        guard let data else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic])
    }

    // MARK: matching

    static func norm(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    /// Whole-word containment (case-insensitive by default) (term edges must not touch letters/digits).
    static func contains(_ text: String, _ term: String, caseSensitive: Bool = false) -> Bool {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !text.isEmpty else { return false }
        var start = text.startIndex
        while let r = text.range(of: t, options: caseSensitive ? [] : [.caseInsensitive], range: start..<text.endIndex) {
            let before = r.lowerBound == text.startIndex ? nil : text[text.index(before: r.lowerBound)]
            let after = r.upperBound == text.endIndex ? nil : text[r.upperBound]
            let edge: (Character?) -> Bool = { c in c.map { !($0.isLetter || $0.isNumber) } ?? true }
            if edge(before) && edge(after) { return true }
            start = r.upperBound
        }
        return false
    }
}
