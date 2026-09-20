import AppKit
import Foundation
import SwiftUI
import Testing
@testable import VoicePlusApp

/// S1 — the parts of the Spool port the golden frames do not cover: the reel-angle integrator (S1.4),
/// the frame loop (S1.5), the real-product rules the prototype only simulates (S1.6), the maths the
/// parity depends on, and the renderer's geometry (viewport, path data, anchors).
@Suite("Spool motion, real-audio rules and rendering (S1)")
struct SpoolMotionTests {

    // MARK: - S1.4 reel angle

    /// Frames at 60 fps through listening 2 s → finishing 0.7 s → preview 0.5 s → inserting 1.3 s →
    /// inserted 0.5 s. The first frame of each state advances nothing (dt = 0).
    @Test func reelIntegratorReproducesTheScriptedSequence() {
        var reel = SpoolReelIntegrator()
        var checkpoints: [SpoolStateKey: Double] = [:]
        let script: [(SpoolStateKey, Int)] = [(.listening, 120), (.finishing, 42), (.preview, 30), (.inserting, 78), (.inserted, 30)]
        for (key, frames) in script {
            for k in 0...frames {
                reel.advance(key, t: Double(k) / 60, dt: k == 0 ? 0 : 1.0 / 60)
            }
            checkpoints[key] = reel.angle
        }
        // listening: 120 frames × 150°/s × 1/60 s, counterclockwise.
        #expect(abs(checkpoints[.listening]! - -300) < 1e-9)
        // finishing: Σ_{k=1}^{32} 150·(1 − (k/60)/0.55)/60 = 40 (t = 33/60 is no longer < 0.55).
        #expect(abs(checkpoints[.finishing]! - -340) < 1e-9)
        // preview holds the angle; nothing snaps back.
        #expect(checkpoints[.preview]! == checkpoints[.finishing]!)
        // Insertion ramps over 120 ms, then turns at 390°/s until 1.2 s.
        let rampDegrees = 390.0 * 28.0 / (3600.0 * 0.12)
        let insertedAngle = -340 + 64 * 390.0 / 60 + rampDegrees
        #expect(abs(checkpoints[.inserting]! - insertedAngle) < 1e-9)
        #expect(checkpoints[.inserted]! == checkpoints[.inserting]!)
    }

    @Test func reelIntegratorClampsDtAndHonoursReduceMotion() {
        var reel = SpoolReelIntegrator(angle: 10)
        reel.advance(.listening, t: 3, dt: 0.4)
        #expect(reel.angle == 10 - 150 * 0.05)
        reel.advance(.latched, t: 3, dt: -1)
        #expect(reel.angle == 10 - 150 * 0.05)
        var reduced = SpoolReelIntegrator(angle: 10)
        for state in [SpoolStateKey.listening, .finishing, .inserting] {
            reduced.advance(state, t: 0.1, dt: 0.02, reduceMotion: true)
        }
        #expect(reduced.angle == 10)
        // Every non-moving state holds.
        for key in SpoolStateKey.allCases where !SpoolPoseTable.isLive(key) && key != .finishing && key != .inserting {
            var still = SpoolReelIntegrator(angle: -42)
            still.advance(key, t: 0.1, dt: 0.02)
            #expect(still.angle == -42, "\(key) must not turn the reels")
        }
    }

    // MARK: - S1.5 frame loop

