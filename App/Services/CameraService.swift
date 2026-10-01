import AVFoundation
import CoreMedia
import CoreVideo
import Engine
import Foundation
import Shared

// MARK: - V5 LR1 · CameraService
//
// The only owner of the camera. Front camera, 15 fps (25 fps while a lip-reading mode needs mouth
// crops), opened only while a `LipMode` other than `.off` is on and the Camera permission is
// granted. Each frame is reduced to scalars (`FaceFrame`) — and, for LR2/LR3, a small grayscale
// mouth crop — inside the capture callback, and the pixel buffer is released when the callback
// returns. Nothing is written to disk, nothing leaves the Mac (LR5; audited by `CameraPrivacyAudit`).

/// Camera TCC status, injected so tests never touch AVFoundation.
public protocol CameraAuthorizing: Sendable {
    func status() -> PermissionStatus
    /// Shows the system dialog when undetermined; returns whether access is granted.
    func request() async -> Bool
}

public struct SystemCameraAuthorization: CameraAuthorizing {
    public init() {}
    public func status() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }
    public func request() async -> Bool { await AVCaptureDevice.requestAccess(for: .video) }
}

/// A frame source. `onFrame` gets a pixel buffer that is valid **only for the duration of the call**.
public protocol CameraCapturing: AnyObject {
    var isRunning: Bool { get }
    func start(frameRate: Int, onFrame: @escaping (CVPixelBuffer, TimeInterval) -> Void) throws
    func stop()
}

public enum CameraCaptureError: Error, Equatable { case noCamera, cannotAddInput, cannotAddOutput }

/// AVFoundation capture: front (or only) camera, BGRA, late frames discarded, no recording output.
public final class AVCameraCapture: NSObject, CameraCapturing, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "voiceplus.camera.frames", qos: .userInitiated)
    private var onFrame: ((CVPixelBuffer, TimeInterval) -> Void)?
    public private(set) var isRunning = false

    public override init() { super.init() }

    public func start(frameRate: Int, onFrame: @escaping (CVPixelBuffer, TimeInterval) -> Void) throws {
        guard !isRunning else { return }
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external],
                                                         mediaType: .video, position: .unspecified)
        guard let device = discovery.devices.first(where: { $0.position == .front })
                ?? discovery.devices.first ?? AVCaptureDevice.default(for: .video) else { throw CameraCaptureError.noCamera }
        session.beginConfiguration()
        session.sessionPreset = .vga640x480
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            session.commitConfiguration(); throw CameraCaptureError.cannotAddInput
        }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { session.commitConfiguration(); throw CameraCaptureError.cannotAddOutput }
        session.addOutput(output)
        if (try? device.lockForConfiguration()) != nil {
            let duration = CMTime(value: 1, timescale: CMTimeScale(max(1, frameRate)))
            let supported = device.activeFormat.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= Double(frameRate) && Double(frameRate) <= $0.maxFrameRate
            }
            if supported { device.activeVideoMinFrameDuration = duration; device.activeVideoMaxFrameDuration = duration }
            device.unlockForConfiguration()
        }
        session.commitConfiguration()
        self.onFrame = onFrame
        session.startRunning()
        isRunning = true
    }

    public func stop() {
        guard isRunning else { return }
        session.stopRunning()
        onFrame = nil
        isRunning = false
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Presentation time is on the host clock — the same clock as `systemUptime`.
        let t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        onFrame?(buffer, t.isFinite ? t : ProcessInfo.processInfo.systemUptime)
    }
}

/// Pure decision: may the camera run for `mode` given the Camera permission?
public enum CameraModeGate {
    public enum Decision: Equatable, Sendable {
        case off
        case start
        /// Undetermined: ask the system (promptable), then start if granted.
        case request
        /// Denied: stay off and say so — the mode switch reverts to off.
        case denied(notice: String)
    }

    public static let deniedNotice = "Camera access is off for VoicePlus — turn it on in System Settings › Privacy & Security › Camera."

    public static func decide(mode: LipMode, status: PermissionStatus) -> Decision {
        guard mode.needsCamera else { return .off }
        switch status {
        case .granted: return .start
        case .notDetermined: return .request
        case .denied, .awaitingUserAction: return .denied(notice: deniedNotice)
        }
    }
}

/// What the notch shows while the camera is on (LR1/LR5 visible indicator).
public struct CameraIndicator: Equatable, Sendable {
    public var visible: Bool
    public var symbol: String
    public var label: String

    public static let hidden = CameraIndicator(visible: false, symbol: "camera.fill", label: "")
    public static func on(_ mode: LipMode) -> CameraIndicator {
        CameraIndicator(visible: true, symbol: mode == .lipsOnly ? "mouth.fill" : "camera.fill",
                        label: mode == .lipsOnly ? "Lips only — mic muted" : "Camera on")
    }
}

public final class CameraService: FaceSignalsProviding, @unchecked Sendable {
    public static let modeKey = "camera.lipMode"

    /// True while VoicePlus itself holds the camera. `CameraInUseMonitor` (meeting detection) sees
    /// every app's camera use including ours; the meeting lane should ignore camera-on while this
    /// is set, or our own lip mode would look like a call starting.
    public static var isOwnCaptureActive: Bool { ownCapture.withLock { $0 } }
    private static let ownCapture = CameraFlagBox(false)

    public private(set) var mode: LipMode = .off
    public private(set) var indicator: CameraIndicator = .hidden
    /// Called on every indicator change (notch wiring).
    public var onIndicatorChange: ((CameraIndicator) -> Void)?
    /// Called with a user-facing line when a mode could not be turned on.
    public var onNotice: ((String) -> Void)?

