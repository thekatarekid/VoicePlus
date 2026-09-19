import Foundation
import Shared

// MARK: - The practice turn (design §8.7: hold → live words → release → final preview → insertion)

/// What one real hold does, as the Try step sees it. Pure: it is fed the engine's own events (the
/// hold runs through the app's real turn path — pill, dwell, lander) and the practice field's text,
/// and never invents a stage it did not observe. "Inserted" means the field really gained text.
public struct PracticeSession: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// Nothing held yet (or the last turn is over and the field is waiting for another).
        case waiting
        /// The key is held and the microphone is open: live words, counterclockwise reels.
        case listening
        /// Released; the final pass is running.
        case finishing
        /// The final payload is in. It is shown in the pill for the dwell before it lands.
        case preview
        /// The practice field gained the text.
        case inserted
        /// The final never reached the field within `insertionGrace` (held, or focus moved).
        case notInserted
        /// Escape (or a cancel) ended the turn before anything was written.
        case cancelled
        /// The turn produced no words.
        case noSpeech
        case failed(String)

        /// True while the real test is running — the only time Spool may move in this window.
        public var isLive: Bool {
            switch self {
            case .listening, .finishing, .preview: return true
            default: return false
            }
        }
    }

    /// How long the final may take to land after it is published: the longest automatic dwell
    /// (1.8 s for a low-confidence turn) plus the write, with room to spare. A manual dwell simply
    /// lands later, which still upgrades `.notInserted` to `.inserted`.
    public static let insertionGrace: TimeInterval = 6

    public private(set) var phase: Phase = .waiting
    /// When `phase` last changed — Spool's `stateStartedAt`.
    public private(set) var phaseStartedAt: Date
    /// The live words (cumulative preview) of the turn in progress.
    public private(set) var liveText = ""
    /// Capture level of the turn in progress, 0…1.
    public private(set) var level: Float = 0
    /// The final spans of the last turn, confidence and alternates intact.
    public private(set) var finalSpans: [TranscriptSpan] = []
    /// What the practice field holds right now.
    public private(set) var fieldText = ""
    /// What the field gained from the last turn.
    public private(set) var insertedText: String?
    /// Turns completed into the field since the step opened.
    public private(set) var insertions = 0

    public init(now: Date = Date()) { phaseStartedAt = now }

    public var finalText: String { finalSpans.renderedText.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Feeds one engine event. Returns true when the phase changed.
    @discardableResult
    public mutating func apply(_ event: EngineEvent, now: Date = Date()) -> Bool {
        let before = phase
        switch event {
        case .state(let state):
            switch state {
            case .starting, .prewarming:
                beginTurnIfIdle(now: now)
            case .listening(let l):
                beginTurnIfIdle(now: now)
                level = l
            case .previewing(let text):
                if phase == .listening { liveText = text }
            case .finishing, .finalizing:
                if phase == .listening { move(to: .finishing, now: now); level = 0 }
            case .cancelled:
                if phase == .listening || phase == .finishing || phase == .preview { move(to: .cancelled, now: now); level = 0 }
            case .error(let message):
                if phase == .listening || phase == .finishing { move(to: .failed(message), now: now); level = 0 }
            case .unavailable(let reason):
                if phase == .listening || phase == .finishing { move(to: .failed(reason), now: now); level = 0 }
            case .idle, .landed, .warning:
                break
            }
        case .partial(let spans):
            beginTurnIfIdle(now: now)
            if phase == .listening { liveText = spans.renderedText }
        case .final(let spans):
            guard phase == .listening || phase == .finishing else { break }
            level = 0
            finalSpans = spans
            move(to: finalText.isEmpty ? .noSpeech : .preview, now: now)
        case .micQuality:
            break
        }
        return phase != before
    }

    /// The practice field changed. Text arriving while a turn is finishing or showing its preview
    /// (or after it was reported as not inserted) is that turn landing.
    @discardableResult
    public mutating func fieldChanged(_ text: String, now: Date = Date()) -> Bool {
        let old = fieldText
        fieldText = text
        guard text.count > old.count else { return false }
        switch phase {
        case .finishing, .preview, .notInserted:
            let gained = text.hasPrefix(old) ? String(text.dropFirst(old.count)) : text
            let trimmed = gained.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            insertedText = trimmed
            insertions += 1
            move(to: .inserted, now: now)
            return true
        default:
            return false
        }
    }

    /// `insertionGrace` elapsed after the final was published.
    @discardableResult
    public mutating func insertionTimedOut(now: Date = Date()) -> Bool {
        guard phase == .preview else { return false }
        move(to: .notInserted, now: now)
        return true
    }

    /// Clears a correction's replacement into the model without counting it as a new landing.
    public mutating func replaceField(with text: String) { fieldText = text }

    private mutating func beginTurnIfIdle(now: Date) {
        guard phase != .listening, phase != .finishing else { return }
        liveText = ""
        level = 0
        finalSpans = []
        insertedText = nil
        move(to: .listening, now: now)
    }

    private mutating func move(to next: Phase, now: Date) {
        guard next != phase else { return }
        phase = next
        phaseStartedAt = now
    }
}

