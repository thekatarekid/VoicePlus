import Foundation
import Shared

/// The five pill states from the Build doc (T2) plus `hidden` for "retracted", and (G0.4) every
/// state of the verified Spool design's inventory (design_v1 §6).
public enum PillState: Equatable, Sendable {
    case hidden
    case idle
    case listening(level: Float)
    case preview(text: String)
    case landing
    /// R2.4 — the delivery actually happened: the pill drops the preview and shows the *committed*
    /// text for a beat (V3 §4.1, §14.1). `verified: false` draws the "Landed · not confirmed"
    /// variant instead of claiming a success readback could not confirm (V3 §6).
    case landed(LandedPillInfo)
    /// R2.4 — committed text with no safe destination: the destination is named and the row offers
    /// Insert here / Copy / Discard. The only other state in which the pill accepts clicks.
    case held(HeldPillInfo)
    case warning(MicQuality)
    /// Nothing on this machine can recognise speech. Its own case so the honest "no recognizer"
    /// notice can never be confused with — or substituted for — transcript text in `.preview`.
    case unavailable(reason: String)
    /// S5b — something went wrong in this turn. Its own case rather than `.preview("⚠︎ …")`: a
    /// notice the user must read is not transcript text, it must be *sized* like a notice, and
    /// `PillDwell` has to be able to tell the two apart to keep it on screen long enough to read.
    case error(message: String)
    /// P2.3 — "talk to your text": tinted pill, "editing N words", then the 5 s ghost / 8 s warm window.
    case transform(TransformPillInfo)

    // MARK: V4 / Spool states (G0.4, design_v1 §6). Additive: every case above keeps its meaning.

    /// I1 — pointer hover over the idle chin. `hint` is already rendered with the *configured* key
    /// (`PillState.readyHint(key:latchEnabled:)`), never a hard-coded "Right Control".
    case ready(hint: String)
    /// I2 — hard mute: microphone closed, no readiness claim. Leaves only on an explicit Unmute.
    case muted
    /// C0 — key down, microphone not open yet. "Listening" is not claimed until capture is.
    case starting
    /// C2 — capture still open but quiet (VAD idle longer than `quietAfter`). The label says so.
    case listeningQuiet
    /// C3 — double-tap latch, with the design's timer only (the V4.38 countdown ring is withdrawn).
    case latched(elapsed: TimeInterval)
    /// C4 — cancelled before any write began (Escape, a too-short tap). Nothing was inserted.
    case cancelled
    /// F0 — microphone closed, final pass running, nothing written yet. `elapsedWarning` is set once
    /// `finishingWarningDelay` has passed and swaps the status for "Still finishing your text".
    case finishing(elapsedWarning: Bool)
    /// F1 / F2 — the immutable final payload, shown for its dwell before the one insertion.
    case finalPreview(FinalPreviewInfo)
    /// D0 — the single insertion attempt of the previewed payload is in flight. No success cue yet.
    case inserting(text: String)
    /// D3 — the `.landed` family's third outcome (`LandedOutcome.partial`): only part of `text` may
    /// have been inserted. The payload is never depicted as lost; the user reviews both versions.
    /// Its own case because `LandedPillInfo.verified` is a two-way flag; build it with
    /// `PillState.landed(text:outcome:)`.
    case landedPartial(text: String)
    /// R0 — the correction popover owns alternatives and focus.
    case correcting
    /// R1 — a selection is being rewritten; microphone closed, original text unchanged.
    case editing
    /// R2 — an edit landed and a safe Undo is still possible.
    case undoAvailable
    /// Q0 / Q1 / Q2 — meeting capture, paused, or preparing notes. Separate from dictation.
    case meeting(MeetingPillInfo)

    public var isVisible: Bool { self != .hidden }

    public var caseName: String {
        switch self {
        case .hidden: return "hidden"
        case .idle: return "idle"
        case .listening: return "listening"
        case .preview: return "preview"
        case .landing: return "landing"
        case .landed(let info): return info.verified ? "landed" : "landedUnverified"
        case .held: return "held"
        case .warning: return "warning"
        case .unavailable: return "unavailable"
        case .error: return "error"
        case .transform: return "transform"
        case .ready: return "ready"
        case .muted: return "muted"
        case .starting: return "starting"
        case .listeningQuiet: return "listeningQuiet"
        case .latched: return "latched"
        case .cancelled: return "cancelled"
        case .finishing: return "finishing"
        case .finalPreview: return "finalPreview"
        case .inserting: return "inserting"
        case .landedPartial: return "landedPartial"
        case .correcting: return "correcting"
        case .editing: return "editing"
        case .undoAvailable: return "undoAvailable"
        case .meeting: return "meeting"
        }
    }

