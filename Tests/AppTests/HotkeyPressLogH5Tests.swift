import CoreGraphics
import Foundation
import Testing
@testable import VoicePlusApp

/// H5 — one notice line per press (sequence, duration, gesture class, result; never text) and the
/// Secure Input flag at key-down (app name only). Synthetic flag words; no live tap.
@Suite("H5 — per-press log line")
struct HotkeyPressLogH5Tests {
    private static let left = CGEventFlags.maskAlternate.rawValue | HotkeyBinding.Kind.deviceLeftAltMask

    final class Box { var records: [HotkeyPressRecord] = [] }

    private func service(secure: HotkeySecureInput = .off) -> (HotkeyService, Box) {
        let d = UserDefaults(suiteName: "AppTests.h5.\(UUID())")!
        let s = HotkeyService(defaults: d)
        s.setBinding(.option)
        s.otherInputWithin = { _ in false }
        s.surfaceShowing = { false }
        s.secureInputProbe = { secure }
        let box = Box()
        s.onPressLogged = { box.records.append($0) }
        return (s, box)
    }

    private func press(_ s: HotkeyService, _ down: TimeInterval, _ up: TimeInterval) {
        s.handle(keyCode: 58, flags: Self.left, timestamp: down)
        s.handle(keyCode: 58, flags: 0, timestamp: up)
    }

    @Test("every press yields exactly one record: tap, double tap, hands-free stop, fold, hold")
    func onePerPress() {
        let (s, box) = service()
        press(s, 0, 0.08)        // tap
        press(s, 0.2, 0.28)      // double tap → hands-free
        press(s, 3, 3.08)        // stop
        press(s, 3.2, 3.3)       // folded (H29)
        press(s, 6, 7.2)         // hold
        #expect(box.records.map(\.sequence) == [1, 2, 3, 4, 5])
        #expect(box.records.map(\.gesture) == [.tap, .doubleTap, .latchStop, .folded, .hold])
        #expect(box.records.map(\.result) == ["cancel", "hands-free", "finalize", "none", "finalize"])
        #expect(box.records.map(\.durationMs) == [80, 80, 80, 100, 1200])
        #expect(s.lastPressRecord == box.records.last)
    }

    @Test("key repeat and the other Option side do not open a second press")
    func repeatsDoNotCount() {
        let (s, box) = service()
        s.handle(keyCode: 58, flags: Self.left, timestamp: 0)
        s.handle(keyCode: 58, flags: Self.left, timestamp: 0.1)
        s.handle(keyCode: 58, flags: 0, timestamp: 0.9)
        #expect(box.records.count == 1)
        #expect(box.records.first?.durationMs == 900)
    }

    @Test("Option + another key logs a chord press, result cancel")
    func chordPress() {
        let (s, box) = service()
        s.handle(keyCode: 58, flags: Self.left, timestamp: 0)
        s.noteOtherInput(at: 0.1)
        s.handle(keyCode: 58, flags: 0, timestamp: 0.3)
        #expect(box.records.count == 1)
        #expect(box.records.first?.gesture == .chord)
    }

    @Test("lost key-up and a reset each close the open press")
    func lostAndReset() {
        let (s, box) = service()
        s.modifierFlags = { 0 }
        s.uptime = { 2 }
        s.handle(keyCode: 58, flags: Self.left, timestamp: 1)
        for _ in 0..<HotkeyService.releasePollStrikes { s.checkForLostKeyUp() }
        #expect(box.records.last?.gesture == .lostKeyUp)
        #expect(box.records.last?.durationMs == 1000)
        s.handle(keyCode: 58, flags: Self.left, timestamp: 3)
        s.resetGesture()
        #expect(box.records.last?.result == "reset")
        #expect(box.records.count == 2)
    }

    @Test("Secure Input at key-down: flag + app name only; off names no app")
    func secureInput() {
        let (s, box) = service(secure: HotkeySecureInput(on: true, app: "1Password"))
        press(s, 0, 0.6)
        let line = try! #require(box.records.first).line
        #expect(line.contains("secure input on (1Password)"))
        #expect(HotkeySecureInput(on: false, app: "Mail").app == nil, "an app is named only while on")
        let (s2, box2) = service()
        press(s2, 0, 0.6)
        #expect(box2.records.first?.line.hasSuffix("secure input off") == true)
    }

    @Test("the line carries no text fields — only counts, classes and the flag")
    func noText() {
        let r = HotkeyPressRecord(sequence: 7, durationMs: 420, gesture: .hold, result: "finalize", secureInput: .off)
        #expect(r.line == "hotkey: press #7 420 ms · hold · result finalize · secure input off")
    }
}
