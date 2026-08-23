import Foundation
import Shared
import Testing
@testable import VoicePlusApp

@Suite("Pill state reducer (T2)")
struct PillReducerTests {
    @Test func coversAllFiveStatesFromEngineStates() {
        var r = PillStateReducer()
        #expect(r.reduce(.prewarming) == .idle)
        #expect(r.reduce(.listening(level: 0.4)) == .listening(level: 0.4))
        #expect(r.reduce(.previewing(text: "hello")) == .preview(text: "hello"))
        #expect(r.reduce(.finalizing) == .landing)
        #expect(r.reduce(.landed) == .landing)
        let bad = MicQuality(snr: 3, clipping: 0, lowLevel: true, verdict: .bad)
        #expect(r.reduce(.warning(bad)) == .warning(bad))
        #expect(r.reduce(.idle) == .hidden)
        #expect(!r.state.isVisible)
    }

    @Test func warningIsStickyThroughListeningUntilTextArrives() {
        var r = PillStateReducer()
        let poor = MicQuality(snr: 8, clipping: 0.1, lowLevel: false, verdict: .poor)
        r.reduce(.warning(poor))
        #expect(r.reduce(.listening(level: 0.9)) == .warning(poor))
        #expect(r.reduce(.previewing(text: "ok")) == .preview(text: "ok"))
        #expect(r.reduce(.listening(level: 0.2)) == .listening(level: 0.2))
    }

    @Test func clearWarningDropsToListening() {
        var r = PillStateReducer()
        r.reduce(.warning(.unknownGood))
        r.clearWarning(level: 0.3)
        #expect(r.state == .listening(level: 0.3))
    }

    @Test func errorShowsInPillAndIdleHides() {
        var r = PillStateReducer()
        #expect(r.reduce(.error("boom")).caseName == "preview")
        r.hide()
        #expect(r.state == .hidden)
    }
}

@Suite("Waveform model")
struct WaveformTests {
    @Test func pushShiftsAndSmooths() {
        var w = WaveformModel(barCount: 4, smoothing: 0)
        w.push(level: 1)
        #expect(w.bars == [0, 0, 0, 1])
        w.push(level: 2) // clamped
        #expect(w.bars == [0, 0, 1, 1])
        w.reset()
        #expect(w.peak == 0)
        var s = WaveformModel(barCount: 2, smoothing: 0.5)
        s.push(level: 1)
        #expect(s.bars.last == 0.5)
    }
}

@Suite("Pill view model")
struct PillViewModelTests {
    @Test @MainActor func appliesEngineStateAndFeedsWaveform() {
        let vm = PillViewModel()
        vm.apply(.listening(level: 0.8))
        #expect(vm.state.caseName == "listening")
        #expect(vm.waveform.peak > 0)
        vm.apply(.idle)
        #expect(vm.state == .hidden)
        #expect(vm.waveform.peak == 0)
    }

    @Test @MainActor func mockEngineDrivesPillThroughFullCycle() async throws {
        let fixture = TranscriptFixture(name: "t", spans: [
            .init(text: "hello", confidence: 0.9, audioStart: 0, audioEnd: 0.5),
            .init(text: "world", confidence: 0.8, audioStart: 0.5, audioEnd: 1),
        ])
        let engine = MockEngine(fixture: fixture, delayScale: 0, prewarmMs: 0)
        var seen: [String] = []
        var reducer = PillStateReducer()
        let events = engine.events()
        let task = Task {
            for await event in events {
                if case .state(let s) = event { seen.append(reducer.reduce(s).caseName) }
            }
        }
        // AsyncStream registers its continuation lazily on first iteration, so give the
        // consumer task a turn on the main actor before start() emits `.listening`.
        // Under a loaded parallel test run fixed sleeps are not enough, so poll (bounded ~5s).
        try await Task.sleep(nanoseconds: 20_000_000)
        try await engine.start(prewarm: true)
        for _ in 0..<100 where !seen.contains("listening") { try await Task.sleep(nanoseconds: 50_000_000) }
        let final = try await engine.stop()
        for _ in 0..<100 where seen.last != "hidden" { try await Task.sleep(nanoseconds: 50_000_000) }
        task.cancel()
        #expect(final.joinedText == "hello world")
        #expect(seen.contains("listening"))
        #expect(seen.contains("landing"))
        #expect(seen.last == "hidden")
    }
}
