// VoicePlus original (task R5.3). The shipped policy for "is a second pass worth its deadline?".
import Foundation
import Shared

/// What the user chose in Settings › Voice (V3 §5.3, §9.7).
///
/// `auto` is the only mode that consults the gate; the other two are the user overruling it, and
/// they are honoured verbatim so that "Never" really means never and "Always" is a usable
/// debugging switch. Neither can conjure a second pass that is not installed — availability is
/// checked before the mode (see `RefinementGate.decide`).
public enum RefinementMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// The gate decides, per segment.
    case auto
    /// Refine every segment that reaches the stage.
    case always
    /// Never refine. The second pass is not loaded and no prompt is built.
    case never

    public var id: String { rawValue }

    /// Title for the Voice tab picker.
    public var title: String {
        switch self {
        case .auto: return "Auto"
        case .always: return "Always"
        case .never: return "Never"
        }
    }

    /// One line of plain English, for the caption under the picker.
    public var explanation: String {
        switch self {
        case .auto:
            return "A second pass runs only when the first one looks unsure, when a name on screen "
                + "sounds like a word you just said, when the words are not English, or when the "
                + "segment is long."
        case .always:
            return "Every segment gets a second pass. Slower, and on the corpus measured so far the "
                + "second model is less accurate overall — useful for comparing, not for daily use."
        case .never:
            return "One pass only. The second model is never loaded."
        }
    }
}

/// Every number the gate can be tuned by, with the reason for each default (R5.3).
///
/// Call sites pass one of these; no threshold is written at a call site. `RefinementGateSettings`
/// is a value, so a Lab arm or a test can vary one number without touching the policy.
public struct RefinementGateSettings: Sendable, Equatable {

    // MARK: Condition 1 — streaming uncertainty

    /// Pass-1 confidence at or below which a second pass is always worth it.
    ///
    /// 0.5 is `TranscriptSpan.lowConfidenceThreshold`, the line the rest of the pipeline already
    /// uses to mean "do not rewrite this silently, it is not settled".
    public var lowConfidence: Float
    /// Whether a segment whose confidence is unknown counts as uncertain.
    ///
    /// Default **false**. Parakeet reports a real number for every span, so `nil` here means some
    /// other producer (a mock, a repaired span, a provider that reports nothing) — and opening the
    /// gate on an absent signal would fire on everything that does not measure itself. V3 §5.3
    /// wants unavailable confidence *marked*, not assumed: the decision records
    /// `confidenceUnavailable` in its signals either way.
    public var treatsUnknownConfidenceAsUncertain: Bool

    // MARK: Condition 2 — context near miss (phonetic)

    /// How many phonetic near misses open the gate. 1: a single name heard as a sound-alike is the
    /// case a context-primed pass exists to fix.
    public var minNearMisses: Int
    /// Phonetic-neighbour similarity (1 − normalised edit distance) that counts as a near miss.
    /// Mirrors `ContextGate.Thresholds.minSimilarity`, which computes the count this policy reads
    /// ("Katari's"/"Kothari" 0.57, "Prea"/"Priya" 0.60).
    public var nearMissMinSimilarity: Float
    /// A near miss must be at least this long, so "a"/"the" cannot trip the gate. Mirrors
    /// `ContextGate.Thresholds.minWordCharacters`.
    public var nearMissMinWordCharacters: Int
    /// A near miss only counts when the second pass will actually see a prompt: a term that was
    /// elided by the character cap cannot be the reason the pass succeeds.
    public var requiresPromptForNearMiss: Bool

    // MARK: Condition 3 — non-English

    /// Fraction of the letters in the hypothesis that may sit outside the Latin scripts before the
    /// segment is called non-English.
    ///
    /// 0.15 rather than 0: one stray glyph (a ₹, an emoji-adjacent letter, a pasted name) is not a
    /// language, and the corpus contains none at all, so the choice costs nothing here and stops a
    /// single character from opening the gate on an English sentence.
    public var maxNonLatinLetterRatio: Double
    /// Below this many letters the script evidence is noise and is ignored ("ok", "हाँ" are both
    /// too short to tell a language from). 8 letters ≈ two words.
    public var nonLatinMinLetters: Int
    /// Whether a language *hint* that names something other than English opens the gate.
    ///
    /// Default true, and it is the only way the gate can see a Latin-script foreign language at all.
    /// Off is for a caller whose hint is a stale locale rather than a per-utterance judgement — a
    /// user dictating English on a French keyboard layout would otherwise refine every segment.
    public var honorsLanguageHint: Bool

    // MARK: Condition 4 — long segment

