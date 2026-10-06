import Engine
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// Launch fix (2026-10-06 investigation, RC2–RC4) end to end: `DictationCoordinator` +
/// `TurnController` (the S3 harness) + a real `RealEngine` whose model load is gated, the way the
/// first launch after an update spends 40–50 s recompiling it.
///
/// On 2026-10-06 the first press (8.2 s hold) recorded 30.3 s, sat on "Starting…" for the whole hold
/// and "Finishing…" for 20 s after it, refused four more presses (K04), was cancelled, and the press
/// after that opened capture 3.9 s late behind the dropped final pass.
@Suite("Launch fix — a press while the speech model is still loading", .serialized)
struct LaunchColdPressTests {
    final class GatedProvider: RecognizerProvider, @unchecked Sendable {
        let final: FinalRecognizer
        private let lock = NSLock()
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var open = false
        private var _resolves = 0
        var resolves: Int { lock.withLock { _resolves } }
        init(final: FinalRecognizer) { self.final = final }
        func release() {
            let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                open = true
                defer { waiters.removeAll() }
                return waiters
            }
            pending.forEach { $0.resume() }
        }
        func resolve() async throws -> (final: FinalRecognizer, preview: PreviewRecognizer?) {
            lock.withLock { _resolves += 1 }
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let ready = lock.withLock { () -> Bool in
                    if open { return true }
                    waiters.append(c)
                    return false
                }
                if ready { c.resume() }
            }
            return (final, nil)
        }
    }

    final class Words: FinalRecognizer, @unchecked Sendable {
        let name = "words"
        private let lock = NSLock()
        private var _received: [Int] = []
        var received: [Int] { lock.withLock { _received } }
        func recognize(_ samples: [Float]) async throws -> [TranscriptSpan] {
            lock.withLock { _received.append(samples.count) }
            return TurnControllerTests.words("hello there")
        }
    }

    final class Mic: AudioSource, @unchecked Sendable {
        var sink: ((UnsafeBufferPointer<Float>) -> Void)?
        private let lock = NSLock()
        private var _starts = 0, _stops = 0, running = false
        var starts: Int { lock.withLock { _starts } }
        var stops: Int { lock.withLock { _stops } }
        var isOpen: Bool { lock.withLock { running } }
        func prewarm() throws {}
        func start() throws { lock.withLock { _starts += 1; running = true } }
        func stop() { lock.withLock { _stops += 1; running = false } }
        func speak(seconds: Double) {
            guard isOpen else { return }
            let block = [Float](repeating: 0.2, count: Int(seconds * 16_000))
            block.withUnsafeBufferPointer { sink?($0) }
        }
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var set = false
        var value: Bool { lock.withLock { set } }
        func raise() { lock.withLock { set = true } }
    }

    struct Rig {
        let h = TurnControllerTests.Harness()
        let words = Words()
        let provider: GatedProvider
        let mic = Mic()
        let engine: RealEngine
        let coordinator: DictationCoordinator

        init() {
            provider = GatedProvider(final: words)
            engine = RealEngine(audio: mic, provider: provider)
            coordinator = DictationCoordinator(engine: engine, database: nil, pill: PillPanelController())
            coordinator.turns = h.controller
        }

        /// `settle()` bounded: false if the chain is still busy after `seconds` (the RC4 wedge).
        func settles(within seconds: TimeInterval) async -> Bool {
            let done = Flag()
            let coordinator = self.coordinator
            Task { await coordinator.settle(); done.raise() }
            return await waitLonger(done, seconds)
        }

        private func waitLonger(_ flag: Flag, _ seconds: TimeInterval) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if flag.value { return true }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            return flag.value
        }
    }

    @Test("the hold is recorded exactly: capture opens at key-down and closes at key-up, model or not")
    @MainActor func holdIsRecordedExactly() async throws {
        let rig = Rig()
        rig.coordinator.start()
        #expect(await rig.settles(within: 5), "key-down waited for the model")
        let id = try #require(rig.coordinator.currentTurn)
        #expect(rig.h.controller.stage(of: id) == .listening, "the turn must leave Starting… once capture is open (RC3)")
        #expect(rig.mic.isOpen)

        rig.mic.speak(seconds: 1.0)
        rig.coordinator.finalize()                       // key-up
        #expect(await rig.h.wait { rig.mic.stops == 1 }, "the microphone stayed open after key-up (RC2)")
        #expect(rig.h.controller.stage(of: id) == .finishing)
        rig.mic.speak(seconds: 5.0)                      // the room after key-up: not recorded

        rig.provider.release()                           // the model lands
        #expect(await rig.settles(within: 10))
        #expect(rig.words.received == [16_000], "the final pass must decode exactly the 1 s hold")
        #expect(rig.h.controller.stage(of: id) == .finalPreview, "the words go on to the preview and the write")
        #expect(rig.provider.resolves == 1)
    }

    @Test("a turn cancelled while it waits for the model does not hold the next press (RC4)")
    @MainActor func cancelledWaitFreesTheNextPress() async throws {
        let rig = Rig()
        rig.coordinator.start()
        #expect(await rig.settles(within: 5))
        let first = try #require(rig.coordinator.currentTurn)
        rig.mic.speak(seconds: 1.0)
        rig.coordinator.finalize()
        #expect(await rig.h.wait { rig.mic.stops == 1 })

        // The 10 s offer's Cancel (no live words: the preview model is loading too).
        rig.h.controller.cancelFinishing()
        #expect(rig.h.controller.stage(of: first) == nil || rig.h.controller.stage(of: first) == .cancelled)
        #expect(await rig.settles(within: 5), "the chain still waits for a model nobody needs (RC4)")

        // The next press opens capture straight away; the model is still loading.
        rig.coordinator.start()
        #expect(await rig.settles(within: 5), "the next press's capture queued behind the dead final pass")
        let second = try #require(rig.coordinator.currentTurn)
        #expect(second != first)
        #expect(rig.mic.starts == 2 && rig.mic.isOpen)
        #expect(rig.h.controller.stage(of: second) == .listening)
        #expect(rig.words.received.isEmpty, "the cancelled turn's audio must not be decoded")

        rig.mic.speak(seconds: 0.5)
        rig.provider.release()
        rig.coordinator.finalize()
        #expect(await rig.settles(within: 10))
        #expect(rig.words.received == [8_000])
        #expect(rig.provider.resolves == 1, "one model load serves both presses")
    }
}
