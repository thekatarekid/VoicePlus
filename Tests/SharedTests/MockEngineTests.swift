import Combine
import Foundation
import Testing
@testable import Shared

private func collectUntilFinal(_ stream: AsyncStream<EngineEvent>) -> Task<[EngineEvent], Never> {
    Task {
        var events: [EngineEvent] = []
        for await event in stream {
            events.append(event)
            if case .final = event { break }
        }
        return events
    }
}

@Suite struct MockEngineTests {
    @Test(arguments: ["email_reply", "code_comment", "chat_noisy"])
    func fixtureLoadsAndIsWellFormed(name: String) throws {
        let fixture = try TranscriptFixture.load(named: name)
        #expect(fixture.name == name)
        #expect(!fixture.spans.isEmpty)
        for span in fixture.spans {
            #expect(span.audioStart <= span.audioEnd, "\(name): \(span.text)")
            #expect((0...1).contains(span.confidence), "\(name): \(span.text)")
        }
        // Every fixture has at least one low-confidence span so repair paths can be exercised.
        #expect(fixture.spans.contains { $0.confidence < TranscriptSpan.lowConfidenceThreshold })
    }

    @Test func missingFixtureThrows() {
        #expect(throws: EngineError.self) { try TranscriptFixture.load(named: "does_not_exist") }
    }

    @Test func streamsFixtureThenReturnsFinalSpans() async throws {
        let engine = try MockEngine(fixtureNamed: "email_reply", delayScale: 0.01)
        let fixture = engine.fixture
        let collector = collectUntilFinal(engine.events())

        try await engine.start(prewarm: true)
        // Let a few partials arrive, then stop: remaining spans must flush into the final result.
        try await Task.sleep(nanoseconds: 30_000_000)
        let final = try await engine.stop()
        let events = await collector.value

        #expect(final.map(\.text) == fixture.spans.map(\.text))
        #expect(final.allSatisfy { $0.provenance == [.asr] })
        #expect(events.contains(.state(.prewarming)))
        #expect(events.contains { if case .state(.listening) = $0 { return true } else { return false } })
        #expect(events.contains { if case .partial = $0 { return true } else { return false } })
        #expect(events.last == .final(final))
        #expect(engine.state == .idle)
    }

    @Test func partialsAreCumulativeAndPreviewTextTracksThem() async throws {
        let engine = try MockEngine(fixtureNamed: "code_comment", delayScale: 0)
        let collector = collectUntilFinal(engine.events())
        try await engine.start(prewarm: false)
        try await Task.sleep(nanoseconds: 50_000_000)
        _ = try await engine.stop()
        let events = await collector.value

        let partials = events.compactMap { event -> [TranscriptSpan]? in
            if case let .partial(spans) = event { return spans } else { return nil }
        }
        #expect(partials.count == engine.fixture.spans.count)
        for (index, partial) in partials.enumerated() {
            #expect(partial.count == index + 1)
        }
        let previews = events.compactMap { event -> String? in
            if case let .state(.previewing(text)) = event { return text } else { return nil }
        }
        #expect(previews.last == partials.last?.joinedText)
    }

    @Test func poorMicFixtureEmitsWarning() async throws {
        let engine = try MockEngine(fixtureNamed: "chat_noisy", delayScale: 0)
        let seen = StateSink()
        let cancellable = engine.statePublisher.sink { seen.append($0) }
        defer { cancellable.cancel() }

        let stream = engine.events()
        let firstMic = Task { () -> MicQuality? in
            for await event in stream {
                if case let .micQuality(q) = event { return q }
            }
            return nil
        }
        try await engine.start(prewarm: false)
        let quality = await firstMic.value
        #expect(quality?.verdict == .poor)
        #expect(seen.states.contains { if case .warning = $0 { return true } else { return false } })
        await engine.cancel()
        #expect(engine.state == .idle)
    }

    @Test func stopWithoutStartThrowsAndDoubleStartThrows() async throws {
        let engine = try MockEngine(fixtureNamed: "email_reply", delayScale: 0)
        await #expect(throws: EngineError.notListening) { _ = try await engine.stop() }
        try await engine.start(prewarm: false)
        await #expect(throws: EngineError.alreadyListening) { try await engine.start(prewarm: false) }
        await engine.cancel()
    }
}

private final class StateSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [EngineState] = []
    var states: [EngineState] { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ s: EngineState) { lock.lock(); storage.append(s); lock.unlock() }
}
