import Engine
import Foundation
import Testing
import Shared
@testable import VoicePlusApp

/// A2 / V4.10 — the start budget follows the device about to open, and a start that runs out of it
/// names that device (A03); a format mismatch is A04. Plus the stop drain the G0.2 handoff asked for.
@Suite("Adaptive start budget and start-failure copy (V4.10)", .serialized)
struct CaptureStartBudgetTests {

    static func device(_ name: String, _ transport: AudioDeviceInfo.Transport) -> AudioDeviceInfo {
        AudioDeviceInfo(id: 7, uid: name, name: name, transport: transport, sampleRate: 48_000, inputChannels: 1)
    }

    private func audio(over source: any AudioCaptureSource) -> PipelineAudioSource {
        var options = AudioPipeline.Options()
        options.noAudioTimeout = 0            // no HAL here; the watchdog has nothing to police
        let audio = PipelineAudioSource(pipeline: AudioPipeline(source: source, vad: EnergyVAD(), options: options))
        audio.requireMicrophonePermission = false
        return audio
    }

    /// A device that takes as long as the test says to open.
    final class SlowCaptureSource: AudioCaptureSource, @unchecked Sendable {
        let device: AudioDeviceInfo?
        var sink: ((UnsafeBufferPointer<Float>) -> Void)?
        var onDeviceChanged: ((AudioDeviceInfo?, AudioDeviceInfo?) -> Void)?
        let opened = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var _stops = 0
        var stops: Int { lock.withLock { _stops } }
        init(device: AudioDeviceInfo?) { self.device = device }
        func prewarm() throws {}
        func start() throws { opened.wait() }
        func stop() { lock.withLock { _stops += 1 } }
        func switchDevice(to device: AudioDeviceInfo?) throws {}
    }

    // MARK: budget

    @Test func budgetTable() {
        #expect(PipelineAudioSource.budget(for: .builtIn) == 3)
        #expect(PipelineAudioSource.budget(for: .usb) == 5)
        #expect(PipelineAudioSource.budget(for: .displayPort) == 5)
        #expect(PipelineAudioSource.budget(for: .bluetooth) == 8)
        #expect(PipelineAudioSource.budget(for: .other) == 8, "Continuity mics report as .other")
        #expect(PipelineAudioSource.budget(for: .virtual) == 8)
        #expect(PipelineAudioSource.budget(for: .aggregate) == 8)
        #expect(PipelineAudioSource.budget(for: nil) == 8, "unknown gets the generous budget")
        #expect(PipelineAudioSource.selfTestBudget == 15)
    }

    @Test func theBudgetFollowsTheDeviceAboutToOpen() {
        let builtIn = audio(over: FixtureCaptureSource(wav: WAVFile(sampleRate: 16_000, samples: []),
                                                       device: Self.device("MacBook Pro Microphone", .builtIn)))
        #expect(builtIn.startTimeout == 3)
        let airPods = audio(over: FixtureCaptureSource(wav: WAVFile(sampleRate: 16_000, samples: []),
                                                       device: Self.device("AirPods Pro", .bluetooth)))
        #expect(airPods.startTimeout == 8)
        let usb = audio(over: FixtureCaptureSource(wav: WAVFile(sampleRate: 16_000, samples: []),
                                                   device: Self.device("Scarlett Solo", .usb)))
        #expect(usb.startTimeout == 5)
        // `--mic-selftest` keeps its wide window.
        airPods.startTimeout = PipelineAudioSource.selfTestBudget
        #expect(airPods.startTimeout == 15)
    }

    // MARK: timeout → A03, naming the device

    @Test func aStartThatRunsOutOfBudgetNamesTheDeviceAndClosesTheLateStart() async throws {
        let source = SlowCaptureSource(device: Self.device("AirPods Pro", .bluetooth))
        let audio = audio(over: source)
        audio.startTimeout = 0.2
        let t0 = Date()
        #expect(throws: AudioCaptureError.startTimedOut(device: "AirPods Pro", seconds: 0.2)) {
            try audio.start(for: .engine)
        }
        #expect(Date().timeIntervalSince(t0) < 2)
        #expect(audio.currentOwner == nil, "a timed-out start must not leave the graph owned")