    /// The fixed sentences this state draws, longest-first is not required — `NotchGeometry` sizes
    /// the pill to the widest of them so a notice is never clipped into a dangling ellipsis.
    /// `.preview` is deliberately absent: live transcript text is head-truncated on purpose (you
    /// want the newest words), and sizing the pill to it would make it twitch on every syllable.
    public var messageLines: [String] {
        switch self {
        case .hidden, .listening, .preview, .transform: return []
        case .idle: return ["Warming up…"]
        case .landing: return ["Landing…"]
        // The committed text is deliberately absent for the same reason `.preview` is: it is
        // variable-length and head-truncated at two lines, so sizing the panel to it buys nothing.
        // The fixed strings a landed/held row can draw *are* listed, so neither can be clipped.
        case .landed(let info): return info.verified ? [] : [DeliveryCopy.landedUnverified]
        case .held(let info): return [info.headline, info.subtitle, HeldPillInfo.actionsLine]
        case .unavailable(let reason): return [reason, PillState.unavailableSubtitle]
        case .error(let message): return [message, PillState.errorSubtitle]
        case .warning(let quality): return [PillState.warningHeadline(quality), PillState.warningSubtitle]
        // V4 states: the fixed sentences of each, verbatim from the verified prototype. Transcript
        // text, the destination-bearing "Inserting in Mail…" / "Updated in Mail" statuses and the
        // hotkey-bearing helpers are absent for the same reason `.preview` is: they are runtime
        // values this state does not carry.
        case .ready(let hint): return [hint]
        case .muted: return [PillCopy.mutedStatus, PillCopy.mutedWords, PillCopy.mutedHelper]
        case .starting: return [PillCopy.startingStatus, PillCopy.startingWords, PillCopy.startingHelper]
        case .listeningQuiet: return [PillCopy.quietStatus, PillCopy.quietHelper]
        case .latched: return [PillCopy.latchedStatus]
        case .cancelled: return [PillCopy.cancelledStatus, PillCopy.cancelledWords, PillCopy.cancelledHelper]
        case .finishing(let slow):
            return [slow ? PillCopy.finishingSlowStatus : PillCopy.finishingStatus, PillCopy.finishingHelper]
        case .finalPreview(let info): return [info.status, info.helper].compactMap { $0 }
        case .inserting: return [PillCopy.insertingHelper]
        case .landedPartial: return [PillCopy.partialStatus, PillCopy.partialHelper]
        case .correcting: return [PillCopy.correctingStatus, PillCopy.correctingHelper]
        case .editing: return [PillCopy.editingHelper]
        case .undoAvailable: return [PillCopy.undoHelper]
        case .meeting(let info): return [info.headline, info.detail, info.helper]
        }
    }

    public static let unavailableSubtitle = "Dictation is off until a speech model is installed"
    public static let errorSubtitle = "Nothing was typed — press the key again to try that turn"
    public static let warningSubtitle = "Check your input device before you speak"

    /// Single source of truth for the mic-quality headline: `PillView` renders it and
    /// `NotchGeometry` measures it, so the pill can never be narrower than its own sentence.
    public static func warningHeadline(_ q: MicQuality) -> String {
        if q.lowLevel { return "Mic level is very low" }
        if q.clipping > 0.05 { return "Mic is clipping" }
        return "Noisy mic — \(Int(q.snr)) dB SNR"
    }

    // MARK: V4 timing that defines the states above (design_v1 §5, build doc S3)

    /// After this long in `.finishing`, `elapsedWarning` is set ("Still finishing your text").
    public static let finishingWarningDelay: TimeInterval = 2
    /// VAD silence while the key is held after which `.listening` reads `.listeningQuiet`.
    public static let quietAfter: TimeInterval = 1.5

    /// The I1 hover hint for the configured key. With the double-tap latch off the design drops the
    /// "or Double Tap" half (design_v1 §5).
    public static func readyHint(key: String, latchEnabled: Bool = true) -> String {
        latchEnabled ? "Hold or Double Tap \(key) to dictate" : "Hold \(key) to dictate"
    }

    /// Owner decision (build doc §0): every prototype string naming "Right Control" is rendered with
    /// the configured key label instead; nothing else in the string changes.
    public static func withHotkey(_ prototypeCopy: String, key: String) -> String {
        prototypeCopy.replacingOccurrences(of: PillCopy.prototypeHotkey, with: key)
    }

    // MARK: The landed family (verified · unverified · partial)

