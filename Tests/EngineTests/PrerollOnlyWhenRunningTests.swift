import Foundation
import Testing
import Shared
@testable import Engine

/// C3 (V4.23) — the pre-roll pads a press only when the capture graph was already running before
/// the key went down. A press that opened the microphone itself gets no pad: 0.5 s of held audio
/// in front of a near-zero tap is what used to push it over the recognizer's 300 ms floor and
/// hand room tone to the decoder.
///
/// `AcousticCaptureSource` (A4 split pre-roll off `prewarm()` into `beginPreroll()`) is driven here
/// against a fake inner device that, like real hardware, delivers audio only while it is running.
@Suite("C3 pre-roll only when the graph was already running")
struct PrerollOnlyWhenRunningTests {
    /// A device in miniature: counts opens, and delivers pushed audio only while open.
    private final class FakeInnerDevice: AudioCaptureSource, @unchecked Sendable {
        var sink: ((UnsafeBufferPointer<Float>) -> Void)?
        var onDeviceChanged: ((AudioDeviceInfo?, AudioDeviceInfo?) -> Void)?
        var device: AudioDeviceInfo? = AudioDeviceInfo(id: 7, uid: "fake-bt", name: "Fake AirPods",
                                                       transport: .bluetooth, sampleRate: 16_000, inputChannels: 1)
        private(set) var prewarms = 0
        private(set) var starts = 0
        private(set) var isRunning = false

        func prewarm() throws { prewarms += 1 }
        func start() throws { starts += 1; isRunning = true }
        func stop() { isRunning = false }
        func switchDevice(to device: AudioDeviceInfo?) throws { self.device = device }

        /// Audio arriving from the microphone. A closed device delivers nothing.
        func deliver(_ value: Float, seconds: Double) {
            guard isRunning else { return }
            let block = [Float](repeating: value, count: Int(seconds * 16_000))
            block.withUnsafeBufferPointer { sink?($0) }
        }
    }

    private static let prePress: Float = 0.25
    private static let live: Float = 0.75
    private static let profile = RobustnessProfile(noiseSuppression: false, aec: .off, prerollSeconds: 0.5)

    private func rig() -> (AcousticCaptureSource, FakeInnerDevice, Box) {
        let inner = FakeInnerDevice()
        let src = AcousticCaptureSource(wrapping: inner, profile: Self.profile)
        src.isRecordingEnabled = { false }
        let box = Box()
        src.sink = { box.samples.append(contentsOf: $0) }
        return (src, inner, box)
    }

    private final class Box: @unchecked Sendable { var samples: [Float] = [] }

    // MARK: the two paths

    /// Path 1 — the graph was already running before key-down (pre-roll armed): the press is
    /// padded with the newest `prerollSeconds` of what the device heard, then live audio follows,
    /// and the device is not opened a second time.
    @Test func pressIntoARunningGraphIsPaddedWithTheHeldAudio() throws {
        let (src, inner, box) = rig()
        try src.beginPreroll()
        #expect(inner.starts == 1)
        inner.deliver(Self.prePress, seconds: 0.8)          // before the key: held, not delivered
        #expect(box.samples.isEmpty)

        try src.start()                                      // key-down
        #expect(inner.starts == 1, "a running graph is not reopened")
        #expect(src.prerollFlushed == 8_000)
        #expect(box.samples.count == 8_000)
        #expect(box.samples.allSatisfy { $0 == Self.prePress })

        inner.deliver(Self.live, seconds: 0.2)
        #expect(box.samples.count == 8_000 + 3_200)
        #expect(box.samples.suffix(3_200).allSatisfy { $0 == Self.live })
        src.stop()
    }

    /// Path 2 — the press opened the microphone (graph prepared, not running): no pad at all. The
    /// first sample the pipeline sees is the first sample captured after the key went down.
    @Test func pressThatOpensTheMicrophoneIsNeverPadded() throws {
        let (src, inner, box) = rig()
        try src.prewarm()                                    // launch warm-up: mic stays closed
        #expect(inner.prewarms == 1)
        #expect(inner.starts == 0)
        inner.deliver(Self.prePress, seconds: 0.8)           // closed device: nothing arrives

        try src.start()                                      // key-down opens the device
        #expect(inner.starts == 1)
        #expect(src.prerollFlushed == 0)
        #expect(box.samples.isEmpty, "a press that opened the microphone was padded")
        inner.deliver(Self.live, seconds: 0.2)
        #expect(box.samples.count == 3_200)
        #expect(box.samples.allSatisfy { $0 == Self.live })
        src.stop()
    }

    /// The pad belongs to one press. After a padded turn ends, the next press — which opens the
    /// microphone again — starts clean.
    @Test func aPaddedTurnDoesNotPadTheNextPress() throws {
        let (src, inner, box) = rig()
        try src.beginPreroll()
        inner.deliver(Self.prePress, seconds: 0.8)
        try src.start()
        #expect(src.prerollFlushed == 8_000)
        src.stop()

        box.samples.removeAll()
        try src.start()
        #expect(src.prerollFlushed == 0)
        #expect(box.samples.isEmpty)
        inner.deliver(Self.live, seconds: 0.1)
        #expect(box.samples.count == 1_600)
        #expect(box.samples.allSatisfy { $0 == Self.live })
        src.stop()
    }

    // MARK: why it matters — through the engine

    /// Bridges the capture wrapper to the `AudioSource` the engine consumes.
    private final class CaptureBridge: AudioSource, @unchecked Sendable {
        var sink: ((UnsafeBufferPointer<Float>) -> Void)?
        let capture: AcousticCaptureSource
        init(_ capture: AcousticCaptureSource) {
            self.capture = capture
            capture.sink = { [weak self] in self?.sink?($0) }
        }
        func prewarm() throws { try capture.prewarm() }
        func start() throws { try capture.start() }
        func stop() { capture.stop() }
    }

    /// A 0.1 s tap that opened the microphone stays under the recognizer's floor: the decoder is
    /// never asked. (With the old pad it would have been 0.6 s of mostly room tone.)
    @Test func nearZeroTapThatOpenedTheMicIsNotPushedOverTheFloor() async throws {
        let inner = FakeInnerDevice()
        let capture = AcousticCaptureSource(wrapping: inner, profile: Self.profile)
        capture.isRecordingEnabled = { false }
        let bridge = CaptureBridge(capture)
        let spy = SpyFinal([TranscriptSpan(text: "you", confidence: 0.9, audioRange: 0...1, provenance: [.asr])])
        let engine = RealEngine(audio: bridge, provider: StaticRecognizerProvider(final: spy, preview: nil))

        try await engine.start(prewarm: true)
        inner.deliver(Self.live, seconds: 0.1)
        for _ in 0..<200 where await engine.bufferedSampleCount() < 1_600 { try? await Task.sleep(nanoseconds: 2_000_000) }
        // Checked before release: `stop()` clears the wrapper's per-turn counters.
        #expect(capture.prerollFlushed == 0)
        #expect(await engine.bufferedSampleCount() == 1_600)
        let spans = try await engine.stop()

        #expect(spans.isEmpty)
        #expect(spy.calls == 0)
        #expect(engine.lastStopReason == .tooShort)
    }
}
