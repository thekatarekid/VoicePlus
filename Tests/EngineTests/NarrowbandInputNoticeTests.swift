import Foundation
import Shared
import Testing
@testable import Engine

/// V5 C3 — "Headset is in call mode — quality reduced". The input policy's two narrowband outcomes
/// (landed on an 8/16 kHz SCO mic, or walked away from one) both become a notice; nothing else does.
/// Real HFP/SCO switching needs a headset (T1); here the capture source runs on the fake HAL driver.
@Suite("V5 C3 — narrowband Bluetooth warning")
struct NarrowbandInputNoticeTests {
    typealias Fixtures = CaptureLifecycleTests
    static let scoNarrow = AudioDeviceInfo(id: 21, uid: "airpods-sco", name: "AirPods Pro", transport: .bluetooth, sampleRate: 8_000, inputChannels: 1)
    static let scoWide = AudioDeviceInfo(id: 22, uid: "airpods-msbc", name: "AirPods Pro", transport: .bluetooth, sampleRate: 16_000, inputChannels: 1)
    static let leAudio = Fixtures.airPods   // 24 kHz: not call mode

    @Test("capturing on an 8 or 16 kHz SCO mic shows the build doc's chip", arguments: [scoNarrow, scoWide])
    func capturingOnSCO(_ headset: AudioDeviceInfo) throws {
        let n = try #require(NarrowbandInputNotice.evaluate(device: headset, avoided: nil))
        #expect(n.kind == .capturing)
        #expect(n.chip == "Headset is in call mode — quality reduced")
        #expect(n.reasonCode == "narrowbandInput.capturing")
        #expect(!n.reasonCode.contains("AirPods"), "diagnostics carry no device names")
    }

    @Test func avoidedSCONamesTheMicInUse() throws {
        let n = try #require(NarrowbandInputNotice.evaluate(device: Fixtures.builtIn, avoided: Self.scoWide))
        #expect(n.kind == .avoided)
        #expect(n.chip == "Headset is in call mode — using MacBook Pro Microphone")
    }

    @Test func nothingToSayOtherwise() {
        #expect(NarrowbandInputNotice.evaluate(device: Fixtures.builtIn, avoided: nil) == nil)
        #expect(NarrowbandInputNotice.evaluate(device: Self.leAudio, avoided: nil) == nil, "24 kHz is not call mode")
        #expect(NarrowbandInputNotice.evaluate(device: nil, avoided: nil) == nil)
        #expect(NarrowbandInputNotice.evaluate(device: Fixtures.builtIn, avoided: Fixtures.usb) == nil)
    }

    @Test func gateRepeatsCapturingButAnnouncesAnAvoidedHeadsetOnce() {
        var gate = NarrowbandNoticeGate()
        let capturing = NarrowbandInputNotice.evaluate(device: Self.scoWide, avoided: nil)
        let avoided = NarrowbandInputNotice.evaluate(device: Fixtures.builtIn, avoided: Self.scoWide)
        let shown = [gate.shouldShow(nil), gate.shouldShow(avoided), gate.shouldShow(avoided),
                     gate.shouldShow(capturing), gate.shouldShow(capturing), gate.shouldShow(avoided)]
        // nil → never; avoided → once per headset per session; capturing → every turn (each one is
        // reduced); captured from in between → the avoidance is worth saying again.
        #expect(shown == [false, true, false, true, true, true])
    }

    // MARK: through the capture source (fake HAL)

    @Test func policyAvoidingTheDefaultHeadsetIsReportedBySourceAndWrapper() throws {
        let driver = Fixtures.FakeCaptureDriver(devices: [Fixtures.builtIn, Self.scoWide], defaultDevice: Self.scoWide)
        let inner = CoreAudioCaptureSource(policy: Fixtures.cleanPolicy(), driver: driver, idleReleaseAfter: 0)
        let src = AcousticCaptureSource(wrapping: inner, profile: .default)
        try src.prewarm()
        #expect(src.device == Fixtures.builtIn)
        #expect(inner.avoidedNarrowbandInput == Self.scoWide)
        #expect(src.avoidedNarrowbandInput == Self.scoWide, "the acoustic wrapper forwards it")
        let n = try #require(NarrowbandInputNotice.evaluate(source: src))
        #expect(n.kind == .avoided)
        inner.release(reason: .quit)
    }

    @Test func landingOnTheOnlyInputHeadsetIsCapturing() throws {
        let driver = Fixtures.FakeCaptureDriver(devices: [Self.scoNarrow], defaultDevice: Self.scoNarrow)
        let src = CoreAudioCaptureSource(policy: Fixtures.cleanPolicy(), driver: driver, idleReleaseAfter: 0)
        try src.prewarm()
        #expect(src.device == Self.scoNarrow)
        #expect(src.avoidedNarrowbandInput == nil)
        #expect(NarrowbandInputNotice.evaluate(source: src)?.kind == .capturing)
        src.release(reason: .quit)
    }

    @Test func routeChangeToAHeadsetRecordsTheAvoidance() throws {
        let driver = Fixtures.FakeCaptureDriver(devices: [Fixtures.builtIn], defaultDevice: Fixtures.builtIn)
        let src = CoreAudioCaptureSource(policy: Fixtures.cleanPolicy(), driver: driver, idleReleaseAfter: 0)
        try src.start()
        #expect(NarrowbandInputNotice.evaluate(source: src) == nil)
        driver.changeDefault(to: Self.scoWide)   // AirPods connect and macOS makes them the default
        #expect(src.device == Fixtures.builtIn, "policy keeps the Mac mic")
        #expect(NarrowbandInputNotice.evaluate(source: src)?.kind == .avoided)
        src.stop()
        src.release(reason: .quit)
    }

    @Test func aSourceThatCannotReportStillWarnsWhenCapturingOnAHeadset() throws {
        final class Plain: AudioCaptureSource, @unchecked Sendable {
            var device: AudioDeviceInfo? = NarrowbandInputNoticeTests.scoWide
            var sink: ((UnsafeBufferPointer<Float>) -> Void)?
            var onDeviceChanged: ((AudioDeviceInfo?, AudioDeviceInfo?) -> Void)?
            func prewarm() throws {}
            func start() throws {}
            func stop() {}
            func switchDevice(to device: AudioDeviceInfo?) throws {}
        }
        #expect(NarrowbandInputNotice.evaluate(source: Plain())?.kind == .capturing)
    }
}