    /// Seconds of audio at or above which a segment counts as long.
    ///
    /// **Set by measurement, not taste** — `Tests/AppTests/GateRecallCorpusTests.swift` sweeps this
    /// number over the real-room corpus with real Parakeet and real Qwen output and prints gate
    /// recall and precision at each step. Measured 11 September 2026, 20 utterances:
    ///
    ///     >= 4s   fired 19/20   recall 1.000 (1/1)   precision 0.053   pass-2 made 7 worse
    ///     >= 8s   fired 11/20   recall 1.000 (1/1)   precision 0.091   pass-2 made 4 worse
    ///     >= 10s  fired  6/20   recall 1.000 (1/1)   precision 0.167   pass-2 made 2 worse
    ///     >= 12s  fired  6/20   recall 1.000 (1/1)   precision 0.167   pass-2 made 2 worse
    ///
    /// Recall never moves — the corpus holds no long segments (3.7–9.4 s, one dictated sentence
    /// each), so this condition wins nothing there — while every threshold inside corpus range costs
    /// precision and fires the weaker second model on text that was already right. 12 s is therefore
    /// the smallest duration that is *out of corpus range*: a paragraph rather than a sentence, the
    /// case where pass-1 context is thinnest. Re-measure when the corpus grows a long-form pass; do
    /// not lower it on intuition.
    public var longSegmentSeconds: TimeInterval
    /// Words at or above which a segment counts as long, for producers that report no audio range.
    /// 30 words ≈ two sentences of dictation; the corpus's longest line is 13.
    public var longSegmentWords: Int

    public init(
        lowConfidence: Float = TranscriptSpan.lowConfidenceThreshold,
        treatsUnknownConfidenceAsUncertain: Bool = false,
        minNearMisses: Int = 1,
        nearMissMinSimilarity: Float = 0.55,
        nearMissMinWordCharacters: Int = 4,
        requiresPromptForNearMiss: Bool = true,
        maxNonLatinLetterRatio: Double = 0.15,
        nonLatinMinLetters: Int = 8,
        honorsLanguageHint: Bool = true,
        longSegmentSeconds: TimeInterval = 12,
        longSegmentWords: Int = 30
    ) {
        self.lowConfidence = lowConfidence
        self.treatsUnknownConfidenceAsUncertain = treatsUnknownConfidenceAsUncertain
        self.minNearMisses = minNearMisses
        self.nearMissMinSimilarity = nearMissMinSimilarity
        self.nearMissMinWordCharacters = nearMissMinWordCharacters
        self.requiresPromptForNearMiss = requiresPromptForNearMiss
        self.maxNonLatinLetterRatio = maxNonLatinLetterRatio
        self.nonLatinMinLetters = nonLatinMinLetters
        self.honorsLanguageHint = honorsLanguageHint
        self.longSegmentSeconds = longSegmentSeconds
        self.longSegmentWords = longSegmentWords
    }

    public static let `default` = RefinementGateSettings()

    /// Every condition disabled: `auto` then behaves like `never`. For a Lab arm that wants the
    /// mode paths without the policy.
    public static let noConditions = RefinementGateSettings(
        lowConfidence: -1, minNearMisses: .max, maxNonLatinLetterRatio: 2,
        honorsLanguageHint: false, longSegmentSeconds: .infinity, longSegmentWords: .max
    )
}

/// What the gate was given for one segment. Counts and numbers only — the one string on it is the
/// hypothesis, which is read for its *script* and never stored on the decision (V3 §7.3: a
/// decision can be logged, the text it came from cannot).
public struct RefinementGateSignals: Sendable {
    /// Pass-1 text. Used for word count and script evidence.
    public var hypothesis: String
    /// Pass-1 confidence, or nil when the producer reports none (V3 §5.3).
    public var confidence: Float?
    /// Phonetic near misses between the hypothesis and the ranked context list — the count
    /// `ContextGate` produces in `Engine/Biasing` (this module cannot see `Engine`, and duplicating
    /// double-metaphone here would be a second implementation to keep in step).
    public var nearMisses: Int
    /// Terms the prompt will actually carry (`PromptBuilder.Result.included`).
    public var promptTerms: Int
    /// Seconds of audio in the segment, or nil when unknown.
    public var segmentSeconds: TimeInterval?
    /// BCP-47 tag from the recognizer or the user's dictation locale, or nil when nothing reports
    /// one. `nil` is not evidence of English.
    public var languageHint: String?
    /// False when the second pass cannot run here at all (macOS 14, no weights, flag off). The
    /// Voice tab says so in words rather than offering a mode that does nothing (V3 §9.7).
    public var refinementAvailable: Bool

