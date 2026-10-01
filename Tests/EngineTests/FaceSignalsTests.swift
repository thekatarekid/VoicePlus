import CoreGraphics
import Foundation
import Testing
@testable import Engine

/// V5 LR1 — camera signals without a lip model, on synthetic sequences (no camera, no Vision).
@Suite struct FaceSignalsTests {
    /// Speech envelope: talk for 1 s (4 Hz syllables), pause 0.7 s, repeated. Returns 0…1.
    static func envelope(_ t: Double) -> Double {
        let cycle = t.truncatingRemainder(dividingBy: 1.7)
        guard cycle < 1.0 else { return 0 }
        return 0.5 + 0.5 * sin(2 * .pi * 4 * t)
    }

    /// 16 kHz audio whose RMS follows `envelope` (+ a small noise floor), in 50 ms blocks.
    static func feedAudio(_ s: inout FaceSignals, seconds: Double, envelope: (Double) -> Double) {
        let block = 800
        var pos = 0.0
        var seed: UInt64 = 7
        while pos < seconds {
            var samples = [Float](repeating: 0, count: block)
            for i in 0..<block {
                let t = pos + Double(i) / 16_000
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let noise = Float(Int64(bitPattern: seed >> 11) % 1000) / 1_000_000
                samples[i] = Float(0.2 * envelope(t)) * Float(sin(2 * .pi * 180 * t)) + noise
            }
            s.noteAudio(samples, position: pos)
            pos += Double(block) / 16_000
        }
    }

    static func feedFrames(_ s: inout FaceSignals, seconds: Double, fps: Double = 15,
                           face: Bool = true, yaw: Double = 0, mouth: (Double) -> Double) {
        var t = 0.0
        while t < seconds {
            s.noteFrame(FaceFrame(time: t, facePresent: face, mouthOpen: face ? mouth(t) : 0, yaw: yaw))
            t += 1 / fps
        }
    }

    @Test func mouthMovingWithTheAudioIsTheUser() {
        var s = FaceSignals()
        Self.feedAudio(&s, seconds: 6, envelope: Self.envelope)
        Self.feedFrames(&s, seconds: 6) { 0.05 + 0.5 * Self.envelope($0) }
        let lips = s.lipActivity(from: 0, to: 6)
        #expect(lips.correlation > 0.5, "correlation \(lips.correlation)")
        #expect(lips.verdict == .userSpeaking)
    }

    @Test func stillMouthWhileTheRoomTalksIsNotTheUser() {
        var s = FaceSignals()
        Self.feedAudio(&s, seconds: 6, envelope: Self.envelope)   // the TV
        Self.feedFrames(&s, seconds: 6) { _ in 0.05 }               // user's mouth closed
        #expect(s.lipActivity(from: 0, to: 6).verdict == .notUser)
    }

    @Test func mouthMovingOutOfStepIsNotTheUser() {
        var s = FaceSignals()
        Self.feedAudio(&s, seconds: 6, envelope: Self.envelope)
        // The mouth moves only in the pauses (talking over / chewing between someone else's words).
        Self.feedFrames(&s, seconds: 6) { t in
            t.truncatingRemainder(dividingBy: 1.7) < 1.0 ? 0.05 : 0.05 + 0.5 * (0.5 + 0.5 * sin(2 * .pi * 5 * t))
        }
        let lips = s.lipActivity(from: 0, to: 6)
        #expect(lips.correlation < 0, "correlation \(lips.correlation)")
        #expect(lips.verdict == .notUser)
    }

    @Test func noFaceMeansLipsDoNotVote() {
        var s = FaceSignals()
        Self.feedAudio(&s, seconds: 4, envelope: Self.envelope)
        Self.feedFrames(&s, seconds: 4, face: false) { _ in 0 }
        #expect(s.lipActivity(from: 0, to: 4).verdict == .noFace)
        let snap = s.snapshot(now: 4)
        #expect(!snap.present && !snap.facingScreen)
    }

    @Test func silenceMeansLipsDoNotVote() {
        var s = FaceSignals()
        Self.feedAudio(&s, seconds: 4) { _ in 0 }
        Self.feedFrames(&s, seconds: 4) { 0.05 + 0.5 * Self.envelope($0) }
        #expect(s.lipActivity(from: 0, to: 4).verdict == .unknown)
    }

    @Test func presenceAndFacing() {
        var s = FaceSignals()
        Self.feedFrames(&s, seconds: 3, yaw: 0.1) { _ in 0.05 }
        #expect(s.snapshot(now: 3).present)
        #expect(s.snapshot(now: 3).facingScreen)
        var turned = FaceSignals()
        Self.feedFrames(&turned, seconds: 3, yaw: 0.9) { _ in 0.05 }
        #expect(turned.snapshot(now: 3).present)
        #expect(!turned.snapshot(now: 3).facingScreen, "head turned ~50° away is not addressing the screen")
    }

