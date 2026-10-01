import CoreVideo
import Engine
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// V5 LR1 — the camera runs only while a mode is on *and* the permission allows it.
@Suite(.serialized) struct CameraServiceTests {
    final class FakeAuth: CameraAuthorizing, @unchecked Sendable {
        var current: PermissionStatus
        var answer: Bool
        var requests = 0
        init(_ s: PermissionStatus, answer: Bool = false) { current = s; self.answer = answer }
        func status() -> PermissionStatus { current }
        func request() async -> Bool {
            requests += 1
            current = answer ? .granted : .denied
            return answer
        }
    }

    final class FakeCapture: CameraCapturing {
        var isRunning = false
        var starts: [Int] = []
        var stops = 0
        func start(frameRate: Int, onFrame: @escaping (CVPixelBuffer, TimeInterval) -> Void) throws {
            starts.append(frameRate); isRunning = true
        }
        func stop() { if isRunning { stops += 1 }; isRunning = false }
    }

    struct NoLandmarks: FaceLandmarking {
        func analyze(_ pixelBuffer: CVPixelBuffer, time: TimeInterval) -> FaceAnalysis { FaceAnalysis(frame: .noFace(at: time)) }
    }

    func make(_ status: PermissionStatus, answer: Bool = false, store: SettingsStore? = InMemorySettingsStore())
        -> (CameraService, FakeAuth, FakeCapture) {
        let auth = FakeAuth(status, answer: answer), cap = FakeCapture()
        return (CameraService(settings: store, authorization: auth, capture: cap, landmarker: NoLandmarks(), now: { 100 }), auth, cap)
    }

    @Test func permissionDeniedNeverCaptures() async {
        let (svc, auth, cap) = make(.denied)
        var notices: [String] = []
        svc.onNotice = { notices.append($0) }
        for mode in LipMode.allCases { _ = await svc.setMode(mode) }
        #expect(cap.starts.isEmpty, "no capture without the permission")
        #expect(auth.requests == 0, "a denied promptable permission is not re-asked")
        #expect(svc.mode == .off && !svc.isCameraOn && !svc.indicator.visible)
        #expect(svc.faceSignals(now: 100) == nil && svc.lipActivity(from: 0, to: 100) == nil)
        #expect(notices.first == CameraModeGate.deniedNotice)
    }

    @Test func modeOffNeverCapturesEvenWhenGranted() async {
        let (svc, _, cap) = make(.granted)
        _ = await svc.setMode(.off)
        #expect(cap.starts.isEmpty && !svc.isCameraOn)
    }

    @Test func undeterminedAsksOnceThenStarts() async {
        let (svc, auth, cap) = make(.notDetermined, answer: true)
        #expect(await svc.setMode(.signals) == .signals)
        #expect(auth.requests == 1 && cap.starts == [15])
        #expect(svc.indicator == .on(.signals) && svc.indicator.visible)
        #expect(CameraService.isOwnCaptureActive)
        _ = await svc.setMode(.off)
        #expect(!cap.isRunning && cap.stops == 1 && svc.indicator == .hidden)
        #expect(!CameraService.isOwnCaptureActive)
    }

    @Test func undeterminedRefusedStaysOff() async {
        let (svc, auth, cap) = make(.notDetermined, answer: false)
        #expect(await svc.setMode(.fused) == .off)
        #expect(auth.requests == 1 && cap.starts.isEmpty)
    }

    @Test func lipReadingModesRunAt25fps() async {
        let (svc, _, cap) = make(.granted)
        svc.bindLipsOnly(engine: SwappableEngine(UnavailableEngine())) { svc.lipsOnlyEngine(model: StubModel()) }
        _ = await svc.setMode(.signals)
        _ = await svc.setMode(.lipsOnly)
        #expect(cap.starts == [15, 25])
        #expect(svc.indicator.label.contains("mic muted"))
    }

