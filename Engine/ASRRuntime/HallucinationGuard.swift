import Foundation
import Shared

/// V4.22 — the last check before a final pass's text is committed: was it actually said?
///
/// Every transducer/CTC decoder turns room tone into its training set's most common closers —
/// "you", "Thank you.", "Bye." — and a decoder that has lost its place loops on one token. Before
/// this guard the only thing standing between those and the user's document was
/// `UtteranceLander` rejecting the empty string (V4 §7).
///
/// Pure: the verdict depends only on its arguments, so the whole rule table is a unit test.
/// `RealEngine` applies it to the final pass's output (pass 1 — refinement reports no confidence of
/// its own) and turns a drop into *no* text, never different text.
public enum HallucinationGuard {
    /// Which rule dropped the text. The raw value is what logs and diagnostics carry.
    public enum Reason: String, Codable, Sendable, Equatable, CaseIterable {
        /// Speech made up less than 20 % of the audio and the whole text is a known room-tone filler.
        case fillerWithoutSpeech
        /// One token repeated four or more times in a row: the decoder looping.
        case repeatedToken
        /// Mean word confidence under 0.3 over less than a second of speech.
        case lowConfidenceShortSpeech
    }

    public enum Verdict: Equatable, Sendable {
        case keep
        case drop(Reason)

        public var isDrop: Bool { if case .drop = self { return true } else { return false } }
        public var reason: Reason? { if case .drop(let r) = self { return r } else { return nil } }
    }

    /// Whole-utterance texts a decoder produces from silence. Compared after `normalize(_:)`.
    public static let fillerPhrases: Set<String> = [
        "you", "thank you", "thanks for watching", "bye", "the end", "subtitles by", "okay",
    ]
    /// Below this speech ratio (VAD speech ÷ audio), a filler text is taken as invented.
    public static let fillerSpeechRatio: Double = 0.2
    /// A run of this many identical consecutive tokens is a loop, not speech.
    public static let repeatRun = 4
    /// Below this mean confidence, with less than `shortSpeechSeconds` of speech, the text goes.
    public static let lowMeanConfidence: Double = 0.3
    public static let shortSpeechSeconds: Double = 1.0