    @Test func historyIsBoundedToScalars() {
        var s = FaceSignals()
        Self.feedAudio(&s, seconds: 30, envelope: Self.envelope)
        Self.feedFrames(&s, seconds: 30) { _ in 0.1 }
        #expect(s.frames.first!.time >= 30 - s.config.historySeconds - 0.1)
        #expect(s.frames.count <= Int(s.config.historySeconds * 15) + 2)
    }

    @Test func pearsonBasics() {
        #expect(abs(FaceSignals.pearson([1, 2, 3], [2, 4, 6]) - 1) < 1e-9)
        #expect(abs(FaceSignals.pearson([1, 2, 3], [3, 2, 1]) + 1) < 1e-9)
        #expect(FaceSignals.pearson([1, 1, 1], [1, 2, 3]) == 0)
    }

    @Test func mouthGeometry() {
        let open = [CGPoint(x: 0.4, y: 0.2), CGPoint(x: 0.6, y: 0.2), CGPoint(x: 0.5, y: 0.3), CGPoint(x: 0.5, y: 0.1)]
        #expect(abs(MouthGeometry.openness(innerLips: open) - 1.0) < 1e-6)
        #expect(MouthGeometry.openness(innerLips: []) == 0)
        let r = MouthGeometry.imageRect(points: open, faceBox: CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5))!
        #expect(abs(r.minX - 0.4) < 1e-6 && abs(r.width - 0.1) < 1e-6)
    }

    // MARK: Rule 3 second vote

    @Test func userVoiceVoteTable() {
        let user = LipActivity(correlation: 0.8, mouthMotion: 0.01, faceCoverage: 1, verdict: .userSpeaking)
        let notUser = LipActivity(correlation: 0, mouthMotion: 0, faceCoverage: 1, verdict: .notUser)
        let noFace = LipActivity(correlation: 0, mouthMotion: 0, faceCoverage: 0, verdict: .noFace)
        #expect(UserVoiceVote.combine(audio: .user, lips: nil).vote == .user, "camera off: audio stands")
        #expect(UserVoiceVote.combine(audio: .other, lips: noFace).vote == .other)
        #expect(UserVoiceVote.combine(audio: .user, lips: user).vote == .user)
        #expect(UserVoiceVote.combine(audio: .user, lips: notUser).vote == .other, "lips veto a matched voice")
        #expect(UserVoiceVote.combine(audio: .unknown, lips: user).vote == .user, "lips rescue an unmeasured voice")
        #expect(UserVoiceVote.combine(audio: .other, lips: user).vote == .unknown)
        #expect(UserVoiceVote.combine(audio: .unknown, lips: notUser).vote == .other)
        #expect(UserVoiceVote.audioVote(.user(similarity: 0.9)) == .user)
        #expect(user.decisionScore! >= 0.5 && notUser.decisionScore! < 0.5 && noFace.decisionScore == nil)
        let state = DecisionState(utterance: "send it", lipActivity: user.decisionScore)
        #expect(DecisionStateRenderer().render(state).contains("lips moving: yes"), "feeds O5 context")
    }

    // MARK: Modes

    @Test func lipModes() {
        #expect(!LipMode.off.needsCamera)
        #expect(LipMode.signals.frameRate == 15 && !LipMode.signals.collectsMouthCrops)
        #expect(LipMode.fused.collectsMouthCrops && LipMode.fused.capturesMicrophone)
        #expect(!LipMode.lipsOnly.capturesMicrophone && LipMode.lipsOnly.frameRate == 25)
    }

    // MARK: LR5 audit

    @Test func cameraPathNeverPersistsOrSendsFrames() throws {
        let root = try #require(CameraPrivacyAudit.packageRoot(), "needs the checkout to audit")
        #expect(CameraPrivacyAudit.auditedFiles(root: root).count >= 4)
        let violations = try #require(CameraPrivacyAudit.audit(root: root))
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test func auditCatchesAStoredFrame() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cam-audit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Engine/Vision"), withIntermediateDirectories: true)
        try "final class Bad { var last: CVPixelBuffer?\n func save() { try? data.write(to: url) } }"
            .write(to: dir.appendingPathComponent("Engine/Vision/Bad.swift"), atomically: true, encoding: .utf8)
        let violations = try #require(CameraPrivacyAudit.audit(root: dir))
        #expect(violations.count == 2)
    }
}
