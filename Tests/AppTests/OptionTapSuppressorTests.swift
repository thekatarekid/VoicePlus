import CoreGraphics
import Foundation
import Testing
@testable import VoicePlusApp

/// X2 (owner round 4) — the active tap's pure decision: first tap passes, the second press and its
/// release within 350 ms of a clean tap are dropped (Claude sees one tap) while VoicePlus latches;
/// a key / click / scroll during the dropped press re-posts it as a chord. Synthetic flag words and
/// timestamps through `HotkeyBinding.edge` — no live tap.
@Suite("X2 — Option double-tap suppressor")
struct OptionTapSuppressorTests {
    typealias S = OptionDoubleTapSuppressor
    private static let left = CGEventFlags.maskAlternate.rawValue | HotkeyBinding.Kind.deviceLeftAltMask
    private static let right = CGEventFlags.maskAlternate.rawValue | HotkeyBinding.Kind.deviceRightAltMask
    private static let option = HotkeyBinding(kind: .option)

    /// Feeds flag words the way the tap does: binding edge → suppressor, and the same edge to the
    /// gesture machine (the tap feeds `HotkeyService` with every Option edge, dropped or not).
    struct Rig {
        var s = S()
        var m = HotkeyStateMachine()
        var decisions: [S.Decision] = []
        var actions: [HotkeyStateMachine.Action] = []

        mutating func flags(_ keyCode: Int64, _ flags: UInt64, _ t: TimeInterval) {
            guard let edge = OptionTapSuppressorTests.option.edge(keyCode: keyCode, flags: flags) else { return }
            decisions.append(s.option(edge, at: t))
            actions += edge == .down ? m.keyDown(at: t) : m.keyUp(at: t)
        }

        mutating func other(_ t: TimeInterval) {
            decisions.append(s.otherInput(at: t))
            actions += m.otherInput(at: t)
        }
    }

    @Test("double tap: the first tap passes, the second press and release are dropped, VoicePlus latches")
    func doubleTapSecondDropped() {
        var r = Rig()
        r.flags(58, Self.left, 0)
        r.flags(58, 0, 0.08)
        r.flags(58, Self.left, 0.25)
        r.flags(58, 0, 0.32)
        #expect(r.decisions == [.pass, .pass, .drop, .drop])
        #expect(r.actions == [.startCapture, .cancelCapture, .startCapture, .enterLatch])
        #expect(r.m.phase == .latched)
    }

    @Test("left then right Option counts as a double tap too")
    func crossSides() {
        var r = Rig()
        r.flags(58, Self.left, 0); r.flags(58, 0, 0.05)
        r.flags(61, Self.right, 0.2); r.flags(61, 0, 0.26)
        #expect(r.decisions == [.pass, .pass, .drop, .drop])
    }

    @Test("a second press after 350 ms is a fresh first tap and passes")
    func outsideWindowPasses() {
        var r = Rig()
        r.flags(58, Self.left, 0); r.flags(58, 0, 0.05)
        r.flags(58, Self.left, 0.5); r.flags(58, 0, 0.55)
        #expect(r.decisions == [.pass, .pass, .pass, .pass])
    }

    @Test("a hold is not a clean tap: the next press passes")
    func holdDoesNotArm() {
        var r = Rig()
        r.flags(58, Self.left, 0); r.flags(58, 0, 0.6)
        r.flags(58, Self.left, 0.7); r.flags(58, 0, 0.75)
        #expect(r.decisions == [.pass, .pass, .pass, .pass])
    }

    @Test("Option+key as the first press is not a clean tap")
    func chordDoesNotArm() {
        var r = Rig()
        r.flags(58, Self.left, 0); r.other(0.03); r.flags(58, 0, 0.06)
        r.flags(58, Self.left, 0.15); r.flags(58, 0, 0.2)
        #expect(r.decisions == [.pass, .pass, .pass, .pass, .pass])
    }

    @Test("a key between the taps breaks the pair")
    func inputBetween() {
        var r = Rig()
        r.flags(58, Self.left, 0); r.flags(58, 0, 0.05)
        r.other(0.1)
        r.flags(58, Self.left, 0.2); r.flags(58, 0, 0.25)
        #expect(r.decisions == [.pass, .pass, .pass, .pass, .pass])
    }

    @Test("Option+key during the dropped second press: re-post Option-down then the key; the release passes; no latch")
    func chordDuringSecondPress() {
        var r = Rig()
        r.flags(58, Self.left, 0); r.flags(58, 0, 0.05)
        r.flags(58, Self.left, 0.2)
        r.other(0.25)
        r.flags(58, 0, 0.4)
        #expect(r.decisions == [.pass, .pass, .drop, .repostOptionDownThenEvent, .pass])
        #expect(!r.actions.contains(.enterLatch))
        #expect(r.actions.last == .cancelCapture, "X1: the chord cancels silently")
        #expect(r.m.lastCancel == .chord)
        #expect(r.s.pressDownAt == nil && !r.s.suppressing)
    }

    @Test("the other side going down during a dropped press is dropped with it")
    func otherSideDuringDrop() {
        var r = Rig()
        r.flags(58, Self.left, 0); r.flags(58, 0, 0.05)
        r.flags(58, Self.left, 0.2)
        r.flags(61, Self.left | Self.right, 0.22)
        r.flags(58, Self.right, 0.25)
        r.flags(61, 0, 0.27)
        #expect(r.decisions == [.pass, .pass, .drop, .drop, .drop, .drop])
    }

    @Test("a triple tap: third press is a fresh first tap (passes)")
    func tripleTap() {
        var r = Rig()
        for (i, t) in [0.0, 0.15, 0.3].enumerated() {
            r.flags(58, Self.left, t); r.flags(58, 0, t + 0.05)
            _ = i
        }
        #expect(r.decisions == [.pass, .pass, .drop, .drop, .pass, .pass])
    }

    @Test("the re-post tag is VoicePlus's own")
    func tag() {
        #expect(OptionKeyEventTap.userDataTag == 0x564F_4943_504C_5553)
    }

    @Test("Option bindings are the ones the tap serves")
    func optionKinds() {
        #expect(HotkeyBinding.Kind.option.isOption)
        #expect(HotkeyBinding.Kind.leftOption.isOption && HotkeyBinding.Kind.rightOption.isOption)
        #expect(!HotkeyBinding.Kind.fn.isOption && !HotkeyBinding.Kind.controlOptionD.isOption)
    }

    @Test("fallback notice: once, ever")
    func fallbackOnce() {
        let d = UserDefaults(suiteName: "AppTests.optionTapFallback.\(UUID())")!
        #expect(OptionTapFallbackNotice.takeOnce(d))
        #expect(!OptionTapFallbackNotice.takeOnce(d))
        #expect(OptionTapFallbackNotice.text.contains("Claude › Settings › General › Quick access shortcut"))
    }

    @MainActor
    @Test("fallback wiring tells the turn controller once, including a failure before wiring")
    func fallbackWiring() {
        let d = UserDefaults(suiteName: "AppTests.optionTapWiring.\(UUID())")!
        let h = TurnControllerTests.Harness()
        var notes: [String] = []
        h.controller.onNote = { notes.append($0) }
        let service = HotkeyService(defaults: UserDefaults(suiteName: "AppTests.optionTapSvc.\(UUID())")!)
        TurnWiring.wireOptionTapFallback(service, controller: { h.controller }, defaults: d)
        service.onOptionTapUnavailable?()
        service.onOptionTapUnavailable?()
        #expect(notes == [OptionTapFallbackNotice.text])
    }
}