    private let settings: SettingsStore?
    private let authorization: CameraAuthorizing
    private let capture: CameraCapturing
    private let landmarker: FaceLandmarking
    private let now: @Sendable () -> TimeInterval
    private let lock = NSLock()
    private var signals = FaceSignals()
    private var audioTask: Task<Void, Never>?
    /// LR2/LR3 — mouth crops for the current utterance (crops only, never frames). The recognisers
    /// read it through `VisualClipProviding`.
    public let mouthCrops: VisualFrameBuffer

    public var isCameraOn: Bool { capture.isRunning }

    public init(settings: SettingsStore? = nil,
                authorization: CameraAuthorizing = SystemCameraAuthorization(),
                capture: CameraCapturing = AVCameraCapture(),
                landmarker: FaceLandmarking = VisionFaceLandmarker(),
                now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.settings = settings
        self.authorization = authorization
        self.capture = capture
        self.landmarker = landmarker
        self.now = now
        self.mouthCrops = VisualFrameBuffer(now: now)
    }

    deinit { audioTask?.cancel(); capture.stop() }

    /// The persisted mode (default off).
    public var persistedMode: LipMode {
        settings?.string(Self.modeKey).flatMap(LipMode.init(rawValue:)) ?? .off
    }

    /// At launch: re-apply the persisted mode **without** prompting — the camera starts only if the
    /// permission is already granted.
    @discardableResult
    public func restore() -> LipMode {
        let wanted = persistedMode
        if case .start = CameraModeGate.decide(mode: wanted, status: authorization.status()) {
            apply(wanted)
        } else {
            apply(.off, persist: false)
        }
        return mode
    }

    /// The mode switch (settings / notch / menu). Returns the mode actually in force.
    @discardableResult
    public func setMode(_ wanted: LipMode) async -> LipMode {
        switch CameraModeGate.decide(mode: wanted, status: authorization.status()) {
        case .off:
            apply(.off)
        case .start:
            apply(wanted)
        case .request:
            if await authorization.request() { apply(wanted) } else {
                apply(.off); onNotice?(CameraModeGate.deniedNotice)
            }
        case .denied(let notice):
            apply(.off); onNotice?(notice)
        }
        return mode
    }

    private func apply(_ next: LipMode, persist: Bool = true) {
        if persist { settings?.set(next.rawValue, for: Self.modeKey) }
        let rateChanged = next.frameRate != mode.frameRate
        mode = next
        if !next.collectsMouthCrops { mouthCrops.clear() }
        if !next.needsCamera {
            stopCamera()
        } else if !capture.isRunning || rateChanged {
            capture.stop()
            do {
                try capture.start(frameRate: next.frameRate) { [weak self] buffer, time in
                    self?.handleFrame(buffer, time: time)
                }
            } catch {
                Log.engine.warning("camera: start failed: \(error)")
                mode = .off
                onNotice?("The camera couldn't be started.")
            }
        }
        Self.ownCapture.withLock { $0 = capture.isRunning }
        let nextIndicator: CameraIndicator = capture.isRunning ? .on(mode) : .hidden
        if nextIndicator != indicator {
            indicator = nextIndicator
            onIndicatorChange?(nextIndicator)
        }
    }

    private func stopCamera() {
        capture.stop()
        lock.withLock { signals.reset() }
        mouthCrops.clear()
    }

    // MARK: Frames

    /// Runs on the capture queue. The buffer is not retained past this call.
    func handleFrame(_ buffer: CVPixelBuffer, time: TimeInterval) {
        let analysis = landmarker.analyze(buffer, time: time)
        ingest(analysis)
        guard mode.collectsMouthCrops else { return }
        let crop = analysis.mouthRect.flatMap { MouthCropper.crop(buffer, mouthRect: $0) }
        mouthCrops.append(MouthCropFrame(time: time, pixels: crop))
    }

    /// Scalars only; exposed for tests (and for a frame source that already ran Vision).
    public func ingest(_ analysis: FaceAnalysis) {
        guard capture.isRunning else { return }
        lock.withLock { signals.noteFrame(analysis.frame) }
    }

    // MARK: Audio (for the lips-vs-audio correlation)

    /// One microphone block, stamped on the host clock at arrival.
    public func noteAudio(_ samples: [Float], sampleRate: Double = 16_000) {
        guard capture.isRunning, !samples.isEmpty else { return }
        let start = now() - Double(samples.count) / sampleRate
        lock.withLock { signals.noteAudio(samples, position: start, sampleRate: sampleRate) }
    }

    /// Subscribe to the one capture graph (§10 — never open a mic of our own).
    public func attach(to broadcaster: AudioPipeline.Broadcaster) {
        audioTask?.cancel()
        let stream = broadcaster.subscribe()
        audioTask = Task { [weak self] in
            for await event in stream {
                if case .audio(let samples, _) = event { self?.noteAudio(samples) }
            }
        }
    }

    // MARK: FaceSignalsProviding

    public func faceSignals(now t: TimeInterval) -> FaceSignalsSnapshot? {
        guard capture.isRunning else { return nil }
        return lock.withLock { signals.snapshot(now: t) }
    }

    public func lipActivity(from: TimeInterval, to: TimeInterval) -> LipActivity? {
        guard capture.isRunning else { return nil }
        return lock.withLock { signals.lipActivity(from: from, to: to) }
    }

    /// Convenience: the current snapshot on the service's clock.
    public func currentFaceSignals() -> FaceSignalsSnapshot? { faceSignals(now: now()) }
}

/// Tiny lock box for the process-wide own-capture flag.
final class CameraFlagBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<R>(_ body: (inout Value) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(&value) }
}