    public init(
        hypothesis: String,
        confidence: Float? = nil,
        nearMisses: Int = 0,
        promptTerms: Int = 0,
        segmentSeconds: TimeInterval? = nil,
        languageHint: String? = nil,
        refinementAvailable: Bool = true
    ) {
        self.hypothesis = hypothesis
        self.confidence = confidence
        self.nearMisses = nearMisses
        self.promptTerms = promptTerms
        self.segmentSeconds = segmentSeconds
        self.languageHint = languageHint
        self.refinementAvailable = refinementAvailable
    }

    /// The signals a batch of pass-1 spans carries on its own: joined text, mean confidence
    /// weighted by nothing (spans are words or sentences, and a mean is what "the segment was
    /// unsure" means), and the audio span from first lower bound to last upper bound.
    public init(
        spans: [TranscriptSpan],
        nearMisses: Int = 0,
        promptTerms: Int = 0,
        languageHint: String? = nil,
        refinementAvailable: Bool = true
    ) {
        let text = spans.map(\.text).joined(separator: " ")
        let confidence: Float? = spans.isEmpty
            ? nil
            : spans.map(\.confidence).reduce(0, +) / Float(spans.count)
        let seconds: TimeInterval? = spans.isEmpty
            ? nil
            : (spans.map(\.audioRange.upperBound).max() ?? 0)
                - (spans.map(\.audioRange.lowerBound).min() ?? 0)
        self.init(hypothesis: text, confidence: confidence, nearMisses: nearMisses,
                  promptTerms: promptTerms, segmentSeconds: seconds, languageHint: languageHint,
                  refinementAvailable: refinementAvailable)
    }

    /// Words in the hypothesis, counted the way the rest of the code counts them.
    public var wordCount: Int {
        hypothesis.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }
}

/// R5.3 — the four-condition gate, plus the user's Auto / Always / Never choice.
///
/// The two conditions that need the context list (confidence and the phonetic near miss) are
/// *computed* by `ContextGate` in `Engine/Biasing`, which owns the list, the double-metaphone index
/// and the possessive handling. This policy takes their result as a count and adds the two
/// conditions that need no list at all, so that the whole decision — mode, availability, four
/// conditions, thresholds — is one value that `Pipeline` can test and `App` can show.
public struct RefinementGate: Sendable {

    /// Why the gate decided as it did. Ordered as evaluated; the first hit is the primary reason
    /// and the rest are reported alongside it.
    public enum Reason: String, Sendable, Equatable, CaseIterable {
        /// The second pass cannot run on this Mac or is turned off at the flag.
        case unavailable
        /// Settings › Voice is set to Never.
        case modeNever
        /// Settings › Voice is set to Always.
        case modeAlways
        /// Pass-1 confidence at or below `lowConfidence`.
        case lowConfidence
        /// A hypothesis word sounds like a term in the prompt but is not it.
        case contextNearMiss
        /// The hypothesis is not in a Latin script, or the language hint names another language.
        case nonEnglish
        /// Longer than `longSegmentSeconds`, or more words than `longSegmentWords`.
        case longSegment
        /// Auto, and none of the four conditions fired.
        case noConditionMet
    }

    public struct Decision: Sendable, Equatable {
        public var shouldRefine: Bool
        /// The reason that decided it.
        public var reason: Reason
        /// Every condition that fired, in evaluation order. Empty unless `reason` is a condition.
        public var conditions: [Reason]
        public var mode: RefinementMode
        /// Repeated here so a log line stands alone.
        public var confidence: Float?
        public var nearMisses: Int
        public var promptTerms: Int
        public var segmentSeconds: TimeInterval?
        public var words: Int

        /// True when pass-1 reported no confidence at all (V3 §5.3: mark it, never infer it).
        public var confidenceUnavailable: Bool { confidence == nil }

        /// Term-free and text-free: safe to log.
        public var summary: String {
            let conf = confidence.map { String(format: "%.2f", $0) } ?? "n/a"
            let seconds = segmentSeconds.map { String(format: "%.1f", $0) } ?? "n/a"
            let fired = conditions.isEmpty ? "-" : conditions.map(\.rawValue).joined(separator: "+")
            return "refine=\(shouldRefine ? "yes" : "no") mode=\(mode.rawValue) "
                + "reason=\(reason.rawValue) fired=\(fired) conf=\(conf) nearMisses=\(nearMisses) "
                + "terms=\(promptTerms) seconds=\(seconds) words=\(words)"
        }

        /// `StageContext.extra` entry that turns `RefineStage` on or off for this one run, so the
        /// decision reaches the stage through the key the stage already documents.
        public var stageExtra: [String: String] {
            [RefineStage.enabledKey: shouldRefine ? "true" : "false"]
        }
    }

    public var mode: RefinementMode
    public var settings: RefinementGateSettings

    public init(mode: RefinementMode = .auto, settings: RefinementGateSettings = .default) {
        self.mode = mode
        self.settings = settings
    }

