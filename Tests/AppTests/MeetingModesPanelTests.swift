import Engine
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// V5 M1–M5 + M14 on the app side: auto-pick and override through the coordinator and the panel
/// driver, the panel's mode pill state and tracks, saved per-leg recordings, and tags in the panel.
@Suite("V5 M1–M5, M14 — meeting modes, recording, tags (app)")
@MainActor
struct MeetingModesPanelTests {
    static func temp() -> MeetingStore {
        MeetingStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("vp-m1app-\(UUID().uuidString)"))
    }

    static func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    // MARK: Coordinator (detector path)

    @Test("coordinator: auto-picks in person (system audio not opened), the override opens it, the record keeps the mode")
    func coordinatorAutoPickAndOverride() async throws {
        let store = Self.temp()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let coordinator = MeetingCoordinator(store: store)
        coordinator.makeSession = { prompt in
            MeetingSession(title: prompt.title, transcriber: MeetingEchoTranscriber(), labeler: ChannelLabeler(), store: store)
        }
        let mic = MeetingFakeSource(), system = MeetingFakeSource()
        coordinator.makeCapture = {
            DualCapture(mic: mic, system: system, micVAD: MeetingAlwaysSpeechVAD(), systemVAD: MeetingNeverSpeechVAD(),
                        aec: PassthroughEchoCanceller())
        }
        coordinator.modeSignals = { _ in MeetingModeSignals(systemAudioActive: false, callAppFrontmost: true) }
        var notes: MeetingRecord?
        coordinator.onNotes = { notes = $0 }
        coordinator.apply(.calendar([CalendarMeeting(id: "e", title: "Walk-in", start: Date(), end: Date().addingTimeInterval(900))]))
        coordinator.apply(.cameraStarted)
        coordinator.choose(.record)
        await Self.waitUntil { mic.isRunning }
        #expect(coordinator.mode == .inPerson)
        #expect(mic.isRunning && !system.isRunning, "in person: system audio is never opened")
        mic.push(seconds: 0.5)

        await coordinator.setMode(.videoCall)
        #expect(system.isRunning, "the override opens system audio now")
        #expect(coordinator.mode == .videoCall)

        coordinator.apply(.recordingStopped)
        await Self.waitUntil { notes != nil }
        let record = try #require(notes)
        #expect(record.mode == .videoCall)
        let saved = store.directory(for: record.id).appendingPathComponent(MeetingAudioRecorder.micFileName)
        #expect(FileManager.default.fileExists(atPath: saved.path), "M5: saved by default (Always)")
    }

    // MARK: Panel driver (manual path)

    @Test("driver: mode reported at start; Never saves no audio; Always writes per-leg WAVs on one clock")
    func driverModesAndRecording() async throws {
        for save in [MeetingRecordingSaveMode.never, .always] {
            let store = Self.temp()
            defer { try? FileManager.default.removeItem(at: store.root) }
            let settings = InMemorySettingsStore()
            MeetingSettings.setSaveRecording(save, store: settings)
            let mic = MeetingFakeSource(), system = MeetingFakeSource()
            let driver = MeetingSessionCaptureDriver(
                makeSession: { prompt in
                    MeetingSession(title: prompt.title, transcriber: MeetingEchoTranscriber(), labeler: ChannelLabeler(), store: store)
                },
                makeCapture: {
                    DualCapture(mic: mic, system: system, micVAD: MeetingAlwaysSpeechVAD(), systemVAD: MeetingNeverSpeechVAD(),
                                aec: PassthroughEchoCanceller())
                },
                store: store, settings: settings,
                modeSignals: { MeetingModeSignals(systemAudioActive: true, callAppFrontmost: true) })
            driver.drainInterval = 60
            let started = try await driver.start(title: "Call", onUtterance: { _ in }, onSystemAudioLost: {})
            #expect(started.mode == .videoCall && started.systemAudio)
            #expect(system.isRunning)
            mic.push(seconds: 0.5); system.push(seconds: 0.5)
            #expect(await driver.setMode(.inPerson))
            #expect(!system.isRunning, "in person closes system audio")
            mic.push(seconds: 0.25)
            let record = try await driver.stop(MeetingCaptureSummary(pauseCount: 0, pausedSeconds: 0))
            #expect(record.mode == .inPerson)
            let dir = store.directory(for: record.id)
            let micFile = dir.appendingPathComponent(MeetingAudioRecorder.micFileName)
            let sysFile = dir.appendingPathComponent(MeetingAudioRecorder.systemFileName)
            if save == .never {
                #expect(!FileManager.default.fileExists(atPath: micFile.path))
                #expect(MeetingFilesStore(store: store).retainedAudio(for: record.id) == nil)
            } else {
                #expect(try WAVFile.read(url: micFile).samples.count == 12_000)
                #expect(try WAVFile.read(url: sysFile).samples.count == 8_000, "system leg saved while it was open")
                #expect(MeetingFilesStore(store: store).retainedAudio(for: record.id)?.lastPathComponent == MeetingAudioRecorder.micFileName)
                #expect(MeetingRecordingAudio.locate(in: dir)?.legs.count == 2, "M8 re-diarization finds both legs")
            }
        }
    }

    // MARK: Panel state

    @Test("panel: mode pill state, in-person tracks say system audio is off (no missing notice), override goes to the driver")
    func panelModeState() async {
        let driver = ModeScriptedDriver()
        let controller = MeetingCaptureController(driver: driver)
        controller.tickInterval = 0
        #expect(await controller.start(title: "Room"))
        #expect(controller.state.mode == .inPerson)
        var content = MeetingPanelContent(state: controller.state, now: Date())
        #expect(content.tracks.map(\.condition) == [.recording, .off])
        #expect(content.notice == nil)

        await controller.setMode(.hybrid)
        #expect(driver.modes == [.hybrid])
        #expect(controller.state.mode == .hybrid)
        content = MeetingPanelContent(state: controller.state, now: Date())
        #expect(content.tracks.map(\.condition) == [.recording, .recording])

        driver.systemOpens = false
        await controller.setMode(.videoCall)
        #expect(controller.state.problem == .systemAudioMissing, "system audio refused for the new mode is shown")
        await controller.setMode(.inPerson)
        #expect(controller.state.problem == nil)
        #expect(MeetingPanelContent(state: controller.state, now: Date()).notice == nil)
    }

    @Test("panel: late tags reach the transcript; dictated / command / note are labelled; the switch hides dictations")
    func panelTags() async {
        let driver = ModeScriptedDriver()
        let controller = MeetingCaptureController(driver: driver)
        controller.tickInterval = 0
        #expect(await controller.start(title: "Tags"))
        let plain = MeetingUtterance(speaker: .you, text: "let's start", range: 0...2, confidence: 0.9)
        let dictated = MeetingUtterance(speaker: .you, text: "email Priya the deck", range: 3...5, confidence: 0.9, tag: .dictate)
        let command = MeetingUtterance(speaker: .you, text: "open the roadmap", range: 6...7, confidence: 0.9, tag: .act)
        let note = MeetingUtterance(speaker: .you, text: "remember the budget", range: 8...9, confidence: 0.9, tag: .note)
        driver.transcript?(MeetingTranscript(utterances: [plain, dictated, command, note]))
        await Self.waitUntil { controller.state.utterances.count == 4 }
        #expect(controller.panelLines.map(\.tag) == [nil, "dictated", "command", "note"])

        controller.showsDictations = false
        #expect(controller.panelLines.map(\.line.text) == ["let's start", "open the roadmap", "remember the budget"])
        await Self.waitUntil { driver.keeps == [true, false] }
        #expect(driver.keeps == [true, false], "the meeting is told, so the saved transcript leaves them out too")
    }

    @Test("M14 switch defaults on and is stored under its key")
    func dictationSwitch() {
        let settings = InMemorySettingsStore()
        #expect(MeetingCaptureSetup.showsDictations(settings))
        #expect(MeetingCaptureSetup.showsDictations(nil))
        MeetingCaptureSetup.setShowsDictations(false, settings: settings)
        #expect(settings.bool(SettingsKeys.meetingShowDictations) == false)
        #expect(!MeetingCaptureSetup.showsDictations(settings))
    }

    @Test("M5: the sweep uses the 7-day setting and leaves Always recordings alone")
    func sweepFollowsSetting() throws {
        let store = Self.temp()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let dir = store.directory(for: "old")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(MeetingAudioRecorder.micFileName)
        try Data(count: 10).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-9 * 86_400)], ofItemAtPath: file.path)
        let settings = InMemorySettingsStore()
        #expect(MeetingCaptureSetup.sweep(store: store, settings: settings, diskCap: 1_000_000, otherBytes: 0).expired == 0)
        MeetingSettings.setSaveRecording(.sevenDays, store: settings)
        #expect(MeetingCaptureSetup.sweep(store: store, settings: settings, diskCap: 1_000_000, otherBytes: 0).expired == 1)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}

/// A driver that does modes without hardware.
final class ModeScriptedDriver: MeetingCaptureDriving, MeetingCaptureModeDriving, @unchecked Sendable {
    var modes: [MeetingMode] = []
    var keeps: [Bool] = []
    var systemOpens = true
    var transcript: (@Sendable (MeetingTranscript) -> Void)?

    func start(title: String, onUtterance: @escaping @Sendable (MeetingUtterance) -> Void,
               onSystemAudioLost: @escaping @Sendable () -> Void) async throws -> MeetingCaptureStart {
        MeetingCaptureStart(meetingID: "m", systemAudio: true, mode: .inPerson)
    }
    func pause() async {}
    func resume() async throws {}
    func stop(_ summary: MeetingCaptureSummary) async throws -> MeetingRecord { MeetingRecord(title: "x") }

    func setMode(_ mode: MeetingMode) async -> Bool {
        modes.append(mode)
        return !mode.legs.capturesSystem || systemOpens
    }
    func observeTranscript(_ handler: @escaping @Sendable (MeetingTranscript) -> Void) { transcript = handler }
    func setKeepsDictations(_ keep: Bool) async { keeps.append(keep) }
}