    /// One constructor for all three landed outcomes, so a caller holding a delivery result never
    /// has to know that `.partial` lives in its own case.
    public static func landed(text: String, outcome: LandedOutcome) -> PillState {
        switch outcome {
        case .verified: return .landed(LandedPillInfo(text: text, verified: true))
        case .unverified: return .landed(LandedPillInfo(text: text, verified: false))
        case .partial: return .landedPartial(text: text)
        }
    }

    /// Which landed outcome this state shows; `nil` outside the landed family.
    public var landedOutcome: LandedOutcome? {
        switch self {
        case .landed(let info): return info.verified ? .verified : .unverified
        case .landedPartial: return .partial
        default: return nil
        }
    }

    // MARK: Design inventory

    /// The verified design's state key (`Fixtures/design/design_copy.json` → `states`, `pill`) this
    /// state is drawn as. Pre-V4 cases map to their nearest design row until S2 redraws them.
    /// The design's E1 "blocked" row has no case of its own: it is a named blocker, which the
    /// recovery catalogue (S9) routes to `.unavailable` / `.error`.
    public var designStateKey: String {
        switch self {
        case .hidden: return "idle"
        case .idle, .starting: return "starting"
        case .listening, .preview: return "listening"
        case .landing, .finishing: return "finishing"
        case .landed(let info): return info.verified ? "inserted" : "unconfirmed"
        case .held: return "held"
        case .warning: return "warning"
        case .unavailable: return "unavailable"
        case .error: return "error"
        case .transform, .editing: return "editing"
        case .ready: return "ready"
        case .muted: return "muted"
        case .listeningQuiet: return "quiet"
        case .latched: return "latched"
        case .cancelled: return "cancelled"
        case .finalPreview(let info): return info.needsReview ? "uncertain" : "preview"
        case .inserting: return "inserting"
        case .landedPartial: return "partial"
        case .correcting: return "correcting"
        case .undoAvailable: return "undo"
        case .meeting(let info): return info.phase.designStateKey
        }
    }
}

/// The three landed outcomes (build doc §2 "Delivery outcome": delivered verified / unverified,
/// partial). `held` and `failed` have their own states.
public enum LandedOutcome: String, CaseIterable, Equatable, Sendable {
    case verified, unverified, partial
}

/// F1 / F2 — what the final preview shows while it dwells. The payload is immutable (`let`): only
/// the dwell bookkeeping around it changes; a different text is a different payload.
public struct FinalPreviewInfo: Equatable, Sendable {
    /// The final payload's rendered text — exactly what will be inserted.
    public let text: String
    /// Low-confidence words (`TranscriptSpan.isLowConfidence`). Any > 0 draws F2 and the long dwell.
    public var uncertainCount: Int
    /// Seconds left before insertion. Meaningless while `manual`.
    public var dwellRemaining: TimeInterval
    /// Hover, focus, selection or Review has frozen the dwell.
    public var paused: Bool
    /// Manual review: nothing is inserted until the Insert action.
    public var manual: Bool
    /// The destination's display name ("Mail") from the key-down snapshot, when one is known.
    public var destination: String?

    public init(text: String, uncertainCount: Int = 0, dwellRemaining: TimeInterval, paused: Bool = false,
                manual: Bool = false, destination: String? = nil) {
        self.text = text
        self.uncertainCount = max(0, uncertainCount)
        self.dwellRemaining = max(0, dwellRemaining)
        self.paused = paused
        self.manual = manual
        self.destination = destination
    }

    public var needsReview: Bool { uncertainCount > 0 }

    /// "Ready for Mail" / "Ready for Mail · 1 word to review". `nil` without a destination name:
    /// the design has no destination-less wording, and none is invented here.
    public var status: String? {
        guard let name = destination?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        let ready = PillCopy.readyFor(name)
        return needsReview ? ready + PillCopy.statusSeparator + PillCopy.wordsToReview(uncertainCount) : ready
    }

    public var helper: String {
        switch (needsReview, manual) {
        case (false, false): return PillCopy.previewHelperAuto
        case (false, true): return PillCopy.previewHelperManual
        case (true, false): return PillCopy.reviewHelperAuto
        case (true, true): return PillCopy.reviewHelperManual
        }
    }
}

/// Q0 / Q1 / Q2 — the meeting pill. Capture is separate from dictation; reels move only while
/// capture is actually open (`phase == .recording`).
public struct MeetingPillInfo: Equatable, Sendable {
    public enum Phase: String, CaseIterable, Equatable, Sendable {
        case recording, paused, preparingNotes