    @Test func frameLoopRunsOnlyWhereTheDesignSays() {
        for key in SpoolPoseTable.liveStates { #expect(SpoolPoseTable.animates(key, t: 60)) }
        #expect(SpoolPoseTable.animates(.editing, t: 60))
        #expect(SpoolPoseTable.animates(.notes, t: 60))
        #expect(SpoolPoseTable.animates(.inserting, t: 1.09))
        #expect(!SpoolPoseTable.animates(.inserting, t: 1.3))
        #expect(SpoolPoseTable.animates(.preview, t: 1.09))
        #expect(!SpoolPoseTable.animates(.preview, t: 1.1))
        #expect(!SpoolPoseTable.animates(.idle, t: 5))
        #expect(!SpoolPoseTable.animates(.listening, t: 0.1, hidden: true))
        #expect(!SpoolPoseTable.animates(.listening, t: 0.1, reduceMotion: true))

        let start = Date(timeIntervalSinceReferenceDate: 1000)
        #expect(SpoolPoseTable.loopEnd(.listening, start: start) == .distantFuture)
        #expect(SpoolPoseTable.loopEnd(.preview, start: start) == start.addingTimeInterval(1.1))
        #expect(SpoolPoseTable.loopEnd(.inserting, start: start) == start.addingTimeInterval(1.3))
        #expect(SpoolPoseTable.loopEnd(.listening, start: start, reduceMotion: true) == nil)
        #expect(SpoolPoseTable.loopEnd(.listening, start: start, hidden: true) == nil)
    }

    @Test func frameScheduleStopsAtTheLoopEnd() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        let still = Array(SpoolFrameSchedule(end: nil).entries(from: start, mode: .normal))
        #expect(still == [start])
        let settling = Array(SpoolFrameSchedule(end: start.addingTimeInterval(0.8)).entries(from: start, mode: .normal))
        #expect(settling.first == start && settling.last == start.addingTimeInterval(0.8))
        #expect(settling.count == 50)   // 0, 1/60 … 48/60, then 0.8
        #expect(zip(settling, settling.dropFirst()).allSatisfy { $0 < $1 })
        let past = Array(SpoolFrameSchedule(end: start).entries(from: start.addingTimeInterval(3), mode: .normal))
        #expect(past.count == 1)
        var live = SpoolFrameSchedule(end: .distantFuture).entries(from: start, mode: .normal).makeIterator()
        var count = 0
        while count < 10_000, live.next() != nil { count += 1 }
        #expect(count == 10_000)
        let lowFrequency = Array(SpoolFrameSchedule(end: .distantFuture).entries(from: start, mode: .lowFrequency))
        #expect(lowFrequency == [start])
    }

    // MARK: - S1.6 real-product rules

    /// Rule 1: silence flattens the tape. With no audio the lane is the eased rest line and the ribbon
    /// never shows its reverse; the simulation waves at the same instant.
    @Test func silenceGivesZeroTapeAmplitude() {
        for key in SpoolPoseTable.liveStates {
            let silent = SpoolScene.frame(key, t: 1.4, drive: .capture(level: 0))
            #expect(silent.activity == 0)
            let end = silent.inlet
            for (i, point) in silent.lane.enumerated() {
                let u = Double(i) / 96
                #expect(point.y == SpoolMath.mix(98, end.y, SpoolMath.pow(u, 9)), "\(key) sample \(i) is not flat")
            }
            #expect(!SpoolSVG.string(silent.drawing).contains(SpoolPalette.tapeBack), "\(key): a flat tape shows no twist")
            let simulated = SpoolScene.frame(key, t: 1.4, drive: .simulation)
            #expect(simulated.lane != silent.lane)
        }
    }

    @Test func tapeAmplitudeScalesWithTheCaptureLevel() {
        let full = SpoolScene.frame(.listening, t: 0.8, drive: .capture(level: 1))
        let simulated = SpoolScene.frame(.listening, t: 0.8, drive: .simulation)
        #expect(full.drawing == simulated.drawing, "full level draws exactly the prototype's live tape")
        let half = SpoolScene.frame(.listening, t: 0.8, drive: .capture(level: 0.5))
        let flat = SpoolScene.frame(.listening, t: 0.8, drive: .capture(level: 0))
        #expect(half.activity == 0.5)
        for i in [10, 30, 48, 70, 90] {
            let fullWave = full.lane[i].y - flat.lane[i].y, halfWave = half.lane[i].y - flat.lane[i].y
            #expect(abs(halfWave - fullWave / 2) < 1e-9)
        }
        // Out-of-range levels are clamped; finishing damps whatever the level leaves.
        #expect(SpoolScene.activity(.listening, t: 1, still: false, drive: .capture(level: 3)) == 1)
        #expect(SpoolScene.activity(.listening, t: 1, still: false, drive: .capture(level: .nan)) == 0)
        #expect(SpoolScene.activity(.finishing, t: 0.55, still: false, drive: .capture(level: 1)) == 0)
        #expect(SpoolScene.activity(.quiet, t: 1, still: false, drive: .capture(level: 1)) == 0)
        #expect(SpoolScene.activity(.listening, t: 1, still: true, drive: .capture(level: 1)) == 0)
    }

