import Engine
import Foundation
import Testing
@testable import VoicePlusApp

/// V5 K5 — Settings › Voice Mic Modes button: opens the system picker, says honestly whether the
/// system mode reaches VoicePlus (only with Apple's voice processing), notes call-mode AirPods.
@MainActor @Suite struct MicModesTests {
    final class FakePresenter: MicModesPresenting, @unchecked Sendable {
        var mode: SystemMicMode?
        var shown = 0
        var modeAfterShow: SystemMicMode?
        init(_ mode: SystemMicMode?) { self.mode = mode }
        func activeMode() -> SystemMicMode? { mode }
        func show() { shown += 1; if let m = modeAfterShow { mode = m } }
    }

    func defaults(_ e: CaptureEnhancement?) -> UserDefaults {
        let d = UserDefaults(suiteName: "k5-\(UUID().uuidString)")!
        if let e { CaptureEnhancement.set(e, defaults: d) }
        return d
    }

    @Test func modeOnlyAppliesWithApplesVoiceProcessing() {
        for e in [CaptureEnhancement.off, .localVQE] {
            let line = MicModesAdvice.line(enhancement: e, active: .voiceIsolation, inputIsNarrowbandBluetooth: false)
            #expect(line.inactive && line.status == MicModesCopy.needsApple)
        }
        let on = MicModesAdvice.line(enhancement: .appleVoiceProcessing, active: .voiceIsolation, inputIsNarrowbandBluetooth: false)
        #expect(!on.inactive && on.status == "macOS Mic Mode: Voice Isolation.")
        let unknown = MicModesAdvice.line(enhancement: .appleVoiceProcessing, active: nil, inputIsNarrowbandBluetooth: false)
        #expect(unknown.status == MicModesCopy.unknown && unknown.airPodsNote == nil)
    }

    @Test func callModeAirPodsGetANote() {
        let line = MicModesAdvice.line(enhancement: .off, active: nil, inputIsNarrowbandBluetooth: true)
        #expect(line.airPodsNote == MicModesCopy.airPodsNote)
    }

    @Test func buttonOpensTheSystemPickerAndRereads() {
        let presenter = FakePresenter(.standard)
        presenter.modeAfterShow = .voiceIsolation
        let model = MicModesViewModel(presenter: presenter, defaults: defaults(.appleVoiceProcessing), narrowbandInput: { false })
        #expect(model.line.status == "macOS Mic Mode: Standard.")
        model.openSystemPicker()
        #expect(presenter.shown == 1)
        #expect(model.line.status == "macOS Mic Mode: Voice Isolation.")
    }

    @Test func defaultEnhancementIsOffSoTheRowSaysSo() {
        let model = MicModesViewModel(presenter: FakePresenter(.voiceIsolation), defaults: defaults(nil), narrowbandInput: { false })
        #expect(model.line.inactive)
    }
}
