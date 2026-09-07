import Foundation
import Shared

/// P5 — why the indicator is showing a stop sign instead of a state.
public enum PresenceBlockReason: Equatable, Sendable {
    case microphoneDenied
    case hotkeyUnavailable
    /// The tap is armed and macOS is still not delivering keys to us. The honest answer here is
    /// "quit and reopen" — offered as one click, never done behind the user's back.
    case relaunchNeeded
    /// P3's download, injected as a fraction. Optional on purpose: P5 ships without waiting for a
    /// download service, and `nil` simply means "don't mention it".
    case modelDownloading(Double)
    /// No ASR model on disk and no OS speech fallback: nothing can be recognised at all.
    case modelMissing

    /// Short word for the resting badge.
    public var badge: String {
        switch self {
        case .microphoneDenied: return "Mic off"
        case .hotkeyUnavailable: return "Key off"
        case .relaunchNeeded: return "Relaunch"
        case .modelDownloading(let p): return "\(Int((min(max(p, 0), 1)) * 100))%"
        case .modelMissing: return "No model"
        }
    }

    /// The sentence shown when the pointer is on the indicator.
    public var detail: String {
        switch self {
        case .microphoneDenied: return "VoicePlus can't hear — grant Microphone in System Settings"
        case .hotkeyUnavailable: return "Dictation key is off — grant Input Monitoring in System Settings"
        case .relaunchNeeded: return "macOS isn't sending keys to VoicePlus — quit and reopen it"
        case .modelDownloading(let p): return "Downloading the speech model — \(Int((min(max(p, 0), 1)) * 100))%"
        case .modelMissing: return "No speech model installed — dictation is off until one is downloaded"
        }
    }

    public var symbol: String {
        switch self {
        case .microphoneDenied: return "mic.slash.circle.fill"
        case .hotkeyUnavailable: return "keyboard.badge.ellipsis"
        case .relaunchNeeded: return "arrow.clockwise.circle.fill"
        case .modelDownloading: return "arrow.down.circle.fill"
        case .modelMissing: return "exclamationmark.circle.fill"
        }
    }
}

/// P5 — what the always-available indicator near the notch is saying right now.
///
/// Distinct from `AmbientState` on purpose: `AmbientState` models the hands-free microphone
/// (listening / muted / processing), which is not the same question as "is VoicePlus alive, and can
/// it do anything?". The two agree where they overlap — this state borrows `AmbientState`'s notch
/// symbols so the glyph vocabulary stays one vocabulary.
public enum PresenceState: Equatable, Sendable {
    /// Nothing on screen at all: switched off in Settings, suppressed by the pill, or a quiet state
    /// hidden in a full-screen Space.
    case off
    case ready
    case listening(level: Float)
    case processing
    case muted
    case paused
    case blocked(PresenceBlockReason)

    public var isVisible: Bool { self != .off }

    public var caseName: String {
        switch self {
        case .off: return "off"
        case .ready: return "ready"
        case .listening: return "listening"
        case .processing: return "processing"
        case .muted: return "muted"
        case .paused: return "paused"
        case .blocked: return "blocked"
        }
    }

    /// States that may be hidden in a full-screen Space. `listening`, `processing` and `muted` are
    /// deliberately absent: hiding a hot (or hard-muted) mic in full screen is exactly the hidden
    /// hot mic the product spec forbids, and full screen — a call, a talk, a screen share — is when
    /// it matters most.
    public var isQuiet: Bool {
        switch self {
        case .off, .ready, .paused, .blocked: return true
        case .listening, .processing, .muted: return false
        }
    }

    public var offersRelaunch: Bool { self == .blocked(.relaunchNeeded) }

    public var symbol: String {
        switch self {
        case .off: return "circle.dashed"
        case .ready: return "mic"
        case .listening: return AmbientState.listening.notchSymbol
        case .processing: return AmbientState.processing.notchSymbol
        case .muted: return AmbientState.muted.notchSymbol
        case .paused: return "pause.circle.fill"
        case .blocked(let reason): return reason.symbol
        }
    }

    /// Short text rendered on the resting badge; `nil` states render as a bare chin or level bar.
    public var badge: String? {
        switch self {
        case .off, .ready, .listening, .processing: return nil
        case .muted: return "MUTED"
        case .paused: return "Paused"
        case .blocked(let reason): return reason.badge
        }
    }