    /// The product path (`SpoolAnimator`, what `SpoolView` draws) never loops a canned ribbon: with no
    /// audio arriving, a whole second of listening frames has a flat tape.
    @Test func productFramesStayFlatWithoutAudio() {
        let animator = SpoolAnimator()
        let start = Date(timeIntervalSinceReferenceDate: 500)
        for k in 0...60 {
            let frame = animator.frame(.listening, stateStartedAt: start, level: 0, at: start.addingTimeInterval(Double(k) / 60),
                                       reduceMotion: false, width: 560)
            #expect(frame.activity == 0)
        }
        // Speech arrives: the tape rises within the 40 ms attack.
        let speaking = animator.frame(.listening, stateStartedAt: start, level: 1, at: start.addingTimeInterval(1 + 0.05),
                                      reduceMotion: false, width: 560)
        #expect(speaking.activity > 0.7)
    }

    @Test func levelSmootherHasA40msAttackAnd250msRelease() {
        var rising = SpoolLevelSmoother()
        rising.advance(toward: 1, dt: 0.040)
        #expect(abs(rising.value - (1 - Foundation.exp(-1))) < 1e-12)
        rising.advance(toward: 1, dt: 0.160)
        #expect(rising.value > 0.99)
        var falling = SpoolLevelSmoother(value: 1)
        falling.advance(toward: 0, dt: 0.250)
        #expect(abs(falling.value - Foundation.exp(-1)) < 1e-12)
        falling.advance(toward: 0, dt: 1)
        #expect(falling.value < 0.02)
        var clamped = SpoolLevelSmoother()
        clamped.advance(toward: 7, dt: 10)
        #expect(clamped.value <= 1)
        let unchanged = clamped.value
        let returned = clamped.advance(toward: 0, dt: 0)
        #expect(returned == unchanged && clamped.value == unchanged)
    }

    /// Rule 2: silence parks the reels — listening shows as quiet after 1.5 s of VAD silence, quiet
    /// accumulates no angle, and speech resumes listening from the same angle.
    @Test func silenceParksTheReelsAndSpeechResumesFromTheSameAngle() {
        var tracker = SpoolSilenceTracker()
        var reel = SpoolReelIntegrator()
        var time = 0.0
        func frame(_ speech: Bool) {
            tracker.note(speech: speech, at: time)
            let key = tracker.displayedKey(.listening, at: time)
            reel.advance(key, t: time, dt: 1.0 / 60, level: speech ? 1 : 0)
            time += 1.0 / 60
        }
        for _ in 0..<60 { frame(true) }
        let afterSpeech = reel.angle
        #expect(afterSpeech < 0)
        for _ in 0..<89 { frame(false) }
        #expect(tracker.displayedKey(.listening, at: time - 1.0 / 60) == .listening)
        let beforeQuiet = reel.angle
        #expect(beforeQuiet == afterSpeech, "no speech energy parks reels immediately")
        for _ in 0..<180 { frame(false) }
        #expect(tracker.displayedKey(.listening, at: time) == .quiet)
        let parked = reel.angle
        for _ in 0..<120 { frame(false) }
        #expect(reel.angle == parked, "quiet must not accumulate")
        frame(true)
        #expect(tracker.displayedKey(.listening, at: time) == .listening)
        #expect(reel.angle < parked && reel.angle > parked - 3, "speech resumes from the parked angle")
        #expect(SpoolSilenceTracker.displayedKey(.latched, silence: 10) == .latched)
        #expect(SpoolSilenceTracker.displayedKey(.listening, silence: 1.49) == .listening)
        #expect(SpoolSilenceTracker.displayedKey(.listening, silence: 1.5) == .quiet)
    }

    /// Listening transport follows real capture energy, including zero speed during silence.
    @Test func listeningSpeedIsModulatedBySpeechActivity() {
        #expect(SpoolReelIntegrator.liveSpeed(level: nil) == 150)
        #expect(abs(SpoolReelIntegrator.liveSpeed(level: 0) - 0) < 1e-12)
        #expect(abs(SpoolReelIntegrator.liveSpeed(level: 0.5) - 75) < 1e-12)
        #expect(abs(SpoolReelIntegrator.liveSpeed(level: 1) - 150) < 1e-12)
        #expect(abs(SpoolReelIntegrator.liveSpeed(level: 4) - 150) < 1e-12)
        var reel = SpoolReelIntegrator()
        reel.advance(.meeting, t: 1, dt: 0.05, level: 0.5)
        #expect(abs(reel.angle - -3.75) < 1e-12)
    }

