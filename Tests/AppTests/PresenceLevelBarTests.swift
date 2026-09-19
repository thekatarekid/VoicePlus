import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import VoicePlusApp

/// FX5 — the chin's "Working…" pulse drifted left and shrank below its own minimum (owner's 1.11.1
/// screenshots: a 5–12 pt capsule, 12 pt left of the chin's centre, where the design says 28–95 pt,
/// centred). The pulse was a `repeatForever` animation started in `onAppear`, which also captured
/// the panel resize it was started during. It is now a pure function of time placed at the chin's
/// centre, so these check the arithmetic — and one rendered frame — instead of trusting an animation.
@Suite("Presence level bar: centred, bounded, still under Reduce Motion (FX5)")
struct PresenceLevelBarTests {
    /// The processing chin as logged on the owner's Mac (`frame={{840, 1116}, {120, 14}}`), the
    /// resting chin, and a wide hover-row-sized panel.
    static let chins = [CGSize(width: 120, height: 14), CGSize(width: 64, height: 14), CGSize(width: 190, height: 38)]
    /// Phases across two full cycles, plus a few "wall clock" times far from zero.
    static let times: [TimeInterval] = (0...32).map { Double($0) * LevelBarPulse.period / 16 }
        + [781_234_567.123, 781_234_568.01, 1_000_000.45]

    @Test("the pulse is symmetric about the chin's centre at every phase")
    func centredAtEveryPhase() {
        for chin in Self.chins {
            for t in Self.times {
                let rect = LevelBarPulse.frame(fraction: LevelBarPulse.pulseFraction(at: t, reduced: false), in: chin)
                #expect(abs(rect.midX - chin.width / 2) < 1e-9, "t=\(t) chin=\(chin): midX \(rect.midX)")
                #expect(abs(rect.minX - (chin.width - rect.maxX)) < 1e-9, "left and right gaps differ at t=\(t)")
                #expect(abs(rect.midY - chin.height / 2) < 1e-9)
            }
        }
    }

    @Test("the pulse stays within 0.25…0.85 of the track and reaches both ends")
    func boundedAndFull() {
        let chin = CGSize(width: 120, height: 14)
        let track = chin.width - 2 * LevelBarPulse.inset
        let fractions = Self.times.map { LevelBarPulse.pulseFraction(at: $0, reduced: false) }
        for f in fractions {
            #expect(f >= LevelBarPulse.minFraction - 1e-9 && f <= LevelBarPulse.maxFraction + 1e-9)
        }
        #expect(abs(LevelBarPulse.pulseFraction(at: 0, reduced: false) - LevelBarPulse.minFraction) < 1e-9)
        #expect(abs(LevelBarPulse.pulseFraction(at: LevelBarPulse.period / 2, reduced: false) - LevelBarPulse.maxFraction) < 1e-9)
        // Never the 5–12 pt sliver of the screenshots: the narrowest frame is a quarter of the track.
        let narrowest = Self.times.map { LevelBarPulse.frame(fraction: LevelBarPulse.pulseFraction(at: $0, reduced: false), in: chin).width }.min()!
        #expect(narrowest >= track * LevelBarPulse.minFraction - 1e-9, "narrowest \(narrowest) pt")
        // The capsule keeps its height (chin − 6) at every phase.
        #expect(LevelBarPulse.frame(fraction: 0.5, in: chin).height == 8)
    }

    @Test("the pulse is periodic and continuous — no jumps between frames")
    func periodicAndContinuous() {
        let slope = (LevelBarPulse.maxFraction - LevelBarPulse.minFraction) * .pi / LevelBarPulse.period
        for t in Self.times {
            let now = LevelBarPulse.pulseFraction(at: t, reduced: false)
            #expect(abs(now - LevelBarPulse.pulseFraction(at: t + LevelBarPulse.period, reduced: false)) < 1e-6)
            let frame = 1.0 / 30
            #expect(abs(LevelBarPulse.pulseFraction(at: t + frame, reduced: false) - now) <= slope * frame + 1e-6)
        }
    }

    @Test("Reduce Motion: the processing bar holds still, centred")
    func reduceMotionIsStatic() {
        let still = Set(Self.times.map { LevelBarPulse.pulseFraction(at: $0, reduced: true) })
        #expect(still == [LevelBarPulse.restingFraction], "one width, whatever the time")
        for chin in Self.chins {
            let rect = LevelBarPulse.frame(fraction: LevelBarPulse.restingFraction, in: chin)
            #expect(abs(rect.midX - chin.width / 2) < 1e-9)
        }
    }

    @Test("listening levels are centred too, floored and clamped")
    func levelsAreCentred() {
        let chin = CGSize(width: 120, height: 14)
        let track = chin.width - 2 * LevelBarPulse.inset
        for level: Float in [-1, 0, 0.06, 0.3, 0.77, 1, 4] {
            let rect = LevelBarPulse.frame(fraction: LevelBarPulse.levelFraction(level), in: chin)
            #expect(abs(rect.midX - chin.width / 2) < 1e-9, "level \(level)")
            #expect(rect.width <= track + 1e-9 && rect.minX >= LevelBarPulse.inset - 1e-9)
        }
        #expect(LevelBarPulse.levelFraction(0) == CGFloat(LevelBarPulse.levelFloor))
        #expect(LevelBarPulse.levelFraction(4) == 1)
    }

    /// One real frame of the processing chin, rendered: the lit columns of the capsule's middle row
    /// sit symmetrically about the chin's centre.
    @Test("a rendered processing chin draws its capsule centred")
    @MainActor func renderedFrameIsCentred() throws {
        let size = CGSize(width: 120, height: 14)
        let view = PresenceIndicatorView(state: .processing, hovered: false, cornerRadius: 6, hint: "")
            .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.cgImage, "the chin rendered")
        let width = image.width, height = image.height
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let row = height / 2
        let lit = (0..<width).filter { x in
            let p = pixels + (row * width + x) * 4
            return Int(p[0]) + Int(p[1]) + Int(p[2]) > 3 * 110   // the cream ink on the black chin
        }
        let first = try #require(lit.first, "the capsule is drawn")
        let last = try #require(lit.last)
        let centre = Double(first + last + 1) / 2
        #expect(abs(centre - Double(width) / 2) <= 1.0, "capsule spans \(first)…\(last) of \(width) px")
        let track = Double(width) - 2 * Double(LevelBarPulse.inset) * 2
        #expect(Double(last - first + 1) >= track * Double(LevelBarPulse.minFraction) - 2,
                "the capsule is never narrower than the design's minimum")
    }
}
