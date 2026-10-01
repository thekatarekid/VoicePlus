import Engine
import SwiftUI

// V5 K3 · Settings › Voice › "Only react to my voice".
//
// One switch for "voices that are not mine never become my text". It is on by default, and it
// *takes effect* once VoicePlus knows the voice: enrolled (H2) or learned passively from holds (M6
// voiceprint, five holds), with an embedder that can tell voices apart. Until then it says so instead of
// pretending a check ran. What it governs:
// * the latch speaker filter (R3.3): hands-free segments in another voice are not typed;
// * K4's turn anchor: in a hands-free turn, another voice than the one that started it goes to Notes.
// A hold is always the user (they pressed the key), so holds are never filtered. Ambient keeps its
// own, stricter rule (V5 L2: only the user's voice may ever act) and is not loosened by this switch.

public enum OnlyMyVoiceSettings {
    public static let key = "voice.onlyMyVoice"

    /// Default on: nothing stored means on.
    public static func isOn(_ store: (any SettingsStore)?) -> Bool { store?.bool(key) ?? true }

    public static func set(_ on: Bool, store: (any SettingsStore)?) { store?.set(on, for: key) }
}

/// What the row says under the switch.
public enum OnlyMyVoiceStatus: Equatable, Sendable {
    /// Switched off by the user: every voice is treated as the user's while hands-free.
    case off
    /// On, and filtering: the voice is known and the embedder identifies speakers.
    case active
    /// On, but no voice known yet (learning N of M from holds, or never enrolled).
    case waiting(learned: Int, of: Int)
    /// On, the voice is known, but no speaker model is installed to compare voices.
    case unavailable

    public init(preference: Bool, enrollment: VoiceEnrollmentStatus) {
        guard preference else { self = .off; return }
        switch enrollment {
        case .enrolled(_, let filtering, _): self = filtering ? .active : .unavailable
        case .learning(let learned, let total): self = .waiting(learned: learned, of: total)
        case .off: self = .waiting(learned: 0, of: PassiveVoiceprint.minimumTurns)
        }
    }

    public var line: String {
        switch self {
        case .off: return OnlyMyVoiceCopy.offLine
        case .active: return OnlyMyVoiceCopy.activeLine
        case .waiting(let learned, let total): return OnlyMyVoiceCopy.waitingLine(learned: learned, of: total)
        case .unavailable: return OnlyMyVoiceCopy.unavailableLine
        }
    }
}

public enum OnlyMyVoiceCopy {
    public static let title = "Only react to my voice"
    public static let detail = "Each hands-free turn is anchored to the voice of whoever started it, and VoicePlus learns your voice from the times you hold the key. Other voices are kept out of your text — they go to Notes instead."
    public static let offLine = "Off — while hands-free, any voice can type."
    public static let activeLine = "On — other voices are kept out of your text."
    public static let unavailableLine = "On, but the speaker model isn't installed yet, so voices can't be told apart."
    public static func waitingLine(learned: Int, of total: Int) -> String {
        "On once VoicePlus knows your voice — hold the key to dictate a few times (\(learned) of \(total))."
    }
}

/// The row: a switch, and the honest sentence under it.
struct OnlyMyVoiceRow: View {
    let enrollment: VoiceEnrollmentStatus
    var store: () -> (any SettingsStore)? = { MainWindowController.dependencies?.settingsStore }
    @State private var isOn: Bool = true

    var body: some View {
        let status = OnlyMyVoiceStatus(preference: isOn, enrollment: enrollment)
        RowView(OnlyMyVoiceCopy.title, detail: OnlyMyVoiceCopy.detail + " " + status.line) {
            Toggle(OnlyMyVoiceCopy.title, isOn: Binding(
                get: { isOn },
                set: { isOn = $0; OnlyMyVoiceSettings.set($0, store: store()) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .accessibilityIdentifier("voice.onlyMyVoice")
        }
        .onAppear { isOn = OnlyMyVoiceSettings.isOn(store()) }
        .accessibilityIdentifier("voice.onlyMyVoice.row")
    }
}
