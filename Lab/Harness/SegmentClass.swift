// VoicePlus original (task R5.4). Segment classes for the refinement benchmark.
import Foundation

/// One axis value a scored utterance can belong to (R5.4, V3 §10.1).
///
/// R5.3 measured the corpus **mean** WER of both passes and that number decided the flag. R5.4 owes
/// the breakdown behind it, because a mean can hide a class: a second pass may lose overall and
/// still win on, say, number-heavy or disfluent speech, and the honest answer then is a *narrowed*
/// gate rather than a dead flag. These are the classes, and every one of them is derived from the
/// reference transcript and the segment duration — never from either pass's output, so no arm can
/// influence which class it is judged in.
///
/// The axes are the ones V3 §10.1 names for accuracy evidence ("names, numbers, real room") plus
/// duration, which is the only continuous property this corpus varies (3.7–9.4 s).
///
/// A segment belongs to **several** classes at once (a long sentence with a name and a digit is in
/// all three). The classes are therefore reported as overlapping buckets with their own `n`, not as
/// a partition — and on a twenty-utterance corpus most of them hold a handful of segments. Every
/// table that prints them prints `n` beside them for that reason.
public enum SegmentClass: String, CaseIterable, Codable, Sendable, Identifiable {

    // MARK: Duration (a partition — exactly one of these per segment)

    /// Shorter than `SegmentClassRules.shortBelowSeconds`. A phrase.
    case durationShort
    /// Between the two duration thresholds. One ordinary dictated sentence.
    case durationMedium
    /// At or above `SegmentClassRules.longAtOrAboveSeconds`. The longest speech this corpus has —
    /// note that it is still nowhere near the `longSegmentSeconds` (12 s) the gate calls "long".
    case durationLong

    // MARK: Content

    /// The reference carries at least one entity by `EntityScorer.detectEntities` — a name, a place,
    /// a product, an acronym. The class a context-primed second pass exists to win.
    case entities
    /// The reference carries none. "Clean speech" for the purposes of R5's no-regression condition.
    case noEntities
    /// The reference contains a decimal digit: a time, a money amount, a postcode. Tests number
    /// *formatting* as well as recognition.
    case writtenDigits
    /// The reference spells a quantity in words ("six", "two", "three"). A recognizer that helpfully
    /// digitises these is scored as wrong here, which is the point: the reference is verbatim.
    case spokenNumbers
    /// The reference contains a hesitation token (um, uh, …). Verbatim transcription is required, so
    /// a pass that tidies the disfluency away is penalised — the class where a fluent language model
    /// is most likely to "improve" the text into an error.
    case disfluency
    /// The reference marks an explicit mid-sentence pause ("…"). Endpointing pressure rather than
    /// vocabulary.
    case explicitPause
    /// Code or terminal vocabulary (`SegmentClassRules.technicalTerms`). **Hand-labelled axis**: the
    /// term list is written out in the rules and matched whole-word, so which utterances land here is
    /// auditable, but it is a list chosen by a human and not a property of the audio.
    case technical

    public var id: String { rawValue }

    /// Short label for a table column.
    public var label: String {
        switch self {
        case .durationShort: return "< 5 s"
        case .durationMedium: return "5–7 s"
        case .durationLong: return "≥ 7 s"
        case .entities: return "entities"
        case .noEntities: return "no entities"
        case .writtenDigits: return "digits"
        case .spokenNumbers: return "number words"
        case .disfluency: return "disfluency"
        case .explicitPause: return "explicit pause"
        case .technical: return "technical"
        }
    }

    /// One line saying what it means, for the report header.
    public var explanation: String {
        switch self {
        case .durationShort: return "segment shorter than the short/medium threshold"
        case .durationMedium: return "segment between the two duration thresholds"
        case .durationLong: return "segment at or above the long threshold"
        case .entities: return "reference has ≥ 1 entity by EntityScorer.detectEntities"
        case .noEntities: return "reference has no detected entity"
        case .writtenDigits: return "reference contains a decimal digit"
        case .spokenNumbers: return "reference spells a quantity in words"
        case .disfluency: return "reference contains a hesitation token"
        case .explicitPause: return "reference marks a mid-sentence pause"
        case .technical: return "reference uses code or terminal vocabulary (hand-labelled list)"
        }
    }

