import Foundation
import Shared

// Tap to talk (owner request, 2026-10-06) — a single short tap of the dictation key starts a
// dictation; the next tap finishes it and lands the text through the same path as a hold (preview,
// outcome row, ribbon). Hold-to-talk and double-tap hands-free are unchanged.
//
// The gesture itself lives in `HotkeyStateMachine` (`.tapToTalk`, `.tapTalking`); this file holds the
// setting, the copy, the silence timeout and the wiring that ties them to the live key.

// MARK: - Settings

public extension SettingsKeys {
    /// Settings › Shortcuts "Tap to talk": on by default.
    static let tapToTalk = "tapToTalk.enabled"
    /// Settings › Shortcuts "Stop after silence of" (seconds, as text like the latch pause).
    static let tapToTalkSilenceSeconds = "tapToTalk.silenceSeconds"
}

public enum TapToTalkSettings {
    public static let defaultSilenceSeconds: TimeInterval = 10
    public static let silenceRange: ClosedRange<TimeInterval> = 3...30

    public static func isEnabled(_ store: SettingsStore?) -> Bool { store?.bool(SettingsKeys.tapToTalk) ?? true }
    public static func setEnabled(_ on: Bool, store: SettingsStore?) { store?.set(on, for: SettingsKeys.tapToTalk) }

    /// The stored timeout, clamped to `silenceRange`. Missing or unreadable → the default.
    public static func silenceSeconds(_ store: SettingsStore?) -> TimeInterval {
        guard let raw = store?.string(SettingsKeys.tapToTalkSilenceSeconds),
              let value = Double(raw.trimmingCharacters(in: .whitespaces)), value.isFinite else {
            return defaultSilenceSeconds
        }
        return clamp(value)
    }

    public static func setSilenceSeconds(_ seconds: TimeInterval, store: SettingsStore?) {
        guard let store, seconds.isFinite else { return }
        store.set(String(clamp(seconds)), for: SettingsKeys.tapToTalkSilenceSeconds)
    }

    /// Bounded to the range, whole seconds (the precision the row offers).
    public static func clamp(_ seconds: TimeInterval) -> TimeInterval {
        min(silenceRange.upperBound, max(silenceRange.lowerBound, seconds)).rounded()
    }
}

// MARK: - Copy

/// Every line names the key the user bound (`HotkeyBinding.label`).
public enum TapToTalkCopy {
    public static let title = "Tap to talk"
    public static func detail(_ key: String) -> String {
        "Tap \(key) once, speak, then tap again to insert. Holding still works."
    }
    public static let silenceTitle = "Stop after silence of"
    public static let silenceDetail = "When you say nothing for this long, a tap-to-talk dictation inserts what you said."
    public static let offNote = "Turn on Tap to talk to use this."
    /// The live notch's lane note while a tap-to-talk dictation listens.
    public static func finishNote(_ key: String) -> String { "Tap \(key) to finish · Esc cancels" }
    /// Onboarding's first dictation.
    public static func onboardingHint(_ key: String) -> String { "Or tap \(key) once, speak, and tap again to finish." }
    public static func seconds(_ value: TimeInterval) -> String { String(format: "%.0f s", value) }
}

// MARK: - The running dictation

/// The tap-to-talk dictation that is running, if any: its silence timeout (nothing said for
/// `silenceTimeout` → finish and land what was said) and whether speech was heard since capture
/// started (chord-cancel applies only before). Fed by the dictation coordinator (gesture, VAD,
/// engine words); its three edges are wired by `TapToTalkWiring`. Thread-safe: VAD arrives off main.
public final class TapToTalkWatch: @unchecked Sendable {
    public var clock: TurnClock = MainQueueTurnClock()
    public var silenceTimeout: () -> TimeInterval = { TapToTalkSettings.defaultSilenceSeconds }
    /// The silence timeout elapsed: finish and land (the live wiring asks the hotkey, so the
    /// gesture and the turn end together).
    public var onSilence: (() -> Void)?
    /// A tap-to-talk dictation began (the key came up and capture keeps running).
    public var onBegan: (() -> Void)?
    /// The dictation ended — by the tap that finished it, the timeout, Escape, a failure or a
    /// switch to hands-free. The live wiring resets a gesture still waiting for the finishing tap.
    public var onEnded: (() -> Void)?

    private let lock = NSLock()
    private var active = false
    private var heard = false
    private var speaking = false
    private var lastWords = ""
    private var generation = 0
    private var timer: TurnTimer?