        /// Design inventory key: Q0 "meeting", Q1 "paused", Q2 "notes".
        public var designStateKey: String {
            switch self {
            case .recording: return "meeting"
            case .paused: return "paused"
            case .preparingNotes: return "notes"
            }
        }
    }

    public var phase: Phase
    public var elapsed: TimeInterval
    /// False when system audio was denied and capture fell back to the microphone alone (design §8.2:
    /// a visible missing-track notice).
    public var capturesSystemAudio: Bool

    public init(phase: Phase, elapsed: TimeInterval, capturesSystemAudio: Bool = true) {
        self.phase = phase
        self.elapsed = max(0, elapsed)
        self.capturesSystemAudio = capturesSystemAudio
    }

    public var headline: String {
        switch phase {
        case .recording: return PillCopy.meetingRecordingStatus
        case .paused: return PillCopy.meetingPausedStatus
        case .preparingNotes: return PillCopy.meetingNotesStatus
        }
    }

    public var detail: String {
        let clock = PillTimer.text(elapsed: elapsed)
        switch phase {
        case .recording:
            let tracks = capturesSystemAudio ? PillCopy.meetingTracksBoth : PillCopy.meetingTracksMicrophoneOnly
            return tracks + PillCopy.statusSeparator + clock
        case .paused: return PillCopy.meetingPausedDetail + PillCopy.statusSeparator + clock
        case .preparingNotes: return PillCopy.meetingNotesDetail
        }
    }

    public var helper: String {
        switch phase {
        case .recording: return PillCopy.meetingRecordingHelper
        case .paused: return PillCopy.meetingPausedHelper
        case .preparingNotes: return PillCopy.meetingNotesHelper
        }
    }
}

/// The pill's clock: "0:06", "12:04", "1:02:03". Negative or non-finite input reads "0:00".
public enum PillTimer {
    public static func text(elapsed: TimeInterval) -> String {
        let total = elapsed.isFinite ? max(0, Int(elapsed.rounded(.down))) : 0
        let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        return hours > 0
            ? "\(hours):" + twoDigits(minutes) + ":" + twoDigits(seconds)
            : "\(minutes):" + twoDigits(seconds)
    }

    private static func twoDigits(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
}

/// Fixed sentences of the V4 pill states, verbatim from the verified prototype
/// (`Fixtures/design/design_copy.json` → `pill`, asserted by `PillStateV4Tests`). Copy voice and
/// the "Right Control" → configured-key rule are the design's (build doc §0).
public enum PillCopy {
    /// The key the prototype's copy names; replaced by the configured key (`PillState.withHotkey`).
    public static let prototypeHotkey = "Right Control"
    public static let statusSeparator = " · "

    public static let mutedStatus = "⊘ VoicePlus is muted"
    public static let mutedWords = "Microphone closed"
    public static let mutedHelper = "Unmute when you are ready"

    public static let startingStatus = "Starting microphone…"
    public static let startingWords = "Ready for your words"
    public static let startingHelper = "Recording starts when the microphone is open"

    public static let quietStatus = "Listening · quiet"
    public static let quietHelper = "Still listening while you hold"

    public static let latchedStatus = "Latched · hands-free"

    public static let cancelledStatus = "Cancelled"
    public static let cancelledWords = "Nothing inserted"
    public static let cancelledHelper = "You can start a new dictation"

    public static let finishingStatus = "Finishing…"
    /// design_v1 §5: said once finalization has taken `PillState.finishingWarningDelay`.
    public static let finishingSlowStatus = "Still finishing your text"
    public static let finishingHelper = "Microphone closed · nothing inserted yet"

    public static let previewHelperAuto = "Final text · inserts after the preview"
    public static let previewHelperManual = "Final text · insert when ready"
    public static let reviewHelperAuto = "Final preview · hover to pause"
    public static let reviewHelperManual = "Review mode · insert when ready"
    public static func readyFor(_ destination: String) -> String { "Ready for \(destination)" }
    public static func wordsToReview(_ count: Int) -> String {
        "\(count) word\(count == 1 ? "" : "s") to review"
    }

    public static let insertingHelper = "Same text · one insertion attempt"

    public static let partialStatus = "⚠ Only part may have been inserted"
    public static let partialHelper = "Review both versions to avoid duplicate text"

    public static let correctingStatus = "Review one word"
    public static let correctingHelper = "Keep the spelling or replace the verified word"

    public static let editingHelper = "Microphone closed · original text unchanged"

    public static let undoHelper = "Undo only while the edited range still matches"