    /// Rule 4: copy shown with Spool names the configured key, never the prototype's "Right Control".
    @Test func hintCopyUsesTheConfiguredKeyLabel() throws {
        let data = try SpoolParityTests.data("Fixtures/design/design_copy.json")
        let copy = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let pill = try #require(copy["pill"] as? [String: [String: Any]])
        var checked = 0
        for (key, entry) in pill {
            let strings = ((entry["strings"] as? [String]) ?? []) + [(entry["text"] as? String) ?? ""]
            for line in strings where line.contains(PillCopy.prototypeHotkey) {
                let rendered = PillState.withHotkey(line, key: "fn / 🌐")
                #expect(!rendered.contains("Right Control"), "\(key): \(rendered)")
                #expect(rendered.contains("fn / 🌐"))
                checked += 1
            }
        }
        #expect(checked > 0)
    }

    // MARK: - Maths the parity depends on (values from node 26)

    @Test func fixedTwoMatchesJavaScript() {
        let cases: [(Double, Double)] = [
            (0.125, 0.13), (-0.125, -0.13), (0.375, 0.38), (1.005, 1), (8.345, 8.35), (2.675, 2.67), (-0.004, 0),
            (-0.005, -0.01), (123.456, 123.46), (-33.99999999999999, -34), (0.1 + 0.2, 0.3), (434.99999999999994, 435),
            (0.285, 0.28), (1.255, 1.25), (14.499999999999998, 14.5), (99.995, 100), (-99.995, -100),
            (0.015, 0.01), (0.025, 0.03), (0.035, 0.04), (0.045, 0.04),
        ]
        for (x, expected) in cases { #expect(SpoolMath.fixed2(x) == expected, "f(\(x))") }
        #expect(SpoolMath.fixed2(-0.001).sign == .minus, "Number('-0.00') is -0")
    }

    @Test func numberPrintingMatchesJavaScript() {
        let cases: [(Double, String)] = [
            (0, "0"), (-0.0, "0"), (1, "1"), (-1, "-1"), (0.1, "0.1"), (0.125, "0.125"), (1e21, "1e+21"), (1e-7, "1e-7"),
            (1.5e-7, "1.5e-7"), (0.000001, "0.000001"), (0.0000012, "0.0000012"),
            (1.2345678901234568e20, "123456789012345680000"), (1.7976931348623157e308, "1.7976931348623157e+308"),
            (5e-324, "5e-324"), (-33.99999999999999, "-33.99999999999999"), (0.1 + 0.2, "0.30000000000000004"),
            (100, "100"), (1234.5, "1234.5"), (-47.8, "-47.8"), (0.69 * 8, "5.52"), (434.99999999999994, "434.99999999999994"),
        ]
        for (x, expected) in cases { #expect(SpoolSVG.number(x) == expected, "String(\(x))") }
    }

    @Test func transcendentalsMatchV8BitForBit() {
        // (x, sin x, cos x, exp(−|x|/3)) as node computes them; Darwin's libm differs on several.
        let cases: [(UInt64, UInt64, UInt64, UInt64)] = [
            (0xc0307bfff504568d, 0x3fe66c53a6b8e131, 0xbfe6d47161078e46, 0x3f70d3ab38a2c808),
            (0x40030b49fc8ff444, 0x3fe6120e83470b70, 0xbfe72bc168e4fb60, 0x3fdcf1c87e6200c2),
            (0x404c75717976218d, 0x3fd7134125169a13, 0x3fedd901288c0063, 0x3e38bc0bdaa688ec),
            (0x4010cccccccccccd, 0xbfebe3f2dfd012d8, 0xbfdf606eec8ac71d, 0x3fcf907d43b60713),
            (0x3fd3333333333333, 0x3fd2e9cd95baba33, 0x3fee921dd42f09ba, 0x3fecf46d99d52b3b),
            (0x402b000000000000, 0x3fe9b89a1e2258b0, 0x3fe309970f142dfc, 0x3f86c0504695c417),
            (0x401c000000000000, 0x3fe50608c26d0a08, 0x3fe81ff79ed92017, 0x3fb8d327a69b3be5),
            (0x4010cccccccccccc, 0xbfebe3f2dfd012d4, 0xbfdf606eec8ac72b, 0x3fcf907d43b60717),
            (0x4036000000000000, 0xbf8220a29f6eb9f4, 0xbfefffadd8d4acda, 0x3f45690c97ae0cd9),
            (0x402a199999999999, 0x3fddc27bf4beb491, 0x3fec547c28aba9df, 0x3f8a6ee30f6e1afe),
            (0x4006000000000000, 0x3fd86d2239c183fb, 0xbfed93e294faed14, 0x3fd99723012e97f1),
        ]
        for (xBits, sinBits, cosBits, expBits) in cases {
            let x = Double(bitPattern: xBits)
            #expect(SpoolMath.sin(x).bitPattern == sinBits, "sin(\(x))")
            #expect(SpoolMath.cos(x).bitPattern == cosBits, "cos(\(x))")
            #expect(SpoolMath.exp(-abs(x) / 3).bitPattern == expBits, "exp(\(-abs(x) / 3))")
        }
        #expect(SpoolMath.hypot(3, 4) == 5)
        #expect(SpoolMath.hypot(0, 0) == 0)
        #expect(SpoolMath.max(0, -0.0).sign == .plus)
        #expect(SpoolMath.min(0, -0.0).sign == .minus)
        #expect(SpoolMath.round(2.5) == 3 && SpoolMath.round(-2.5) == -2 && SpoolMath.round(0.49999999999999994) == 0)
    }

    // MARK: - Rendering geometry and anchors

    @Test func viewportFitsAndCentresLikeSVG() {
        let pill = SpoolViewport(viewBox: [0, 0, 560, 160], size: CGSize(width: 560, height: 160))
        #expect(pill.scale == 1 && pill.offsetX == 0 && pill.offsetY == 0)
        let cameo = SpoolViewport(viewBox: SpoolScene.cameoViewBox, size: CGSize(width: 76, height: 132))
        #expect(cameo.scale == 0.5)
        #expect(cameo.map(SpoolPoint(0, 0)) == CGPoint(x: 38, y: 69))
        let empty = SpoolViewport(viewBox: [0, 0, 560, 160], size: .zero)
        #expect(empty.scale == 0)
        #expect(SpoolView.sceneWidth(for: CGSize(width: 560, height: 160)) == 560)
        #expect(SpoolView.sceneWidth(for: CGSize(width: 280, height: 80)) == 560)
    }

    @Test func pathDataHandlesTheCommandsThePrototypeUses() {
        let relative = SpoolPathGeometry.path(SpoolPathData("M-4 20v-6q4 -8 8 0v6"))
        let box = relative.boundingRect
        #expect(abs(box.minX - -4) < 1e-9 && abs(box.maxX - 4) < 1e-9)
        #expect(abs(box.maxY - 20) < 1e-9 && box.minY < 14)
        let brows = SpoolPathGeometry.path(SpoolPathData("M-38 -40l14 -5M15 -45l15 5")).boundingRect
        #expect(brows == CGRect(x: -38, y: -45, width: 68, height: 5))
        let mouth = SpoolPathGeometry.path(SpoolPathData("M-27 18H27L35 38H-35Z")).boundingRect
        #expect(mouth == CGRect(x: -35, y: 18, width: 70, height: 20))
        #expect(SpoolPathData("M-3 -5L-5 -10Q0 -13 5 -10L3 -5Z").segments.map(\.command) == ["M", "L", "Q", "L", "Z"])
        let face = SpoolCanvas.rgba("#AD714F")
        let expected: (Double, Double, Double) = (173.0 / 255, 113.0 / 255, 79.0 / 255)
        #expect(face?.r == expected.0 && face?.g == expected.1 && face?.b == expected.2 && face?.a == 1)
        #expect(SpoolCanvas.rgba("#d99c8660")?.a == 96.0 / 255)
        #expect(SpoolCanvas.rgba("transparent") == nil)
    }

    /// The lane ends at the cassette inlet and the flight starts at the mouth, in every layout.
    @Test func anchorsFollowTheCharacter() {
        let ready = SpoolScene.frame(.ready, t: 1.4, drive: .capture(level: 0))
        #expect(ready.mouth == SpoolPoint(488, 100.8))
        #expect(ready.inlet == SpoolPoint(438.4, 93.6))
        let narrow = SpoolScene.frame(.ready, t: 1.4, width: 380, drive: .capture(level: 0))
        #expect(abs(narrow.mouth.x - 319) < 1e-9 && abs(narrow.mouth.y - (76 + 31 * 0.65)) < 1e-9)
        for key in SpoolStateKey.allCases {
            for t in [0.0, 0.3, 0.9, 1.6] {
                let frame = SpoolScene.frame(key, t: t, drive: .simulation)
                let last = frame.lane.last!
                #expect(abs(last.x - frame.inlet.x) < 1e-9 && abs(last.y - frame.inlet.y) < 1e-9, "\(key) t=\(t)")
            }
        }
        // Inserting leans and lifts: the anchors move with the body.
        let inserting = SpoolScene.frame(.inserting, t: 0.5, drive: .simulation)
        #expect(inserting.mouth != SpoolPoint(488, 100.8))
        let anchors = SpoolAnchors(frame: ready, size: CGSize(width: 560, height: 160), origin: CGPoint(x: 100, y: 40))
        #expect(anchors.mouthAnchor == CGPoint(x: 588, y: 140.8))
        #expect(anchors.inletAnchor == CGPoint(x: 538.4, y: 133.6))
        let half = SpoolAnchors(frame: ready, size: CGSize(width: 280, height: 80), origin: .zero)
        #expect(half.mouthAnchor == CGPoint(x: 244, y: 50.4))
        let cameo = SpoolScene.cameo(.ready)
        #expect(cameo.mouth == SpoolPoint(0, 31))
    }

    /// The flight maths S4 uses: nothing before it starts or after the tail has fed in.
    @Test func flightIsFiniteAndReachesTheCaret() {
        let from = SpoolPoint(488, 100.8), to = SpoolPoint(140, 420)
        #expect(SpoolFlight.frame(t: 0, from: from, to: to, width: 900, height: 600) == nil)
        #expect(SpoolFlight.frame(t: SpoolFlight.duration, from: from, to: to, width: 900, height: 600) == nil)
        let arrived = try? #require(SpoolFlight.frame(t: 0.65, from: from, to: to, width: 900, height: 600))
        #expect(arrived?.head == 1)
        #expect(arrived?.points.count == SpoolFlight.samples)
        let tip = arrived?.points.last
        #expect(tip.map { abs($0.x - to.x) < 1e-6 && abs($0.y - to.y) < 1e-6 } == true)
    }

    /// Reduce Motion draws the still frame: no reel angle, flat tape.
    @Test func reduceMotionDrawsTheStillFrame() {
        let animator = SpoolAnimator()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        var frame = animator.frame(.listening, stateStartedAt: start, level: 1, at: start, reduceMotion: true, width: 560)
        frame = animator.frame(.listening, stateStartedAt: start, level: 1, at: start.addingTimeInterval(0.5), reduceMotion: true, width: 560)
        #expect(animator.reel.angle == 0)
        #expect(frame.activity == 0)
        #expect(frame.drawing == SpoolScene.frame(.listening, t: 0, still: true, drive: .capture(level: 1)).drawing)
    }

    @Test func v3MotionCarriesPhaseAndExpressionAcrossStateChanges() {
        let animator = SpoolAnimator()
        let start = Date(timeIntervalSinceReferenceDate: 100)
        for i in 0...60 {
            _ = animator.frame(.listening, stateStartedAt: start, level: 1,
                               at: start.addingTimeInterval(Double(i) / 60), reduceMotion: false, width: 560)
        }
        let previous = animator.motion, angle = animator.reel.angle
        let release = start.addingTimeInterval(1)
        _ = animator.frame(.finishing, stateStartedAt: release, level: 0, at: release, reduceMotion: false, width: 560)
        #expect(animator.motion == previous)
        #expect(animator.reel.angle == angle)
        _ = animator.frame(.finishing, stateStartedAt: release, level: 0, at: release.addingTimeInterval(0.05), reduceMotion: false, width: 560)
        #expect(animator.motion.phase > previous.phase)
        #expect(animator.motion.level < previous.level)
        #expect(animator.reel.angle < angle)
    }

    @Test func verifiedAcknowledgementLetsTheFiniteFeedComplete() {
        let animator = SpoolAnimator(), start = Date(timeIntervalSinceReferenceDate: 100)
        _ = animator.frame(.inserting, stateStartedAt: start, level: 0, at: start, reduceMotion: false, width: 560)
        _ = animator.frame(.inserting, stateStartedAt: start, level: 0, at: start.addingTimeInterval(0.1), reduceMotion: false, width: 560)
        let acknowledged = start.addingTimeInterval(0.1)
        _ = animator.frame(.inserted, stateStartedAt: acknowledged, level: 0, at: acknowledged, reduceMotion: false, width: 560)
        let angle = animator.reel.angle
        _ = animator.frame(.inserted, stateStartedAt: acknowledged, level: 0, at: acknowledged.addingTimeInterval(0.05), reduceMotion: false, width: 560)
        #expect(animator.reel.angle > angle)
        _ = animator.frame(.inserted, stateStartedAt: acknowledged, level: 0, at: start.addingTimeInterval(1.3), reduceMotion: false, width: 560)
        let parked = animator.reel.angle
        _ = animator.frame(.inserted, stateStartedAt: acknowledged, level: 0, at: start.addingTimeInterval(1.4), reduceMotion: false, width: 560)
        #expect(animator.reel.angle == parked)
    }

    @Test func v3FlightTracesAllLinesAndSettlesWithoutGeometryJump() throws {
        let lines = [SpoolFlight.Line(x: 100, y: 300, width: 220), .init(x: 100, y: 326, width: 80)]
        let frame = try #require(SpoolFlight.frame(t: 1.299999, from: .init(488, 100.8), lines: lines,
                                                 width: 900, height: 600, verified: true))
        #expect(frame.points.isEmpty)
        #expect(frame.linePoints.count == 2)
        #expect(frame.flattening > 0.999999)
        for (line, points) in zip(lines, frame.linePoints) {
            #expect(points.first == SpoolPoint(line.x, line.y))
            let end = try #require(points.last)
            #expect(abs(end.x - (line.x + line.width)) < 1e-9)
            #expect(abs(end.y - line.y) < 1e-9)
        }
        let rtl = try #require(SpoolFlight.frame(t: 1, from: .init(488, 100.8), lines: [.init(x: 320, y: 300, width: -220)],
                                               width: 900, height: 600))
        #expect(rtl.linePoints.first?.last?.x == 100)
    }

    @MainActor
    @Test func ribbonWrapOpacityCompositesTheWholeMaterialOnce() throws {
        let drawing = SpoolDrawing(viewBox: [0, 0, 30, 20], attributes: [], nodes: [
            .group(attributes: [.init("opacity", number: 0.5)], transform: nil, children: [
                SpoolRig.R(0, 0, 20, 20, 0, .hex(SpoolPalette.tapeFace)),
                SpoolRig.R(10, 0, 20, 20, 0, .hex(SpoolPalette.tapeFace)),
            ]),
        ])
        let renderer = ImageRenderer(content: Canvas { ctx, size in
            SpoolCanvas.draw(drawing, in: &ctx, size: size)
        }.frame(width: 30, height: 20))
        renderer.scale = 1
        let bitmap = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        let single = try #require(bitmap.colorAt(x: 5, y: 10))
        let overlap = try #require(bitmap.colorAt(x: 15, y: 10))
        #expect(abs(single.alphaComponent - 0.5) < 0.01)
        #expect(abs(overlap.alphaComponent - single.alphaComponent) < 0.01)
    }

    /// The renderer draws the cassette where the drawing puts it (a smoke test: the pixels are the
    /// housing's warm colours, and the empty lane corner stays clear). Real-display appearance is
    /// verified by eye against the prototype (build doc §5 item 7).
    @MainActor
    @Test func canvasRendersTheCassette() throws {
        let frame = SpoolScene.frame(.preview, t: 1.4, drive: .capture(level: 0))
        let view = Canvas { ctx, size in SpoolCanvas.draw(frame.drawing, in: &ctx, size: size) }
            .frame(width: 560, height: 160)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        let bitmap = NSBitmapImageRep(cgImage: image)
        // Housing face just inside the top-left of the shell (488 − 44, 76 − 41).
        let shell = try #require(bitmap.colorAt(x: 444, y: 35)?.usingColorSpace(.sRGB))
        #expect(shell.alphaComponent > 0.99)
        #expect(shell.redComponent > shell.blueComponent + 0.15, "warm housing colour, got \(shell)")
        // Top-left corner: nothing drawn.
        let corner = try #require(bitmap.colorAt(x: 4, y: 4))
        #expect(corner.alphaComponent < 0.01)
        // The lane passes the text side at y ≈ 98.
        let lane = try #require(bitmap.colorAt(x: 60, y: 98)?.usingColorSpace(.sRGB))
        #expect(lane.alphaComponent > 0.9)
    }
}
