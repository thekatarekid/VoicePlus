import AVFoundation
import Engine
import Foundation
import Shared
import SwiftUI

// V5 K5 — Settings › Voice "Mic Mode": a button that opens macOS's own Mic Modes picker
// (Standard / Voice Isolation / Wide Spectrum) via `AVCaptureDevice.showSystemUserInterface(.microphoneModes)`.
// macOS applies Mic Modes only to capture that runs Apple's voice processing, which in VoicePlus is
// the C1 "Noise and echo reduction › Apple's" choice — so the row says which mode is in force and,
// when the enhancement is off, that the system mode won't touch VoicePlus until Apple's is chosen.
// VoicePlus never sets the mode itself (only the user can, in the system UI).

/// The system's Mic Mode, mirrored so the advice is testable without AVFoundation.
public enum SystemMicMode: String, Equatable, Sendable, CaseIterable {
    case standard, voiceIsolation, wideSpectrum

    public var title: String {
        switch self {
        case .standard: return "Standard"
        case .voiceIsolation: return "Voice Isolation"
        case .wideSpectrum: return "Wide Spectrum"
        }
    }
}

/// Reads the active Mic Mode and opens the system picker. Injectable for tests.
public protocol MicModesPresenting: Sendable {
    /// The mode macOS reports as active; nil when unknown (no app has used voice processing yet).
    func activeMode() -> SystemMicMode?
    /// Opens Control Center's Mic Modes picker.
    func show()
}

public struct SystemMicModes: MicModesPresenting {
    public init() {}

    public func activeMode() -> SystemMicMode? {
        switch AVCaptureDevice.activeMicrophoneMode {
        case .standard: return .standard
        case .voiceIsolation: return .voiceIsolation
        case .wideSpectrum: return .wideSpectrum
        @unknown default: return nil
        }
    }

    public func show() { AVCaptureDevice.showSystemUserInterface(.microphoneModes) }
}

enum MicModesCopy {
    static let title = "Mic Mode"
    static let button = "Mic Modes…"
    static let detail = "Voice Isolation keeps your voice and drops the room; Wide Spectrum keeps everything. macOS sets it, not VoicePlus."
    static func active(_ mode: SystemMicMode) -> String { "macOS Mic Mode: \(mode.title)." }
    static let unknown = "macOS shows the mode once a dictation with Apple's noise reduction has run."
    static let needsApple = "Mic Modes only apply with Noise and echo reduction set to Apple's."
    static let airPodsNote = "AirPods: VoicePlus keeps the Mac's microphone while AirPods are in call mode (narrowband); choose AirPods above to use them anyway."
}

/// Pure: what the row says for the current enhancement / mode / input.
public enum MicModesAdvice {
    public struct Line: Equatable, Sendable {
        public var status: String
        /// True when the system mode cannot affect VoicePlus capture right now.
        public var inactive: Bool
        public var airPodsNote: String?
    }

    public static func line(enhancement: CaptureEnhancement, active: SystemMicMode?, inputIsNarrowbandBluetooth: Bool) -> Line {
        let note = inputIsNarrowbandBluetooth ? MicModesCopy.airPodsNote : nil
        guard enhancement == .appleVoiceProcessing else {
            return Line(status: MicModesCopy.needsApple, inactive: true, airPodsNote: note)
        }
        return Line(status: active.map(MicModesCopy.active) ?? MicModesCopy.unknown, inactive: false, airPodsNote: note)
    }
}

@MainActor
public final class MicModesViewModel: ObservableObject {
    @Published public private(set) var line: MicModesAdvice.Line
    private let presenter: any MicModesPresenting
    private let defaults: UserDefaults
    private let narrowbandInput: () -> Bool

    public init(presenter: any MicModesPresenting = SystemMicModes(), defaults: UserDefaults = .standard,
                narrowbandInput: @escaping () -> Bool = { MicModesViewModel.defaultInputIsNarrowband() }) {
        self.presenter = presenter
        self.defaults = defaults
        self.narrowbandInput = narrowbandInput
        self.line = MicModesAdvice.line(enhancement: CaptureEnhancement.current(defaults: defaults, environment: [:]),
                                        active: presenter.activeMode(), inputIsNarrowbandBluetooth: narrowbandInput())
    }

    public func refresh() {
        line = MicModesAdvice.line(enhancement: CaptureEnhancement.current(defaults: defaults, environment: [:]),
                                   active: presenter.activeMode(), inputIsNarrowbandBluetooth: narrowbandInput())
    }

    /// The button: open the system picker, then re-read (the user may change it there).
    public func openSystemPicker() {
        presenter.show()
        refresh()
    }

    /// Whether the system default input is a call-mode (HFP/SCO) Bluetooth mic.
    nonisolated public static func defaultInputIsNarrowband() -> Bool {
        guard let device = AudioDeviceEnumerator.defaultInputDevice() else { return false }
        return BluetoothInputDetector.mode(for: device).isNarrowbandSpeech
    }
}

struct MicModesGroup: View {
    @StateObject private var model = MicModesViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            GroupBox(layout: .rows) {
                RowView(MicModesCopy.title, detail: MicModesCopy.detail) {
                    Button(MicModesCopy.button) { model.openSystemPicker() }
                        .accessibilityIdentifier("settings.voice.micModes")
                }
            }
            Text(model.line.status)
                .windowFont(Tokens.Typography.meta)
                .foregroundStyle(WindowColor.secondaryInk)
            if let note = model.line.airPodsNote {
                Text(note)
                    .windowFont(Tokens.Typography.meta)
                    .foregroundStyle(WindowColor.secondaryInk)
            }
        }
        .onAppear { model.refresh() }
    }
}