    public static let meetingRecordingStatus = "Meeting · recording"
    public static let meetingTracksBoth = "Microphone + system audio"
    /// design_v1 §8.2: system-audio denial falls back to microphone-only capture, labelled as such.
    public static let meetingTracksMicrophoneOnly = "Microphone only"
    public static let meetingRecordingHelper = "Capture is separate from dictation"
    public static let meetingPausedStatus = "Meeting paused"
    public static let meetingPausedDetail = "Capture is paused"
    public static let meetingPausedHelper = "Resume when you are ready"
    public static let meetingNotesStatus = "Preparing meeting notes"
    public static let meetingNotesDetail = "Your transcript is already available"
    public static let meetingNotesHelper = "No microphone is recording"
}

/// What the transform-tinted pill shows (P2.3). Additive; the engine reducer never produces it.
public struct TransformPillInfo: Equatable, Sendable {
    public enum Stage: Equatable, Sendable {
        /// Model is rewriting; "editing N words".
        case editing
        /// Rewrite landed; ghost row offers "↩ / try again" for `TransformGhost.lifetime`.
        case done(changed: Int)
        /// Selection still warm for a chained turn; `remaining` seconds.
        case warm(remaining: Int)
        /// No change / failed; short notice then warm.
        case notice(String)
    }
    public var editingWords: Int
    public var stage: Stage
    public init(editingWords: Int, stage: Stage) { self.editingWords = editingWords; self.stage = stage }

    public var headline: String {
        switch stage {
        case .editing: return "editing \(editingWords) word\(editingWords == 1 ? "" : "s")"
        case .done(let n): return n == 0 ? "no change" : "changed \(n) word\(n == 1 ? "" : "s")"
        case .warm(let r): return "say more… (\(r)s)"
        case .notice(let s): return s
        }
    }
    public var showsGhost: Bool { if case .done(let n) = stage { return n > 0 }; return false }
}

/// Pure reducer: engine state → pill state. Warning is sticky for the utterance so the bad-mic
/// notice renders *before* speech starts and is not blown away by the first `listening` tick.
public struct PillStateReducer: Equatable, Sendable {
    public private(set) var state: PillState = .hidden
    public private(set) var stickyWarning: MicQuality?

    public init() {}

    @discardableResult
    public mutating func reduce(_ engine: EngineState) -> PillState {
        switch engine {
        case .idle:
            state = .hidden
            stickyWarning = nil
        case .prewarming:
            state = .idle
        case .warning(let quality):
            stickyWarning = quality
            state = .warning(quality)
        case .listening(let level):
            if let q = stickyWarning { state = .warning(q) } else { state = .listening(level: level) }
        case .previewing(let text):
            stickyWarning = nil
            state = .preview(text: text)
        case .finalizing, .landed:
            stickyWarning = nil
            state = .landing
        case .error(let message):
            stickyWarning = nil
            state = .error(message: message)
        case .unavailable(let reason):
            stickyWarning = nil
            state = .unavailable(reason: reason)
        // G0.4 — the V4 turn lifecycle, 1:1. A new turn never inherits the last one's warning, and
        // neither a closed microphone nor a cancelled turn keeps showing a live-capture warning.
        case .starting:
            stickyWarning = nil
            state = .starting
        case .finishing:
            stickyWarning = nil
            state = .finishing(elapsedWarning: false)
        case .cancelled:
            stickyWarning = nil
            state = .cancelled
        }
        return state
    }

    /// Dismisses a warning while capture continues (user keeps talking anyway).
    public mutating func clearWarning(level: Float) {
        stickyWarning = nil
        if case .warning = state { state = .listening(level: level) }
    }

    public mutating func hide() {
        state = .hidden
        stickyWarning = nil
    }
}

/// Rolling audio-level history for the waveform view. Pure; driven by a level publisher.
public struct WaveformModel: Equatable, Sendable {
    public let barCount: Int
    public private(set) var bars: [Float]
    public var smoothing: Float

    public init(barCount: Int = 24, smoothing: Float = 0.35) {
        self.barCount = max(1, barCount)
        self.bars = Array(repeating: 0, count: max(1, barCount))
        self.smoothing = smoothing
    }

    /// Push the newest level (0…1); the oldest bar falls off the left.
    public mutating func push(level: Float) {
        let clamped = min(1, max(0, level))
        let previous = bars.last ?? 0
        let smoothed = previous + (clamped - previous) * (1 - smoothing)
        bars.removeFirst()
        bars.append(smoothed)
    }

    public mutating func reset() { bars = Array(repeating: 0, count: barCount) }

    public var peak: Float { bars.max() ?? 0 }
}