    /// The verdict. Rules are checked in the order listed in `Reason`; the first that matches wins.
    ///
    /// - Parameters:
    ///   - text: the final pass's text for one segment.
    ///   - speechRatio: VAD speech seconds ÷ audio seconds for that segment (1 when unknown).
    ///   - speechSeconds: VAD speech seconds for that segment (the audio length when unknown).
    ///   - meanConfidence: mean word confidence of the final pass (1 when unknown).
    ///   - tokens: the words of `text`; normalised here, so raw words are fine.
    public static func verdict(
        text: String,
        speechRatio: Double,
        speechSeconds: Double,
        meanConfidence: Double,
        tokens: [String]
    ) -> Verdict {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return .keep }
        if speechRatio < fillerSpeechRatio, fillerPhrases.contains(normalized) {
            return .drop(.fillerWithoutSpeech)
        }
        if longestRun(of: tokens) >= repeatRun { return .drop(.repeatedToken) }
        if meanConfidence < lowMeanConfidence, speechSeconds < shortSpeechSeconds {
            return .drop(.lowConfidenceShortSpeech)
        }
        return .keep
    }

    /// Verdict for a segment's spans, given what the VAD measured for it.
    ///
    /// `speechSeconds == nil` means no VAD fed the engine. Then nothing is known about speech, so
    /// the ratio is taken as 1 (the filler rule cannot fire on a guess) and speech is bounded by the
    /// audio length — which is exact for the confidence rule's "less than a second" test.
    /// Refined spans (`StageID.refineQwen3`) report no confidence and are left out of the mean.
    public static func verdict(for spans: [TranscriptSpan], speechSeconds: Double?, audioSeconds: Double) -> Verdict {
        let text = spans.renderedText
        let ratio: Double
        if let speechSeconds, audioSeconds > 0 { ratio = min(1, speechSeconds / audioSeconds) } else { ratio = 1 }
        return verdict(text: text,
                       speechRatio: ratio,
                       speechSeconds: speechSeconds ?? audioSeconds,
                       meanConfidence: meanConfidence(of: spans),
                       tokens: tokens(of: text))
    }

    /// Lowercased, punctuation folded to spaces, whitespace collapsed. "Thank you." → "thank you".
    public static func normalize(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else if scalar == "'" || scalar == "\u{2019}" {
                out.unicodeScalars.append("'")
            } else {
                out.append(" ")
            }
        }
        return out.split(separator: " ")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Whitespace-separated words of `text` (not yet normalised).
    public static func tokens(of text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// Longest run of equal consecutive tokens, compared after normalisation. Tokens that
    /// normalise to nothing (bare punctuation) are skipped rather than breaking a run.
    public static func longestRun(of tokens: [String]) -> Int {
        var best = 0, run = 0
        var previous: String?
        for token in tokens {
            let word = normalize(token)
            guard !word.isEmpty else { continue }
            run = (word == previous) ? run + 1 : 1
            previous = word
            best = max(best, run)
        }
        return best
    }

    /// Mean confidence of the spans that carry one. 1 when none do (unknown never drops).
    public static func meanConfidence(of spans: [TranscriptSpan]) -> Double {
        let scored = spans.filter {
            !$0.provenance.contains(.refineQwen3)
                && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !scored.isEmpty else { return 1 }
        return scored.reduce(0.0) { $0 + Double($1.confidence) } / Double(scored.count)
    }
}

/// What the speech guards threw away (V4.21 no-speech gate, V4.22 hallucination guard), kept in
/// memory for Diagnostics and tests. Never persisted, and never holds the dropped text: a drop is
/// recorded by its utterance stamp, segment, rule and sizes, which is what the corpus needs to
/// find the recording again.
public final class EngineDiagnostics: @unchecked Sendable {
    public enum DropKind: Equatable, Sendable {
        /// The VAD heard less speech than the gate needs; the final pass was never run.
        case noSpeech
        /// The final pass ran and the guard dropped its text.
        case hallucination(HallucinationGuard.Reason)
    }

    public struct Drop: Equatable, Sendable {
        /// When capture for the segment closed, in the utterance recorder's stamp format
        /// (`yyyy-MM-dd-HHmmss-SSS`). With recordings on, the recording that the same key release
        /// wrote carries the nearest stamp at or before this one.
        public var stamp: String
        public var segment: SegmentID?
        public var kind: DropKind
        public var speechSeconds: Double?
        public var audioSeconds: Double
        public var tokenCount: Int
    }

    /// Most recent drops kept for inspection.
    public static let recentLimit = 50

    private let lock = NSLock()
    private var noSpeech = 0
    private var byReason: [HallucinationGuard.Reason: Int] = [:]
    private var recent: [Drop] = []

    public init() {}

    /// Segments the no-speech gate kept away from the decoder.
    public var noSpeechSkips: Int { lock.withLock { noSpeech } }
    /// Final-pass results the hallucination guard dropped, all rules together.
    public var hallucinationDrops: Int { lock.withLock { byReason.values.reduce(0, +) } }
    public func hallucinationDrops(_ reason: HallucinationGuard.Reason) -> Int { lock.withLock { byReason[reason] ?? 0 } }
    public var recentDrops: [Drop] { lock.withLock { recent } }

    func record(_ drop: Drop) {
        lock.withLock {
            switch drop.kind {
            case .noSpeech: noSpeech += 1
            case .hallucination(let reason): byReason[reason, default: 0] += 1
            }
            recent.append(drop)
            if recent.count > Self.recentLimit { recent.removeFirst(recent.count - Self.recentLimit) }
        }
    }

    static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss-SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    static func stamp(_ date: Date) -> String { stampFormatter.string(from: date) }
}