        // The device finally opens. Nobody owns it any more, so it is closed again rather than left
        // running with the microphone indicator lit behind an error.
        source.opened.signal()
        let deadline = Date().addingTimeInterval(3)
        while source.stops == 0, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(source.stops == 1, "the late start was left running with no owner")
    }

    @Test func startFailureCopyNamesTheDeviceAndKeepsTheCatalogueHeadline() throws {
        let timedOut = AudioCaptureError.startTimedOut(device: "AirPods Pro", seconds: 8)
        let sentence = try #require(timedOut.errorDescription)
        #expect(sentence.hasPrefix(CaptureRecoveryCopy.startFailedHeadline))
        #expect(sentence.contains("AirPods Pro"), "V4.10: say which device is slow")
        #expect(sentence.contains("8 s"))
        #expect(AudioCaptureError.formatMismatch(hardware: 48_000, client: 44_100).errorDescription
                == CaptureRecoveryCopy.formatMismatchHeadline)
        // Every other case keeps its old wording on every path.
        #expect(AudioCaptureError.noInputDevice.errorDescription == nil)
        #expect(AudioCaptureError.busy(owner: "engine").errorDescription == nil)
        // The notch reads the engine's message: A03 / A04 headlines, never a raw token or "timed out".
        let notch = EngineMessage.describe(timedOut)
        #expect(notch.hasPrefix(CaptureRecoveryCopy.startFailedHeadline))
        #expect(!notch.contains("startTimedOut"))
        #expect(EngineMessage.describe(AudioCaptureError.formatMismatch(hardware: 48_000, client: 44_100))
                .hasPrefix(CaptureRecoveryCopy.formatMismatchHeadline))
    }

    /// S11: the pill's second line is the entry's own consequence (A03 "Nothing was recorded.").
    @Test func thePillSubtitleStillSaysNothingWasTyped() {
        let lines = PillState.error(message: EngineMessage.describe(AudioCaptureError.startTimedOut(device: "AirPods Pro", seconds: 8))).messageLines
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix(CaptureRecoveryCopy.startFailedHeadline))
        #expect(lines[1] == RecoveryCatalog.entry(.A03).consequence)
    }

    /// The copy is the verified design's, not retyped: A03 and A04 as the fixture has them.
    @Test func headlinesMatchTheDesignCatalogue() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        let data = try Data(contentsOf: root.appendingPathComponent("Fixtures/design/design_copy.json"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let errors = try #require(json["errors"] as? [[String: Any]])
        func headline(_ id: String) -> String? { errors.first { $0["id"] as? String == id }?["headline"] as? String }
        #expect(headline(CaptureRecoveryCopy.startFailedID) == CaptureRecoveryCopy.startFailedHeadline)
        #expect(headline(CaptureRecoveryCopy.formatMismatchID) == CaptureRecoveryCopy.formatMismatchHeadline)
        #expect(CaptureRecoveryCopy.startFailedID == "A03")
        #expect(CaptureRecoveryCopy.formatMismatchID == "A04")
    }

    // MARK: stop drain (G0.2 handoff)

    final class ChunkCount: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        var value: Int { lock.withLock { n } }
        func bump() { lock.withLock { n += 1 } }
    }

    /// `stop()` used to cancel the forwarder the moment the pipeline stopped, dropping whatever the
    /// pipeline had queued at the end of the run — here, the final chunk flushed at stop. It now
    /// drains to `.stopped` first.
    @Test func stopDeliversTheEventsTheRunEndedWith() async throws {
        let source = FixtureCaptureSource(wav: WAVFile(sampleRate: 16_000, samples: []))
        let audio = audio(over: source)
        let chunks = ChunkCount()
        audio.onChunk = { _ in chunks.bump() }
        try audio.start(for: .engine)
        let tone = (0..<16_000).map { 0.1 * sin(Float($0) * 2 * .pi * 440 / 16_000) }
        source.push(tone)
        await audio.pipeline.drain()
        #expect(chunks.value == 0, "one second is under the 3 s chunk minimum: nothing yet")
        audio.stop()
        #expect(chunks.value == 1, "the tail chunk flushed at stop never reached onChunk")
        #expect(audio.currentOwner == nil)
    }
}
