import Combine
import Engine
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// FIX 3 regression cover: `DictationCoordinator` bound the pill with `bind(engineState:)` only —
/// never passing `audioLevel:` — so the waveform's only source was `EngineState.listening(level:)`,
/// which the engine stops emitting the instant a preview arrives. The pill's waveform froze
/// mid-utterance (and showed nothing at all once the first partial landed).
@Suite("Pill waveform is driven by captured audio (FIX 3)")
struct PillWaveformTests {
    /// Let the `receive(on: .main)` hops in `PillViewModel.bind` land.
    @MainActor private func settle() async {
        for _ in 0..<20 { await Task.yield(); try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    /// The required case: a level published while the pill is showing a preview still moves bars.
    @Test @MainActor func levelPublishedWhilePreviewingReachesThePillModel() async {
        let state = CurrentValueSubject<EngineState, Never>(.listening(level: 0))
        let levels = PassthroughSubject<Float, Never>()
        let model = PillViewModel()
        model.bind(engineState: state.eraseToAnyPublisher(), audioLevel: levels.eraseToAnyPublisher())

        state.send(.previewing(text: "hello there"))
        await settle()
        #expect(model.state == .preview(text: "hello there"))
        let before = model.waveform.peak

        levels.send(0.9)
        levels.send(0.9)
        await settle()
        #expect(model.state == .preview(text: "hello there"), "levels must not disturb the preview text")
        #expect(model.waveform.peak > before, "the waveform froze once the preview arrived")
    }

    /// Real capture path, everything but the HAL: pipeline `.level(rms:)` → `PipelineAudioSource`
    /// → the coordinator's level subject → pill model, while the engine sits in `.previewing`.
    @Test @MainActor func capturedPipelineLevelsDriveTheWaveform() async throws {
        let source = FixtureCaptureSource(wav: WAVFile(sampleRate: 16_000, samples: []))
        let audio = PipelineAudioSource(pipeline: AudioPipeline(source: source, vad: EnergyVAD()))
        audio.requireMicrophonePermission = false

        let state = CurrentValueSubject<EngineState, Never>(.previewing(text: "half a sentence"))
        let model = PillViewModel()
        let levels = PassthroughSubject<Float, Never>()
        model.bind(engineState: state.eraseToAnyPublisher(), audioLevel: levels.eraseToAnyPublisher())
        // Exactly what `DictationCoordinator.bindWaveform(to:)` installs (the coordinator itself
        // needs a live `NSPanel`, which a headless test process cannot host).
        audio.onLevel = { level in levels.send(level) }

        try audio.start()
        let n = 16_000
        source.push((0..<n).map { 0.2 * sin(Float($0) * 2 * .pi * 440 / 16_000) })
        await audio.pipeline.drain()
        audio.stop()
        await settle()

        #expect(model.state == .preview(text: "half a sentence"))
        #expect(model.waveform.peak > 0, "captured audio never reached the pill waveform")
    }

    /// The fixture / mock-engine path has no capture pipeline: `.listening(level:)` must still drive
    /// the bars (`VOICEPLUS_FIXTURE` demos and the Lab depend on it).
    @Test @MainActor func mockEngineStatesStillDriveTheWaveform() async {
        let state = CurrentValueSubject<EngineState, Never>(.idle)
        let model = PillViewModel()
        model.bind(engineState: state.eraseToAnyPublisher(), audioLevel: nil)
        state.send(.listening(level: 0.8))
        await settle()
        #expect(model.waveform.peak > 0)
    }

    /// One bar per block: captured levels take over, engine states stop double-pushing.
    @Test @MainActor func capturedLevelsSuppressDuplicateEngineStateBars() {
        let model = PillViewModel()
        model.push(capturedLevel: 0.5)
        let afterCaptured = model.waveform.bars
        model.apply(.listening(level: 0.5))
        #expect(model.waveform.bars == afterCaptured, "the same audio pushed a second bar")
        // …and once capture stops, engine levels drive the bars again.
        model.apply(.idle)
        model.apply(.listening(level: 0.9))
        #expect(model.waveform.peak > 0)
    }
}