    /// The sentence shown when the pointer is on the indicator. Always non-empty for a visible state.
    public var detail: String {
        switch self {
        case .off: return "VoicePlus indicator is off"
        case .ready: return "VoicePlus · Ready"
        case .listening: return "VoicePlus · Listening"
        case .processing: return "VoicePlus · Working…"
        case .muted: return "VoicePlus · Muted — the mic stays closed"
        case .paused: return "VoicePlus · Paused"
        case .blocked(let reason): return reason.detail
        }
    }

    /// 0…1 mic level; 0 for every state that is not listening.
    public var level: Float {
        if case .listening(let l) = self { return min(max(l, 0), 1) }
        return 0
    }
}

/// Everything the presence state is a function of. All defaults are the "nothing wired yet" values,
/// so a caller only supplies what it actually knows.
public struct PresenceInputs: Equatable, Sendable {
    /// Settings › General › "Show indicator under the notch".
    public var enabled: Bool
    /// Settings › General › "Hide it in full screen" — quiet states only, always.
    public var hideInFullScreen: Bool
    /// False = the host display is in a full-screen Space (its menu bar has collapsed).
    public var menuBarPresent: Bool
    /// The pill is the richer surface at the same anchor: one thing under the notch at a time.
    public var pillVisible: Bool
    public var muted: Bool
    public var paused: Bool
    /// The hands-free ambient model is doing work (`AmbientStateModel.processing`). Independent of
    /// the dictation engine, which has its own states below.
    public var ambientProcessing: Bool
    public var engine: EngineState
    public var capabilities: PermissionPlanner.Capabilities
    /// `CapabilityWatcher.onTapProvenDead` — armed tap, no events.
    public var tapProvenDead: Bool
    /// Injected by whoever owns model downloads; `nil` means "don't mention it".
    public var downloadProgress: Double?

    /// "Nothing is missing" — the default the reducer starts from. A `public` constant rather than
    /// an inline literal because `PermissionPlanner.Capabilities`' memberwise initialiser is
    /// internal and so cannot appear in a public default argument.
    public static let allCapabilities = PermissionPlanner.Capabilities(canCapture: true, canUseGlobalHotkey: true,
                                                                      canInjectText: true)

    public init(enabled: Bool = true,
                hideInFullScreen: Bool = true,
                menuBarPresent: Bool = true,
                pillVisible: Bool = false,
                muted: Bool = false,
                paused: Bool = false,
                ambientProcessing: Bool = false,
                engine: EngineState = .idle,
                capabilities: PermissionPlanner.Capabilities = PresenceInputs.allCapabilities,
                tapProvenDead: Bool = false,
                downloadProgress: Double? = nil) {
        self.enabled = enabled
        self.hideInFullScreen = hideInFullScreen
        self.menuBarPresent = menuBarPresent
        self.pillVisible = pillVisible
        self.muted = muted
        self.paused = paused
        self.ambientProcessing = ambientProcessing
        self.engine = engine
        self.capabilities = capabilities
        self.tapProvenDead = tapProvenDead
        self.downloadProgress = downloadProgress
    }
}

/// Pure reducer. Precedence — mute wins over everything, because the indicator must never show
/// something less alarming than reality:
///
///     muted  >  paused  >  blocked  >  listening  >  processing  >  ready
public enum PresenceStateReducer {
    public static func reduce(_ inputs: PresenceInputs) -> PresenceState {
        guard inputs.enabled else { return .off }
        let state = substance(inputs)
        // The pill is showing at the same anchor; it says everything this would say and more.
        if inputs.pillVisible { return .off }
        if inputs.hideInFullScreen, !inputs.menuBarPresent, state.isQuiet { return .off }
        return state
    }

    /// The state before any suppression rule is applied.
    public static func substance(_ inputs: PresenceInputs) -> PresenceState {
        if inputs.muted { return .muted }
        if inputs.paused { return .paused }
        if let reason = blockage(inputs) { return .blocked(reason) }
        switch inputs.engine {
        case .listening(let level): return .listening(level: min(max(level, 0), 1))
        case .prewarming, .previewing, .finalizing: return .processing
        case .idle, .landed, .warning, .error: return inputs.ambientProcessing ? .processing : .ready
        // No recognizer at all: the indicator must not read "ready" — nothing can be dictated.
        case .unavailable: return .blocked(.modelMissing)
        }
    }

    static func blockage(_ inputs: PresenceInputs) -> PresenceBlockReason? {
        if !inputs.capabilities.canCapture { return .microphoneDenied }
        if inputs.tapProvenDead { return .relaunchNeeded }
        if !inputs.capabilities.canUseGlobalHotkey { return .hotkeyUnavailable }
        if let progress = inputs.downloadProgress, progress < 1 { return .modelDownloading(progress) }
        return nil
    }
}
