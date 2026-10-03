import Foundation
import Testing
import Shared
@testable import Engine

/// Hands-free fix (RC5) — a preview recognizer that confirms an end of utterance (the EOU head) is
/// announced once, on the open segment, as `SegmentEvent.endOfUtterance`; the formatting wrapper
/// passes it through.
@Suite("Hands-free: end of utterance from the preview (RC5)")
struct EndOfUtteranceEventTests {
    /// Reports an end of utterance once `after` samples have been fed, once per reset.
    final class EOUPreview: PreviewRecognizer, EndOfUtteranceReporting, @unchecked Sendable {
        private let lock = NSLock()
        private var fed = 0
        private var reported = false
        let after: Int
        init(after: Int) { self.after = after }
        func feed(_ samples: [Float]) async throws -> String {
            lock.withLock { fed += samples.count; return "words \(fed)" }
        }
        func reset() async { lock.withLock { fed = 0; reported = false } }
        func takeEndOfUtterance() async -> Bool {
            lock.withLock {
                guard fed >= after, !reported else { return false }
                reported = true
                return true
            }
        }
    }

    @Test func endOfUtteranceIsAnnouncedOnceOnTheOpenSegment() async throws {
        let audio = SegmentAudioSource()
        let preview = FormattedPreviewRecognizer(EOUPreview(after: 8_000))
        let engine = RealEngine(audio: audio,
                                provider: StaticRecognizerProvider(final: LengthNamingFinal(), preview: preview))
        engine.previewBlock = 0.05
        let log = SegmentLog(engine)
        defer { log.stop() }

        try await engine.start(prewarm: true)
        audio.push(seconds: 1.0)
        let eou: () -> [SegmentID] = {
            log.events.compactMap { if case .endOfUtterance(let s) = $0 { return s } else { return nil } }
        }
        for _ in 0..<200 where eou().isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        audio.push(seconds: 0.5)
        try await Task.sleep(nanoseconds: 100_000_000)
        _ = try await engine.stop()

        #expect(eou().count == 1, "once per segment: \(eou())")
        #expect(eou().first?.index == 0)
    }

    @Test func formattedWrapperForwardsTheSignal() async throws {
        let base = EOUPreview(after: 1)
        let wrapped = FormattedPreviewRecognizer(base)
        #expect(await wrapped.takeEndOfUtterance() == false)
        _ = try await wrapped.feed([0.1, 0.2])
        #expect(await wrapped.takeEndOfUtterance())
        #expect(await wrapped.takeEndOfUtterance() == false)
        #expect(await FormattedPreviewRecognizer(CountingPreview()).takeEndOfUtterance() == false)
    }
}
