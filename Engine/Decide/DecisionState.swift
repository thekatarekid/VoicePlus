import Foundation
import Shared

// V5 O5 · the context passed on every Layer 1 call.
//
// The decision models read one plain-text "state" plus the questions. The state carries what the app
// knows at the end of an utterance: frontmost app, field role, whether a text field is focused, whether
// a meeting is recording, the last three utterances *with their decisions* (the continuation question
// needs history), whether another voice was heard in the last 10 s, lip activity and a prosody summary.
//
// Capped at 384 tokens — Kev's state bucket (`KevManager.evaluationMaxStateTokens`). Kev truncates on
// its own, but it truncates the *tail*, which is the utterance being decided; this renderer instead
// drops the oldest history first, then shortens the utterance, so the cap never costs the words that
// matter most.

/// One earlier utterance and what it was decided to be.
public struct DecisionHistoryItem: Equatable, Sendable {
    public var text: String
    public var owner: UtteranceOwner
    public init(text: String, owner: UtteranceOwner) { self.text = text; self.owner = owner }
}

/// A prosody summary (from `DirectedSpeechFeatures`) in words the model can read.
public struct ProsodySummary: Equatable, Sendable {
    /// Speech level over the noise floor (dB).
    public var snrDB: Double
    /// Energy rising (+) or falling (−) across the utterance.
    public var energySlope: Double
    /// Energy onsets per second.
    public var speakingRate: Double

    public init(snrDB: Double, energySlope: Double, speakingRate: Double) {
        self.snrDB = snrDB; self.energySlope = energySlope; self.speakingRate = speakingRate
    }

    /// From the directed-speech feature vector (which stores unit-scaled values).
    public init(features f: DirectedSpeechFeatures) {
        self.init(snrDB: f.snrDB * 20, energySlope: f.energyContourSlope, speakingRate: f.speakingRate * 5)
    }

    public var phrase: String {
        let level = snrDB >= 20 ? "close and clear" : snrDB >= 10 ? "moderate" : "distant or quiet"
        let contour = energySlope > 0.05 ? "rising" : energySlope < -0.05 ? "falling" : "flat"
        let pace = speakingRate >= 4 ? "fast" : speakingRate >= 2 ? "normal" : "slow"
        return "\(level), \(contour) energy, \(pace) pace"
    }
}

/// O5 — everything a decision model sees about one utterance.
public struct DecisionState: Equatable, Sendable {
    /// The utterance being decided.
    public var utterance: String
    public var frontmostApp: String?
    /// `FieldRole` raw value (Pipeline owns the enum; Engine sees the string).
    public var fieldRole: String?
    public var textFieldFocused: Bool
    public var meetingActive: Bool
    /// Oldest first; only the last `historyLimit` are rendered.
    public var history: [DecisionHistoryItem]
    /// Another (non-user) voice heard in the last 10 s.
    public var otherVoiceRecently: Bool
    /// Lip activity 0…1 while speaking (LR); nil when the camera is off.
    public var lipActivity: Double?
    public var prosody: ProsodySummary?

    public static let historyLimit = 3

    public init(utterance: String, frontmostApp: String? = nil, fieldRole: String? = nil,
                textFieldFocused: Bool = false, meetingActive: Bool = false,
                history: [DecisionHistoryItem] = [], otherVoiceRecently: Bool = false,
                lipActivity: Double? = nil, prosody: ProsodySummary? = nil) {
        self.utterance = utterance; self.frontmostApp = frontmostApp; self.fieldRole = fieldRole
        self.textFieldFocused = textFieldFocused; self.meetingActive = meetingActive
        self.history = history; self.otherVoiceRecently = otherVoiceRecently
        self.lipActivity = lipActivity; self.prosody = prosody
    }
}

/// Renders a `DecisionState` to the model's state string under a token cap.
public struct DecisionStateRenderer: Sendable {
    /// Kev's state bucket.
    public static let defaultMaxTokens = 384

    public var maxTokens: Int
    /// Token counter. The default over-estimates a Qwen BPE count (≈ 3 UTF-8 bytes per token, English
    /// averages ≈ 4), so a string that fits here fits the real tokenizer.
    public var tokenCount: @Sendable (String) -> Int

    public init(maxTokens: Int = DecisionStateRenderer.defaultMaxTokens,
                tokenCount: @escaping @Sendable (String) -> Int = DecisionStateRenderer.estimateTokens) {
        self.maxTokens = maxTokens
        self.tokenCount = tokenCount
    }

    public static func estimateTokens(_ s: String) -> Int {
        (s.utf8.count + 2) / 3
    }

    public func render(_ state: DecisionState) -> String {
        var history = Array(state.history.suffix(DecisionState.historyLimit))
        var utterance = state.utterance
        func compose() -> String { Self.compose(state, history: history, utterance: utterance) }
        var text = compose()
        // 1. Drop the oldest history.
        while tokenCount(text) > maxTokens, !history.isEmpty {
            history.removeFirst()
            text = compose()
        }
        // 2. Shorten the utterance from the end, a word at a time (keep its opening: it carries the
        //    address form / leading verb).
        var words = utterance.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        while tokenCount(text) > maxTokens, words.count > 1 {
            words.removeLast()
            utterance = words.joined(separator: " ") + " …"
            text = compose()
        }
        // 3. Last resort: hard cut on characters (a single enormous token-free word).
        while tokenCount(text) > maxTokens, !text.isEmpty {
            text.removeLast(max(1, text.count / 10))
        }
        return text
    }

    static func compose(_ s: DecisionState, history: [DecisionHistoryItem], utterance: String) -> String {
        var lines: [String] = []
        lines.append("app: \(s.frontmostApp ?? "unknown")")
        lines.append("field: \(s.textFieldFocused ? (s.fieldRole ?? "text field") + " focused" : "no text field focused")")
        lines.append("meeting recording: \(s.meetingActive ? "yes" : "no")")
        lines.append("another voice in the last 10 s: \(s.otherVoiceRecently ? "yes" : "no")")
        if let lip = s.lipActivity { lines.append("lips moving: \(lip >= 0.5 ? "yes" : "no")") }
        if let p = s.prosody { lines.append("voice: \(p.phrase)") }
        if history.isEmpty {
            lines.append("earlier: none")
        } else {
            lines.append("earlier (oldest first):")
            for h in history { lines.append("- [\(h.owner.rawValue)] \(h.text)") }
        }
        lines.append("latest utterance: \(utterance)")
        return lines.joined(separator: "\n")
    }
}