// MARK: - One uncertain word, demonstrated and corrected (design §7, §8.7)

/// The Try step's word review. Uses the user's own dictation when its final payload really carries
/// an uncertain word with at least one alternative that landed in the practice field; otherwise the
/// prototype's own example, labelled "Example" — a word in the user's text is never marked
/// uncertain when the recogniser was not.
///
/// Copy is the prototype's Word review dialog (`#reviewDialog`), verbatim.
public struct UncertainWordReview: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// A low-confidence word from the user's own dictation, landed in the practice field.
        case dictation
        /// The prototype's sample sentence.
        case example
    }

    public let source: Source
    /// The sentence as it currently reads (updated by a correction).
    public private(set) var sentence: String
    /// The uncertain word as dictated.
    public let word: String
    /// Credible alternatives, best first, at most three (design §8.8).
    public let suggestions: [String]
    /// Character offset of `word` inside `sentence`.
    public let offset: Int
    /// The spelling the user settled on; nil while the word is still marked.
    public private(set) var chosen: String?

    public static let maxSuggestions = 3

    // MARK: Prototype copy (#reviewDialog)
    public static let eyebrow = "Word review"
    public static let customLabel = "Or enter a spelling"
    public static let customPlaceholder = "Your spelling"
    public static let applyTitle = "Use spelling"
    public static let cancelTitle = "Cancel"
    public var title: String { "Did you mean “\(suggestions.first ?? word)”?" }
    public var body: String { "“\(word)” was uncertain. Choose a spelling or keep what you said." }
    public var keepTitle: String { "\(word) · keep" }
    /// The prototype's `aria-label` on the dotted word.
    public var reviewLabel: String { "Review uncertain word \(word)" }

    /// The prototype's sample: "Mira" was uncertain; "Meera" is the suggestion.
    public static let example = UncertainWordReview(source: .example, sentence: "Can we meet with Mira on Friday?",
                                                    word: "Mira", suggestions: ["Meera"], offset: 17)

    public var isResolved: Bool { chosen != nil }
    /// The word as it reads now.
    public var currentWord: String { chosen ?? word }

    init(source: Source, sentence: String, word: String, suggestions: [String], offset: Int) {
        self.source = source
        self.sentence = sentence
        self.word = word
        self.suggestions = Array(suggestions.prefix(Self.maxSuggestions))
        self.offset = offset
    }

    /// The review for a landed turn: the first low-confidence span with an alternative whose word
    /// is found in the landed text, else the example.
    public static func make(spans: [TranscriptSpan], landed: String?) -> UncertainWordReview {
        guard let landed, !landed.isEmpty else { return example }
        let trim = CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines)
        for span in spans where span.isLowConfidence {
            let word = span.text.trimmingCharacters(in: trim)
            guard !word.isEmpty else { continue }
            var seen = Set([word.lowercased()])
            let suggestions = span.alternates.map { $0.text.trimmingCharacters(in: trim) }
                .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            guard !suggestions.isEmpty,
                  let range = landed.range(of: word) ?? landed.range(of: word, options: .caseInsensitive) else { continue }
            let found = String(landed[range])
            return UncertainWordReview(source: .dictation, sentence: landed, word: found, suggestions: suggestions,
                                       offset: landed.distance(from: landed.startIndex, to: range.lowerBound))
        }
        return example
    }

    /// The word's range in `sentence` as it reads now.
    public var currentRange: Range<String.Index>? {
        guard offset >= 0, offset + currentWord.count <= sentence.count else { return nil }
        let start = sentence.index(sentence.startIndex, offsetBy: offset)
        let end = sentence.index(start, offsetBy: currentWord.count)
        return sentence[start..<end] == currentWord ? start..<end : nil
    }

    /// Settles the word. For the user's own dictation the practice field is corrected too, and only
    /// while the landed sentence is still there unchanged (a verified range — design §7); returns
    /// the corrected field text, or nil when the field no longer holds the sentence (nothing is
    /// replaced then). For the example the sentence alone changes and `field` is returned as is.
    public mutating func choose(_ spelling: String, field: String) -> String? {
        let spelling = spelling.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spelling.isEmpty, !isResolved, let wordRange = currentRange else { return nil }
        var corrected = sentence
        corrected.replaceSubrange(wordRange, with: spelling)
        switch source {
        case .example:
            sentence = corrected
            chosen = spelling
            return field
        case .dictation:
            guard let at = field.range(of: sentence) else { return nil }
            var newField = field
            newField.replaceSubrange(at, with: corrected)
            sentence = corrected
            chosen = spelling
            return newField
        }
    }

    /// "Keep": the word stays as dictated and loses its mark.
    public mutating func keep() {
        guard !isResolved else { return }
        chosen = word
    }
}