    /// Decide for one segment.
    public func decide(_ signals: RefinementGateSignals) -> Decision {
        func decision(_ refine: Bool, _ reason: Reason, _ conditions: [Reason] = []) -> Decision {
            Decision(shouldRefine: refine, reason: reason, conditions: conditions, mode: mode,
                     confidence: signals.confidence, nearMisses: signals.nearMisses,
                     promptTerms: signals.promptTerms, segmentSeconds: signals.segmentSeconds,
                     words: signals.wordCount)
        }
        // Availability first: a mode cannot promise a pass that is not installed (V3 §9.7).
        guard signals.refinementAvailable else { return decision(false, .unavailable) }
        switch mode {
        case .never: return decision(false, .modeNever)
        case .always: return decision(true, .modeAlways)
        case .auto: break
        }
        let fired = conditions(signals)
        guard let first = fired.first else { return decision(false, .noConditionMet) }
        return decision(true, first, fired)
    }

    /// Every condition that fires for these signals, in evaluation order. Public because the
    /// measurement harness reports per-condition counts, and because a test that asserts one
    /// condition in isolation should not have to infer it from `reason`.
    public func conditions(_ signals: RefinementGateSignals) -> [Reason] {
        var fired: [Reason] = []
        if isUncertain(signals) { fired.append(.lowConfidence) }
        if hasContextNearMiss(signals) { fired.append(.contextNearMiss) }
        if isNonEnglish(signals) { fired.append(.nonEnglish) }
        if isLongSegment(signals) { fired.append(.longSegment) }
        return fired
    }

    // MARK: The four conditions

    /// 1 — streaming uncertainty below threshold.
    public func isUncertain(_ signals: RefinementGateSignals) -> Bool {
        guard let confidence = signals.confidence else {
            return settings.treatsUnknownConfidenceAsUncertain
        }
        return confidence <= settings.lowConfidence
    }

    /// 2 — a word that sounds like a context term without being it. The count comes from
    /// `ContextGate`; this is the policy over it.
    public func hasContextNearMiss(_ signals: RefinementGateSignals) -> Bool {
        guard signals.nearMisses >= settings.minNearMisses, settings.minNearMisses > 0 else { return false }
        if settings.requiresPromptForNearMiss, signals.promptTerms <= 0 { return false }
        return true
    }

    /// 3 — non-English.
    ///
    /// Two independent kinds of evidence, and the honest limit of both:
    /// - **A language hint** (recognizer output, or the user's dictation locale) that names
    ///   something other than English. Authoritative when present.
    /// - **Script.** A hypothesis whose letters are mostly outside the Latin scripts is not
    ///   English, whatever anything claims. This is what caught Qwen's Devanagari regression
    ///   (`c6c8887`) and it is cheap and certain.
    ///
    /// What this cannot do: tell Spanish from English. Both are Latin script, and nothing in the
    /// shipping path reports a per-utterance language. So for Latin-script languages the gate is
    /// blind unless a hint is supplied, and that limit is recorded here rather than papered over
    /// with a word-list heuristic that would misfire on English names.
    public func isNonEnglish(_ signals: RefinementGateSignals) -> Bool {
        if settings.honorsLanguageHint, let hint = signals.languageHint, !Self.hintIsEnglish(hint) {
            return true
        }
        let (letters, nonLatin) = Self.letterCounts(signals.hypothesis)
        guard letters >= settings.nonLatinMinLetters else { return false }
        return Double(nonLatin) / Double(letters) > settings.maxNonLatinLetterRatio
    }

    /// 4 — long segment: more audio, or more words, than pass-1 context comfortably covers.
    public func isLongSegment(_ signals: RefinementGateSignals) -> Bool {
        if let seconds = signals.segmentSeconds, seconds >= settings.longSegmentSeconds { return true }
        return signals.wordCount >= settings.longSegmentWords
    }

    // MARK: Script and language helpers

    /// True when the tag's primary subtag is English ("en", "en-IN", "En_us").
    public static func hintIsEnglish(_ tag: String) -> Bool {
        let primary = tag.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? ""
        return primary == "en" || primary == "eng"
    }

    /// (letters, letters outside the Latin scripts). Latin here is ASCII plus Latin-1 Supplement,
    /// Latin Extended-A and -B (U+00C0…U+024F) — enough for every language written in a Latin
    /// alphabet, and it excludes Devanagari, CJK, Cyrillic, Arabic and the rest.
    public static func letterCounts(_ text: String) -> (letters: Int, nonLatin: Int) {
        var letters = 0, nonLatin = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            letters += 1
            let value = scalar.value
            let isLatin = (value < 0x80) || (value >= 0xC0 && value <= 0x24F)
            if !isLatin { nonLatin += 1 }
        }
        return (letters, nonLatin)
    }
}
