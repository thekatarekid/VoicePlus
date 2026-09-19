import AppKit
import Foundation
import Shared

// W3H — the wave-2 gate's open hand-offs that live at the composition root (AppDelegate's W3H block):
// Settings › Shortcuts "Double-tap to latch" on the live key, Settings › General sound cues at the
// design's cue points (design §11), the saved window theme applied at launch, and Privacy's
// "Save dictation history" switch honoured by everything that saves a dictation. The pill's Review
// routing and transform rows are in `PillReviewRouting.swift` and PillView's W3H region.
//
// Every piece is a value or a small object with injected edges, so AppTests drive it without a key,
// a speaker, a window or a database.

// MARK: - Double-tap to latch

/// Applies "Double-tap to latch" (S7g, `LatchGestureSettings`) to the live dictation key, read on every
/// action so the switch takes effect without a relaunch. With it off, the second quick tap is one more
/// short tap: `.enterLatch` becomes `.cancelCapture`, and the key's state machine — which did latch —
/// is reset first, so the next press starts a new hold instead of finishing a latch nobody asked for.
public struct LatchGestureHook {
    public var isEnabled: () -> Bool
    public var resetGesture: () -> Void
    public var forward: (HotkeyStateMachine.Action) -> Void

    public init(isEnabled: @escaping () -> Bool, resetGesture: @escaping () -> Void,
                forward: @escaping (HotkeyStateMachine.Action) -> Void) {
        self.isEnabled = isEnabled
        self.resetGesture = resetGesture
        self.forward = forward
    }

    public func handle(_ action: HotkeyStateMachine.Action) {
        let enabled = isEnabled()
        if !enabled, action == .enterLatch { resetGesture() }
        LatchGestureSettings.filter([action], enabled: enabled).forEach(forward)
    }

    /// The idle chin's hint names the gesture only when it exists (design §5): "Hold or Double Tap
    /// fn / 🌐 to dictate", or "Hold fn / 🌐 to dictate" with the switch off.
    public static func readyHint(binding: HotkeyBinding, settings: SettingsStore?) -> String {
        binding.readyHint(latchEnabled: LatchGestureSettings.isEnabled(settings))
    }
}

// MARK: - The window theme at launch

/// Settings › Appearance (S7g): the saved follow system / light / dark is applied as the app starts,
/// before the first window, menu or onboarding page is drawn — not only when the Settings page is first
/// built. The pill never follows it (its tokens are fixed dark).
public enum LaunchAppearance {
    @MainActor
    @discardableResult
    public static func apply(settings: SettingsStore?,
                             apply: @MainActor (WindowTheme) -> Void = { AppearanceSettings.apply($0) }) -> WindowTheme {
        let theme = AppearanceSettings.theme(settings)
        apply(theme)
        return theme
    }
}

// MARK: - Sound cues

/// Settings › General "Sound cues" at the design's cue points (design §11: "Optional quiet start/stop
/// earcons default off; no success sound until insertion is verified"): a start earcon when the
/// microphone actually opens (Listening, never Starting), a stop earcon when it closes, and the success
/// sound only for a delivery readback verified. Unconfirmed, partial, held, failed and cancelled turns
/// make no success sound. Driven by the turn record's stages (S11), so a cue follows what happened to
/// the turn, not what the pill drew; `SoundCuePlayer` decides whether cues are on.
public final class TurnSoundCues: @unchecked Sendable {
    /// Turns remembered for de-duplication (a record is saved again when its database write lands).
    public static let memory = 128

    private let lock = NSLock()
    private var stages: [TurnID: TurnStage] = [:]
    private var order: [TurnID] = []

    public init() {}

    /// The cue moments one change to a turn's record crosses. A repeat of the same stage (the database
    /// write landing, a field update) crosses none.
    public func events(for entry: TurnEntry) -> [SoundCueEvent] {
        let previous = remember(entry.id, entry.stage)
        guard previous != entry.stage else { return [] }
        var events: [SoundCueEvent] = []
        let wasOpen = previous.map(Self.microphoneOpen) ?? false
        let isOpen = Self.microphoneOpen(entry.stage)
        if isOpen, !wasOpen { events.append(.captureOpened) }
        if wasOpen, !isOpen { events.append(.captureClosed) }
        switch entry.stage {
        case .landed:
            if let outcome = entry.record.outcome, outcome.isDelivered {
                events.append(.delivered(verified: outcome.isVerified))
            } else {
                events.append(.notDelivered)
            }
        case .held, .failed, .cancelled:
            events.append(.notDelivered)
        default:
            break
        }
        return events
    }

    /// Capture really open: C1 / C2. `starting` is key-down, not listening.
    static func microphoneOpen(_ stage: TurnStage) -> Bool {
        stage == .listening || stage == .listeningQuiet
    }

    private func remember(_ id: TurnID, _ stage: TurnStage) -> TurnStage? {
        lock.withLock {
            let previous = stages[id]
            if previous == nil {
                order.append(id)
                if order.count > Self.memory { stages[order.removeFirst()] = nil }
            }
            stages[id] = stage
            return previous
        }
    }

    /// Chains onto the store's change feed (whoever listened before keeps listening); the store keeps
    /// this tracker alive. Cues play on the main thread; `sink` is the speaker (`NSSound` in the app,
    /// a recorder in tests).
    public func attach(to store: TurnStore, settings: SettingsStore?,
                       sink: @escaping (SoundCue) -> Void = { NSSound(named: NSSound.Name($0.systemSoundName))?.play() },
                       perform: @escaping (@escaping () -> Void) -> Void = { work in
                           if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
                       }) {
        let previous = store.onChange
        store.onChange = { entry in
            previous?(entry)
            let events = self.events(for: entry)
            guard !events.isEmpty else { return }
            perform {
                for event in events { SoundCuePlayer.play(event, store: settings, sink: sink) }
            }
        }
    }
}

// MARK: - "Save dictation history"

/// Privacy › "Save dictation history" (S7f's row, S7b's key `history.dictation.enabled`). Off: no
/// dictation reaches `dictation_history` (the lander, the coordinator's shell path) and the turn store
/// writes only recoverable rows (held, partial), under recovery persistence — which stays its own
/// switch. In-memory turn state (the controller's record, Today's held drafts, this session's rows)
/// is untouched.
public enum DictationHistoryGate {
    public static func recordsHistory(_ settings: SettingsStore?) -> Bool {
        TodayHistorySettings.isEnabled(settings)
    }

    /// Points every writer at the switch, read per write so turning it off takes effect on the next
    /// dictation, with no relaunch.
    public static func attach(settings: SettingsStore?, lander: UtteranceLander?, coordinator: DictationCoordinator?,
                              store: TurnStore?) {
        let reads: () -> Bool = { recordsHistory(settings) }
        lander?.recordsHistory = reads
        coordinator?.recordsHistory = reads
        store?.historyEnabled = reads
    }
}
