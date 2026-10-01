import Engine
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// The microphone picker and the recording diagnostic in Settings › General.
///
/// Both exist because of the 1.7.12 accuracy report: dictation can silently land on a Bluetooth
/// headset mic that macOS runs at phone-call bandwidth, and when a dictation does come out wrong
/// there was no way to keep the audio that caused it. The rule here is that neither behaviour is
/// silent — the picker says which mic is in use and why, and the toggle says out loud when it is on.
@Suite("microphone selection and the recording diagnostic are visible in Settings")
@MainActor
struct MicrophoneSettingsTests {

    static func defaults() -> UserDefaults {
        UserDefaults(suiteName: "vp.micsettings.\(UUID().uuidString)")!
    }

    @Test("automatic is the default, and choosing a device writes the key the capture source reads")
    func selectionWritesThePolicyKey() {
        let d = Self.defaults()
        let model = AudioInputSettingsViewModel(defaults: d)
        #expect(model.selection == AudioInputSettingsViewModel.automatic)
        #expect(d.string(forKey: InputSelectionPolicy.preferredUIDKey) == nil)

        model.selection = "some-device-uid"
        #expect(d.string(forKey: InputSelectionPolicy.preferredUIDKey) == "some-device-uid",
                "the picker must write the same key InputSelectionPolicy reads, or it changes nothing")

        model.selection = AudioInputSettingsViewModel.automatic
        #expect(d.string(forKey: InputSelectionPolicy.preferredUIDKey) == nil,
                "back to Automatic must clear the pin, not leave a stale one")
    }

    @Test("V5 F3: the recording toggle is on by default (every dictation is stored) and writes the engine's own switch")
    func recordingToggleIsOnByDefault() {
        let d = Self.defaults()
        let model = AudioInputSettingsViewModel(defaults: d)
        #expect(model.saveRecordings, "F3: dictation audio is kept unless a person turned it off")
        #expect(UtteranceRecorder.isExplicitlyEnabled(d) == false, "other captures still need an explicit on")
        model.saveRecordings = true
        #expect(UtteranceRecorder.isEnabled(d))
        model.saveRecordings = false
        #expect(UtteranceRecorder.isEnabled(d) == false)
    }

    @Test("a device the user pinned but then unplugged falls back instead of showing a blank picker")
    func stalePinFallsBackToAutomatic() {
        let d = Self.defaults()
        d.set("a-device-that-is-not-here", forKey: InputSelectionPolicy.preferredUIDKey)
        let model = AudioInputSettingsViewModel(defaults: d)
        model.refresh()
        #expect(model.selection == AudioInputSettingsViewModel.automatic)
    }

    @Test("the note explains the substitution rather than making it silently")
    func theNoteIsWrittenForAPersonWhoDoesNotKnowWhatHFPIs() {
        let model = AudioInputSettingsViewModel(defaults: Self.defaults())
        let note = model.note
        #expect(!note.isEmpty)
        // Whatever this machine's devices are, the note has to name the mic in use — a note that
        // says nothing concrete is the silent behaviour this is meant to replace.
        #expect(note.contains("Using") || note.contains("VoicePlus is using")
                || note.contains("Dictation always uses") || note.contains("No microphone"))
    }

    @Test("a low-quality Bluetooth mic is labelled as such in the picker")
    func narrowbandBluetoothIsLabelled() {
        let model = AudioInputSettingsViewModel(defaults: Self.defaults())
        let airpods = AudioDeviceInfo(id: 0, uid: "ap", name: "AirPods Pro", transport: .bluetooth,
                                      sampleRate: 16_000, inputChannels: 1)
        let builtIn = AudioDeviceInfo(id: 0, uid: "bi", name: "MacBook Pro Microphone", transport: .builtIn,
                                      sampleRate: 48_000, inputChannels: 1)
        #expect(model.title(for: airpods).contains("low quality"))
        #expect(!model.title(for: builtIn).contains("low quality"))
    }

    @Test("the recordings summary counts utterances, not the three files each one writes")
    func recordingsSummaryCountsUtterances() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vp-sum-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = UtteranceRecorder(directory: dir)
        recorder.begin(device: nil, profile: .raw)
        [Float](repeating: 0.1, count: 1_600).withUnsafeBufferPointer { recorder.appendRaw($0) }
        recorder.appendProcessed([Float](repeating: 0.1, count: 1_600))
        _ = try recorder.finish()
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        #expect(files.count == 3, "one utterance writes raw, processed and a sidecar")
        #expect(Set(files.map(UtteranceRecorder.stamp(of:))).count == 1)
    }
}