    public init() {}

    public var isActive: Bool { lock.withLock { active } }
    /// Speech (VAD, or the engine's live words) since the capture started.
    public var heardSpeech: Bool { lock.withLock { heard } }

    /// A capture is starting (key-down): nothing heard yet.
    public func captureStarting() {
        lock.withLock {
            heard = false
            speaking = false
            lastWords = ""
        }
    }

    public func begin() {
        let began = lock.withLock { () -> Bool in
            guard !active else { return false }
            active = true
            if !speaking { armLocked() }
            return true
        }
        guard began else { return }
        Log.app.info("tap-to-talk: listening until the next tap or \(Int(silenceTimeout())) s of silence")
        onBegan?()
    }

    /// The dictation ended. Notifies only when one was running.
    public func end() {
        let ended = lock.withLock { () -> Bool in
            guard active else { return false }
            active = false
            timer?.cancel()
            timer = nil
            generation &+= 1
            return true
        }
        if ended { onEnded?() }
    }

    /// The tap came up but there is no dictation to keep (a refused press): reset the gesture.
    public func abandon() {
        let wasActive = isActive
        end()
        if !wasActive { onEnded?() }
    }

    /// VAD speech start (`true`) / end (`false`). Silence is counted from the last speech end.
    public func noteSpeech(_ speech: Bool) {
        lock.withLock {
            speaking = speech
            if speech { heard = true }
            guard active else { return }
            if speech {
                timer?.cancel()
                timer = nil
                generation &+= 1
            } else {
                armLocked()
            }
        }
    }

    /// The engine's live words. New words are speech even where no VAD feeds this watch.
    public func noteWords(_ text: String) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.withLock {
            guard !words.isEmpty, words != lastWords else { return }
            lastWords = words
            heard = true
            if active, !speaking { armLocked() }
        }
    }

    private func armLocked() {
        timer?.cancel()
        generation &+= 1
        let current = generation
        let seconds = max(0.5, silenceTimeout())
        timer = clock.schedule(after: seconds) { [weak self] in self?.fire(current) }
    }

    private func fire(_ current: Int) {
        let due = lock.withLock { active && generation == current && !speaking }
        guard due else { return }
        Log.app.notice("tap-to-talk: \(Int(silenceTimeout())) s of silence — finishing")
        onSilence?()
    }
}

// MARK: - Wiring

/// Ties the setting, the live key and the running dictation together (composition root).
public enum TapToTalkWiring {
    /// How long after the tap the lane note waits: the notch reveals 300 ms after key-down (X1).
    public static let noteDelay: TimeInterval = TurnController.holdPresentDelayDefault + 0.15

    /// The gesture switches on the live key, before the container exists. The hotkey is armed
    /// before `AppContainer.build` (A3) and `LaunchPressGate` holds one press until it lands; without
    /// this a tap made in the first seconds after launch was a plain tap (cancelled) instead of
    /// starting a dictation the gate replays. Settings live in `UserDefaults.standard`, the same
    /// store the container reads later.
    public static func armEarly(hotkey: HotkeyService, settings: SettingsStore?) {
        hotkey.tapToTalkEnabled = { TapToTalkSettings.isEnabled(settings) }
        hotkey.doubleTapLatchEnabled = { LatchGestureSettings.isEnabled(settings) }
    }

    public static func attach(hotkey: HotkeyService, coordinator: DictationCoordinator, settings: SettingsStore?,
                              showNote: @escaping (String) -> Void) {
        armEarly(hotkey: hotkey, settings: settings)
        let watch = coordinator.tapToTalk
        hotkey.speechHeard = { [weak watch] in watch?.heardSpeech ?? false }
        watch.silenceTimeout = { TapToTalkSettings.silenceSeconds(settings) }
        watch.onSilence = { [weak hotkey] in
            onMain { hotkey?.finishTapToTalk(reason: "silence timeout") }
        }
        watch.onEnded = { [weak hotkey] in
            onMain { hotkey?.abandonTapToTalk() }
        }
        watch.onBegan = { [weak watch, weak hotkey] in
            DispatchQueue.main.asyncAfter(deadline: .now() + noteDelay) {
                guard let watch, watch.isActive, let key = hotkey?.binding.label else { return }
                showNote(TapToTalkCopy.finishNote(key))
            }
        }
    }

    private static func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}