    /// The duration axis, in order. Exactly one of these holds any segment whose duration is known.
    public static let durationAxis: [SegmentClass] = [.durationShort, .durationMedium, .durationLong]
    /// The content axes, in reporting order.
    public static let contentAxis: [SegmentClass] = [
        .entities, .noEntities, .writtenDigits, .spokenNumbers, .disfluency, .explicitPause, .technical,
    ]
    /// Every class in reporting order.
    public static let reportingOrder: [SegmentClass] = durationAxis + contentAxis
}

/// Every threshold and word list the classifier uses, so none of them is written at a call site and
/// all of them are visible in one place when a table is read.
public struct SegmentClassRules: Sendable, Equatable {

    /// Below this many seconds a segment is `durationShort`.
    ///
    /// 5 s and 7 s split the real-room corpus (3.7–9.4 s) into three non-empty thirds. They are
    /// **corpus-fitted boundaries**, not product thresholds: a reader must not read `≥ 7 s` here as
    /// "long-form speech" — the gate's own `longSegmentSeconds` is 12 s and no utterance here
    /// reaches it. Re-cut them when the corpus grows a long-form pass.
    public var shortBelowSeconds: TimeInterval
    /// At or above this many seconds a segment is `durationLong`.
    public var longAtOrAboveSeconds: TimeInterval

    /// Hesitation tokens, matched as whole normalised words.
    public var disfluencies: Set<String>
    /// Quantity words, matched as whole normalised words. Ordinals and "a"/"an" are deliberately out:
    /// "a table" is not a number and "first" is not a count.
    public var numberWords: Set<String>
    /// Code and terminal vocabulary, matched as whole normalised words. The hand-labelled axis.
    public var technicalTerms: Set<String>
    /// Substrings that mark an explicit mid-sentence pause in a verbatim reference.
    public var pauseMarkers: [String]

    public init(
        shortBelowSeconds: TimeInterval = 5,
        longAtOrAboveSeconds: TimeInterval = 7,
        disfluencies: Set<String> = ["um", "uh", "erm", "er", "hmm", "mm", "mhm", "ah", "eh"],
        numberWords: Set<String> = [
            "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
            "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen",
            "nineteen", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
            "hundred", "thousand", "million", "dozen",
        ],
        technicalTerms: Set<String> = [
            "branch", "build", "commit", "compile", "config", "debug", "endpoint", "function", "git",
            "grep", "json", "kubectl", "merge", "npm", "path", "push", "rebase", "repo", "scratch",
            "script", "sudo", "swift", "terminal", "token", "variable", "zsh",
        ],
        pauseMarkers: [String] = ["...", "…", "--", "—"]
    ) {
        self.shortBelowSeconds = shortBelowSeconds
        self.longAtOrAboveSeconds = longAtOrAboveSeconds
        self.disfluencies = disfluencies
        self.numberWords = numberWords
        self.technicalTerms = technicalTerms
        self.pauseMarkers = pauseMarkers
    }

    public static let `default` = SegmentClassRules()
}

/// Turns a reference transcript (+ duration, when known) into the set of classes it belongs to.
///
/// Deterministic, reference-only, and never shown either pass's output — the guarantee that makes a
/// per-class table meaningful rather than a post-hoc grouping of wins.
public struct SegmentClassifier: Sendable {
    public var rules: SegmentClassRules

    public init(rules: SegmentClassRules = .default) { self.rules = rules }

    /// The duration class, or nil when no duration is known (a manifest-only fixture).
    public func durationClass(seconds: TimeInterval?) -> SegmentClass? {
        guard let seconds else { return nil }
        if seconds < rules.shortBelowSeconds { return .durationShort }
        if seconds >= rules.longAtOrAboveSeconds { return .durationLong }
        return .durationMedium
    }

    /// Every class this segment belongs to.
    public func classify(reference: String, seconds: TimeInterval? = nil) -> Set<SegmentClass> {
        var out: Set<SegmentClass> = []
        if let duration = durationClass(seconds: seconds) { out.insert(duration) }

        let words = Set(TextNormalizer.words(reference))
        out.insert(EntityScorer.detectEntities(in: reference).isEmpty ? .noEntities : .entities)
        if reference.contains(where: \.isNumber) { out.insert(.writtenDigits) }
        if !words.isDisjoint(with: rules.numberWords) { out.insert(.spokenNumbers) }
        if !words.isDisjoint(with: rules.disfluencies) { out.insert(.disfluency) }
        if rules.pauseMarkers.contains(where: reference.contains) { out.insert(.explicitPause) }
        if !words.isDisjoint(with: rules.technicalTerms) { out.insert(.technical) }
        return out
    }
}
