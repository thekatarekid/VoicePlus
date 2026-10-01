import CoreVideo
import Engine
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// V5 LR5 — camera only while a mode is on; a frame is borrowed for the callback only, never older
/// than a second, never written anywhere; crops beyond the 1 s pre-roll only for an utterance.
@Suite(.serialized) struct CameraPrivacyTests {
    final class Clock: @unchecked Sendable { var t: TimeInterval = 100 }

    final class Auth: CameraAuthorizing, @unchecked Sendable {
        func status() -> PermissionStatus { .granted }
        func request() async -> Bool { true }
    }

    final class Capture: CameraCapturing {
        var isRunning = false
        func start(frameRate: Int, onFrame: @escaping (CVPixelBuffer, TimeInterval) -> Void) throws { isRunning = true }
        func stop() { isRunning = false }
    }

    final class Calls: @unchecked Sendable { var n = 0 }

    /// A face with a mouth in the middle of every frame; counts how often Vision would have run.
    struct MouthLandmarks: FaceLandmarking {
        let calls: Calls
        func analyze(_ pixelBuffer: CVPixelBuffer, time: TimeInterval) -> FaceAnalysis {
            calls.n += 1
            return FaceAnalysis(frame: FaceFrame(time: time, facePresent: true, mouthOpen: 0.2, yaw: 0),
                                mouthRect: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.1))
        }
    }

    static func pixelBuffer() throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 48, kCVPixelFormatType_32BGRA, nil, &pb)
        return try #require(pb)
    }

    func make() -> (CameraService, Capture, Clock, Calls) {
        let cap = Capture(), clock = Clock(), calls = Calls()
        let svc = CameraService(settings: InMemorySettingsStore(), authorization: Auth(), capture: cap,
                                landmarker: MouthLandmarks(calls: calls), now: { clock.t })
        return (svc, cap, clock, calls)
    }

    @Test func framesOnlyWhileTheModeIsOn() async throws {
        let (svc, _, clock, calls) = make()
        let pb = try Self.pixelBuffer()
        svc.handleFrame(pb, time: clock.t)
        #expect(calls.n == 0 && svc.mouthCrops.count == 0, "mode off: the frame is not even looked at")
        _ = await svc.setMode(.fused)
        svc.handleFrame(pb, time: clock.t)
        #expect(calls.n == 1 && svc.mouthCrops.count == 1)
        _ = await svc.setMode(.off)
        svc.handleFrame(pb, time: clock.t)   // a late callback after stop
        #expect(calls.n == 1 && svc.mouthCrops.count == 0 && !svc.isCameraOn)
    }

    @Test func staleFramesAreDroppedUnread() async throws {
        let (svc, _, clock, calls) = make()
        _ = await svc.setMode(.fused)
        let pb = try Self.pixelBuffer()
        svc.handleFrame(pb, time: clock.t - CameraService.maxFrameAge - 0.01)
        #expect(calls.n == 0 && svc.mouthCrops.count == 0)
        svc.handleFrame(pb, time: clock.t - 0.5)
        #expect(calls.n == 1)
    }

    @Test func theFrameIsNotRetainedPastTheCallback() async throws {
        let (svc, _, clock, _) = make()
        _ = await svc.setMode(.fused)
        let pb = try Self.pixelBuffer()
        let before = CFGetRetainCount(pb)
        for i in 0..<10 { svc.handleFrame(pb, time: clock.t - 0.9 + Double(i) * 0.04) }
        #expect(CFGetRetainCount(pb) <= before, "nothing on the camera path kept a reference to the frame")
    }

    @Test func idleCropsStayUnderOneSecondAndAnUtteranceIsBracketedByCapture() async throws {
        let (svc, _, clock, _) = make()
        _ = await svc.setMode(.fused)
        let pb = try Self.pixelBuffer()
        func run(_ seconds: Double) {
            for _ in 0..<Int(seconds * 25) { clock.t += 0.04; svc.handleFrame(pb, time: clock.t) }
        }
        run(10)
        #expect(svc.mouthCrops.heldSpan <= 1, "idle: a 1 s pre-roll only")
        svc.noteAudioEvent(.started(device: nil))
        run(3)
        #expect(svc.mouthCrops.heldSpan > 3)
        svc.noteAudioEvent(.stopped(totalSamples: 48_000))
        let clip = try #require(svc.mouthCrops.visualClip(duration: 3))
        #expect(clip.frames.count >= 70, "the fused recogniser reads the whole utterance once")
        run(1)
        #expect(svc.mouthCrops.heldSpan <= 1)
    }

    @Test func signalsModeKeepsNoCrops() async throws {
        let (svc, _, clock, _) = make()
        _ = await svc.setMode(.signals)
        svc.noteAudioEvent(.started(device: nil))
        let pb = try Self.pixelBuffer()
        for _ in 0..<50 { clock.t += 0.04; svc.handleFrame(pb, time: clock.t) }
        #expect(svc.mouthCrops.count == 0 && !svc.mouthCrops.isUtteranceOpen)
    }

    /// The behaviour half of the audit (like `AmbientInjectionAudit`): a camera session writes no
    /// file anywhere we can see — app support, caches, temp.
    @Test func aCameraSessionWritesNoFiles() async throws {
        let dirs = [FileManager.default.temporaryDirectory, AppPaths.supportDirectory(),
                    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]]
        let media: Set<String> = ["png", "jpg", "jpeg", "heic", "mov", "mp4", "raw", "bgra", "tiff"]
        /// Two levels deep — where a careless write would land; model trees are not walked.
        func snapshot() -> Set<String> {
            var out = Set<String>()
            func walk(_ d: URL, depth: Int) {
                let items = (try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
                for u in items {
                    if media.contains(u.pathExtension.lowercased()) { out.insert(u.path) }
                    if depth > 0, (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { walk(u, depth: depth - 1) }
                }
            }
            dirs.forEach { walk($0, depth: 1) }
            return out
        }
        let before = snapshot()
        let (svc, _, clock, _) = make()
        _ = await svc.setMode(.fused)
        let pb = try Self.pixelBuffer()
        svc.noteAudioEvent(.started(device: nil))
        for _ in 0..<50 { clock.t += 0.04; svc.handleFrame(pb, time: clock.t) }
        svc.noteAudioEvent(.stopped(totalSamples: 0))
        _ = await svc.setMode(.off)
        #expect(snapshot().subtracting(before).isEmpty)
        #expect(svc.mouthCrops.count == 0, "turning the camera off drops every crop")
    }
}