    @Test func indicatorCallbackFiresOnChange() async {
        let (svc, _, _) = make(.granted)
        var seen: [Bool] = []
        svc.onIndicatorChange = { seen.append($0.visible) }
        _ = await svc.setMode(.signals)
        _ = await svc.setMode(.signals)
        _ = await svc.setMode(.off)
        #expect(seen == [true, false])
    }

    @Test func restoreNeverPrompts() async {
        let store = InMemorySettingsStore()
        store.set(LipMode.fused.rawValue, for: CameraService.modeKey)
        let (svc, auth, cap) = make(.notDetermined, store: store)
        #expect(svc.restore() == .off)
        #expect(auth.requests == 0 && cap.starts.isEmpty)
        #expect(svc.persistedMode == .fused, "restore without a grant does not forget the user's choice")
        let (granted, _, cap2) = make(.granted, store: store)
        #expect(granted.restore() == .fused && cap2.starts == [25])
    }

    @Test func framesWhileOffAreDropped() async {
        let (svc, _, _) = make(.granted)
        svc.ingest(FaceAnalysis(frame: FaceFrame(time: 99.5, facePresent: true, mouthOpen: 0.2, yaw: 0)))
        _ = await svc.setMode(.signals)
        #expect(svc.faceSignals(now: 100)?.present == false, "a frame that arrived while off was not kept")
        for i in 0..<15 { svc.ingest(FaceAnalysis(frame: FaceFrame(time: 99 + Double(i) / 15, facePresent: true, mouthOpen: 0.1, yaw: 0))) }
        #expect(svc.faceSignals(now: 100)?.present == true)
    }

    @Test func cameraRowIsOptionalAndPromptable() {
        let row = OptionalPermission.camera
        #expect(row.title == "Camera (optional)")
        #expect(row.isPromptable && !OptionalPermission.screenRecording.isPromptable)
        #expect(row.settingsAnchor == "Privacy_Camera")
        #expect(!Permission.allCases.map(\.rawValue).contains(row.rawValue), "never part of the required walk")
        #expect(row.rationale.contains("never saved"))
    }

    // MARK: LR3

    final class StubModel: AVSRModelRunning, @unchecked Sendable {
        let vocabulary = AVSRVocabulary(tokens: ["<blank>", "\u{2581}HI"])
        var installed = true
        func isAvailable(_ v: AVSRVariant) -> Bool { installed }
        func run(_ input: AVSRInput, variant: AVSRVariant) async throws -> CTCOutput {
            CTCOutput(logProbs: [[Float(log(0.1)), Float(log(0.9))]], frameDuration: 0.04)
        }
    }

    @Test func lipsOnlySwapsTheEngineAndMutesTheMic() async {
        let (svc, _, _) = make(.granted)
        let voice = UnavailableEngine(reason: "voice stand-in")
        let slot = SwappableEngine(voice)
        let model = StubModel()
        var muted: [Bool] = []
        svc.onMicrophoneMuted = { muted.append($0) }
        svc.bindLipsOnly(engine: slot) { svc.lipsOnlyEngine(model: model) }
        _ = await svc.setMode(.lipsOnly)
        #expect(slot.current is LipsOnlyEngine && svc.lipsOnlyActive)
        _ = await svc.setMode(.fused)
        #expect(slot.current === voice && !svc.lipsOnlyActive)
        #expect(muted == [true, false])
    }

    @Test func lipsOnlyWithoutTheModelFallsBackToFused() async {
        let (svc, _, _) = make(.granted)
        let slot = SwappableEngine(UnavailableEngine())
        var notices: [String] = []
        svc.onNotice = { notices.append($0) }
        svc.bindLipsOnly(engine: slot) { nil }
        #expect(await svc.setMode(.lipsOnly) == .fused)
        #expect(!(slot.current is LipsOnlyEngine))
        #expect(notices == [LipsOnlyEngine.notInstalledMessage])
    }

    @Test func relaunchNeverRestoresAMutedMic() {
        let store = InMemorySettingsStore()
        store.set(LipMode.lipsOnly.rawValue, for: CameraService.modeKey)
        let (svc, _, _) = make(.granted, store: store)
        #expect(svc.restore() == .fused)
    }
}
