import Foundation

// V5 L1 · the three ambient settings (owner decision).
//
//   Off            — no ambient listening; explicit use (hold key, latch, act key) only.
//   Listen & note  — keep listening and noting; never act. Explicit triggers still act.
//   Listen & act   — infer and run any capability (§O rubric), under the L2 guarantees
//                    (`AmbientGuarantees`: user's voice only, act band only, never self-confirming).
//
// One key, `ambient.mode`, replaces the R8.1 on/off `ambient.capture.enabled`. A Mac that had the old
// switch on migrates to Listen & note — the old switch only ever kept a transcript, so that is the
// mode that changes nothing the user agreed to. Switchable from the menu bar / notch menu (one menu,
// `AmbientModeMenu`), Settings › Privacy, and by voice (`AmbientModeVoiceCommand`).

public enum AmbientMode: String, CaseIterable, Codable, Sendable {
    case off
    case listenAndNote
    case listenAndAct

    public var title: String {
        switch self {
        case .off: return "Off"
        case .listenAndNote: return "Listen & note"
        case .listenAndAct: return "Listen & act"
        }
    }

    /// The one-line consequence under the control.
    public var detail: String {
        switch self {
        case .off: return "VoicePlus only listens when you press a key or latch."
        case .listenAndNote: return "Keeps listening and saves what you say for yourself to Notes. Never types or acts on its own."
        case .listenAndAct: return "Keeps listening and may type or act when you clearly talk to it — only your voice, only when sure."
        }
    }

    /// Glyph for the menu row / presence (X14: shown whenever ambient is on, not gated on `directedSpeech`).
    public var symbol: String? {
        switch self {
        case .off: return nil
        case .listenAndNote: return "ear"
        case .listenAndAct: return "ear.badge.waveform"
        }
    }

    /// Ambient capture runs at all.
    public var listens: Bool { self != .off }
    /// Ambient speech may be acted on / typed (still subject to `AmbientGuarantees`).
    public var mayAct: Bool { self == .listenAndAct }
}

/// Reads and writes the mode, migrating the R8.1 switch.
public enum AmbientModeSettings {
    public static let key = "ambient.mode"
    /// R8.1's switch; read once for migration, then kept in step for older readers.
    public static let legacyEnabledKey = "ambient.capture.enabled"
    /// Set after the first-enable explainer was shown.
    public static let explainerShownKey = "ambient.mode.explainerShown"

    public static func mode(_ store: (any SettingsStore)?) -> AmbientMode {
        guard let store else { return .off }
        if let raw = store.string(key), let m = AmbientMode(rawValue: raw) { return m }
        return store.bool(legacyEnabledKey) == true ? .listenAndNote : .off
    }

    public static func set(_ mode: AmbientMode, store: (any SettingsStore)?) {
        store?.set(mode.rawValue, for: key)
        store?.set(mode.listens, for: legacyEnabledKey)
    }

    /// True the first time ambient is turned on (from off) on this Mac; marks it shown.
    public static func consumeExplainer(turningOn mode: AmbientMode, store: (any SettingsStore)?) -> Bool {
        guard mode.listens, let store, store.bool(explainerShownKey) != true else { return false }
        store.set(true, for: explainerShownKey)
        return true
    }
}

/// "stop listening" → Off · "just take notes" → Listen & note · "you can act again" → Listen & act.
/// Whole-utterance phrases only (a sentence that merely contains "stop listening" is not a command).
public enum AmbientModeVoiceCommand {
    public static let phrases: [AmbientMode: [String]] = [
        .off: ["stop listening", "stop listening to me", "turn off listening", "turn listening off",
               "stop ambient", "ambient off"],
        .listenAndNote: ["just take notes", "only take notes", "just notes", "take notes only",
                         "listen and note", "notes only"],
        .listenAndAct: ["you can act again", "you can act", "listen and act", "start acting again",
                        "you can do things again"],
    ]

    public static func parse(_ text: String) -> AmbientMode? {
        let norm = text.lowercased()
            .components(separatedBy: CharacterSet.letters.union(.whitespaces).inverted).joined()
            .split(separator: " ").joined(separator: " ")
        var stripped = norm
        for lead in ["hey voiceplus ", "voiceplus ", "okay ", "ok ", "please "] where stripped.hasPrefix(lead) {
            stripped.removeFirst(lead.count)
        }
        for suffix in [" please", " now", " for now"] where stripped.hasSuffix(suffix) {
            stripped.removeLast(suffix.count)
        }
        for (mode, list) in phrases where list.contains(stripped) { return mode }
        return nil
    }
}

/// The live mode, shared by the menu, Settings and the voice path. Observers are told on every change.
public final class AmbientModeController: @unchecked Sendable {
    private weak var settings: (any SettingsStore)?
    private let lock = NSLock()
    private var observers: [UUID: (AmbientMode) -> Void] = [:]
    /// Called on the first enable from off (the one-time explainer sheet). Nil: nothing shown.
    public var presentExplainer: ((AmbientMode) -> Void)?

    public init(settings: (any SettingsStore)?) { self.settings = settings }

    public var mode: AmbientMode { AmbientModeSettings.mode(settings) }

    public func set(_ mode: AmbientMode) {
        let old = self.mode
        guard old != mode else { return }
        AmbientModeSettings.set(mode, store: settings)
        if !old.listens, AmbientModeSettings.consumeExplainer(turningOn: mode, store: settings) {
            presentExplainer?(mode)
        }
        let list = lock.withLock { Array(observers.values) }
        list.forEach { $0(mode) }
    }

    /// Applies a spoken mode command; returns the new mode when `text` was one.
    @discardableResult
    public func applyVoice(_ text: String) -> AmbientMode? {
        guard let m = AmbientModeVoiceCommand.parse(text) else { return nil }
        set(m)
        return m
    }

    @discardableResult
    public func observe(_ body: @escaping (AmbientMode) -> Void) -> UUID {
        let id = UUID()
        lock.withLock { observers[id] = body }
        return id
    }

    public func removeObserver(_ id: UUID) { lock.withLock { observers[id] = nil } }

    /// The app's explainer presenter for surfaces that write the mode directly (Settings › Privacy).
    /// Set at launch; nil in tests.
    nonisolated(unsafe) public static var presentFirstEnable: ((AmbientMode) -> Void)?

    public static let explainerTitle = "Ambient listening"
    public static let explainerBody = """
        VoicePlus keeps listening between turns. Only your enrolled voice is used; other people are never \
        acted on. Listen & note saves things you say for yourself to Notes and never types or acts. \
        Listen & act may also type or act — only when it is sure you are talking to it, and never \
        confirms anything irreversible by itself. Say "stop listening" or use the menu to turn it off. \
        The microphone indicator stays on while it listens.
        """
}
