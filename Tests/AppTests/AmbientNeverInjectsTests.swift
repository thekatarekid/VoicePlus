import Engine
import Foundation
import Injection
import Shared
import Testing
@testable import VoicePlusApp

/// R8.1 — the one property this item exists to protect: **ambient speech cannot reach an injection
/// path.** V3 §8: "Transcript into Timeline only; never type or act from ambient speech."
///
/// Four independent proofs, each of which fails on its own:
///
/// 1. `ambientSpeechNeverTouchesDelivery` — the production `LatchRuntime` with a delivery spy that
///    records every call. Ambient text is stored in the real `AmbientTranscriptStore`; the spy is
///    never entered at all.
/// 2. `dictationSpeechDoesReachDelivery` — the control. Identical rig, `source = .dictation`, and the
///    spy *is* entered. Without this, proof 1 would also pass on a rig that delivers nothing, which
///    is the way this kind of test rots.
/// 3. `ambientSourcesNameNoDeliveryPath` / `injectionPathsNameNoAmbientCaptureType` — the static
///    audit over this checkout. Wiring ambient output into the injector means naming `AmbientEntry`
///    or `AmbientTranscriptSink` on an injection path, and there is no way to do that this misses.
/// 4. `ambientEntryIsNotAnythingTheInjectorAccepts` — the type audit, plus the runtime assertion that
///    the store is not an `Injector` and an `Injector` is not a transcript sink.
@Suite("Ambient speech never reaches an injection path (V3 §8)")
struct AmbientNeverInjectsTests {

    // MARK: A delivery that would be caught red-handed

    /// Records every call. Nothing here succeeds, because nothing here should ever be reached from
    /// ambient speech — and `entered` is what the assertions read.
    final class WatchfulDelivery: LatchDelivering, @unchecked Sendable {
        private let lock = NSLock()
        private var _delivered: [String] = []
        private var _held: [String] = []
        private var _insertHeldCalls = 0

        var delivered: [String] { lock.withLock { _delivered } }
        var held: [String] { lock.withLock { _held } }
        var insertHeldCalls: Int { lock.withLock { _insertHeldCalls } }
        /// Every way this object can be asked to put characters somewhere.
        var entered: Int { lock.withLock { _delivered.count + _held.count + _insertHeldCalls } }

        func deliver(_ spans: [TranscriptSpan], segment: SegmentID) async -> Bool {
            lock.withLock { _delivered.append(spans.map(\.text).joined(separator: " ")) }
            return true
        }

        func hold(_ spans: [TranscriptSpan], segment: SegmentID, reason: String) -> String {
            lock.withLock { _held.append(spans.map(\.text).joined(separator: " ")) }
            return "Notes"
        }

        func insertHeld(into target: String) -> Int {
            lock.withLock { _insertHeldCalls += 1 }
            return 0
        }
    }

    /// Collects capture decisions off whatever thread the latch's delivery chain is on.
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var decisions: [AmbientCaptureDecision] = []
        var all: [AmbientCaptureDecision] { lock.withLock { decisions } }
        func append(_ d: AmbientCaptureDecision) { lock.withLock { decisions.append(d) } }
    }

    static func temporaryStore(clock: @escaping @Sendable () -> Date = { Date() }) throws -> AmbientTranscriptStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("r81-inject-\(UUID().uuidString)", isDirectory: true)
        return AmbientTranscriptStore(meetings: MeetingStore(root: root),
                                     database: try AppDatabase.inMemory(),
                                     retention: { AmbientRetentionPolicy(days: 7) },
                                     clock: clock)
    }

    /// Ambient capture on, every speaker kept, so nothing *but* the injection rule can explain an
    /// empty store: a discard here would make the test pass for the wrong reason.
    static var wideOpenGate: AmbientCaptureGate {
        AmbientCaptureGate(isEnabled: true, capturesEverySpeaker: true,
                           filter: SpeakerFilter(isOn: false, gate: SpeakerGate(profile: nil), canIdentify: false))
    }

    static func closedSegment(_ text: String, index: Int = 0, session: UUID) -> SegmentEvent {
        .closed(segment: SegmentID(sessionID: session, index: index),
                spans: [TranscriptSpan(text: text, confidence: 0.9, audioRange: 0...1, provenance: [.asr])],
                stability: .committed, reason: .endpoint)
    }

    // MARK: 1 — behaviour: the production path

    @Test("ambient speech is stored as transcript and the delivery spy is never entered")
    func ambientSpeechNeverTouchesDelivery() async throws {
        let spy = WatchfulDelivery()
        let runtime = LatchRuntime(delivery: spy)
        runtime.isLatched = { true }
        runtime.source = .ambient
        let store = try Self.temporaryStore()
        let decisions = Recorder()
        AmbientWiring.attach(to: runtime, sink: store, gate: { Self.wideOpenGate },
                             onDecision: { decisions.append($0) })

        let session = UUID()
        runtime.handle(Self.closedSegment("someone in the room said this", session: session))
        runtime.handle(Self.closedSegment("and then said this", index: 1, session: session))
        await runtime.settle()

        // Stored: the whole point of ambient capture.
        #expect(store.entries().map(\.text).sorted() == ["and then said this", "someone in the room said this"])
        #expect(decisions.all.count == 2)
        #expect(decisions.all.allSatisfy { $0.kept != nil })

        // Not delivered — and not "delivered and then discarded": the spy was never entered.
        #expect(spy.entered == 0, "ambient speech reached a delivery call")
        #expect(spy.delivered.isEmpty, "ambient speech was typed")
        #expect(spy.held.isEmpty, "ambient speech was queued for typing")
        #expect(spy.insertHeldCalls == 0)
        #expect(runtime.deliveredText.isEmpty, "ambient speech was recorded as delivered")
        #expect(runtime.outcomes.allSatisfy {
            if case .transcript = $0.outcome { return true } else { return false }
        }, "an ambient segment ended in an outcome other than .transcript")
    }

    /// Even a focus change — the state whose whole job is to *hold text for later typing* — must not
    /// give ambient speech a route in. A held item is a queued insertion.
    @Test("ambient speech is not held for later insertion when delivery is paused")
    func pausedDeliveryDoesNotHoldAmbientSpeech() async throws {
        let spy = WatchfulDelivery()
        let runtime = LatchRuntime(delivery: spy)
        runtime.isLatched = { true }
        runtime.source = .ambient
        let store = try Self.temporaryStore()
        AmbientWiring.attach(to: runtime, sink: store, gate: { Self.wideOpenGate })

        runtime.pauseDelivery(awaiting: "Notes")
        runtime.handle(Self.closedSegment("said while focus was elsewhere", session: UUID()))
        await runtime.settle()

        #expect(spy.entered == 0, "ambient speech was held for insertion")
        #expect(store.entries().count == 1)
        // And the explicit resume — the only thing that empties the held queue — has nothing to find.
        #expect(runtime.resumeDelivery(into: "Notes") == 0)
    }

    // MARK: 2 — the control, so proof 1 cannot rot into a tautology

    @Test("the same rig does deliver dictated speech (so proof 1 is about ambient, not about the rig)")
    func dictationSpeechDoesReachDelivery() async throws {
        let spy = WatchfulDelivery()
        let runtime = LatchRuntime(delivery: spy)
        runtime.isLatched = { true }
        runtime.source = .dictation
        let store = try Self.temporaryStore()
        AmbientWiring.attach(to: runtime, sink: store, gate: { Self.wideOpenGate })

        runtime.handle(Self.closedSegment("type this please", session: UUID()))
        await runtime.settle()

        #expect(spy.delivered == ["type this please"], "the rig does not deliver at all — proof 1 proves nothing")
        #expect(store.entries().isEmpty, "dictated speech was written to the ambient Timeline")
    }

    // MARK: 3 — the static audit

    @Test("no file under App/Ambient names a way to deliver text")
    func ambientSourcesNameNoDeliveryPath() throws {
        let root = try #require(AmbientInjectionAudit.packageRoot(),
                                "the audit could not find the checkout — it must fail, not pass quietly")
        #expect(AmbientInjectionAudit.auditedFileCount(root: root) > 10,
                "the audit read almost nothing; the root is wrong")
        let violations = try #require(AmbientInjectionAudit.auditSources(root: root))
        let outbound = violations.filter { $0.file.hasPrefix(AmbientInjectionAudit.ambientDirectory) }
        #expect(outbound.isEmpty, "\(outbound.map(\.description))")
    }

    @Test("no file on an injection path names an ambient-capture type")
    func injectionPathsNameNoAmbientCaptureType() throws {
        let root = try #require(AmbientInjectionAudit.packageRoot())
        let violations = try #require(AmbientInjectionAudit.auditSources(root: root))
        let inbound = violations.filter { !$0.file.hasPrefix(AmbientInjectionAudit.ambientDirectory) }
        #expect(inbound.isEmpty, "\(inbound.map(\.description))")
    }

    /// The audit has to be able to *fail*, or the two tests above say nothing. This feeds it a
    /// directory that does contain the forbidden names and checks that it objects.
    @Test("the audit really does catch a file that names an injector")
    func theAuditCatchesAViolation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("r81-audit-\(UUID().uuidString)", isDirectory: true)
        let ambient = root.appendingPathComponent(AmbientInjectionAudit.ambientDirectory, isDirectory: true)
        let injection = root.appendingPathComponent("Injection", isDirectory: true)
        try FileManager.default.createDirectory(at: ambient, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: injection, withIntermediateDirectories: true)
        try "// Package\n".write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try """
            import Injection
            func leak(_ injector: any Injector) {}
            """.write(to: ambient.appendingPathComponent("Leak.swift"), atomically: true, encoding: .utf8)
        try """
            func wire(_ sink: any AmbientTranscriptSink, _ entry: AmbientEntry) {}
            """.write(to: injection.appendingPathComponent("Wired.swift"), atomically: true, encoding: .utf8)

        let violations = try #require(AmbientInjectionAudit.auditSources(root: root))
        #expect(violations.contains { $0.symbol == "import Injection" })
        #expect(violations.contains { $0.symbol == "Injector" })
        #expect(violations.contains { $0.symbol == "AmbientTranscriptSink" && $0.file.hasPrefix("Injection") })
        #expect(violations.contains { $0.symbol == "AmbientEntry" && $0.file.hasPrefix("Injection") })
        try? FileManager.default.removeItem(at: root)
    }

    /// …and it must not fire on prose. Every one of these files explains the rule in a comment, which
    /// an audit that scanned raw lines would report as a breach of it.
    @Test("the audit ignores comments, so documenting the rule does not break it")
    func theAuditIgnoresProse() {
        let lines = AmbientInjectionAudit.code(in: """
            // this comment names Injector and AmbientEntry
            let kept = 1  // and so does this one: import Injection
            /* block: Injector */ let also = 2
            /*
            Injector
            */
            let third = 3
            """)
        #expect(lines.joined(separator: "\n").contains("Injector") == false)
        #expect(lines.joined(separator: "\n").contains("AmbientEntry") == false)
        #expect(lines.contains { $0.contains("let kept = 1") })
        #expect(lines.contains { $0.contains("let also = 2") })
        #expect(lines.contains { $0.contains("let third = 3") })
    }

    // MARK: 4 — the type audit

    @Test("an ambient entry carries nothing the injector accepts, and the sink is not an injector")
    func ambientEntryIsNotAnythingTheInjectorAccepts() throws {
        #expect(AmbientInjectionAudit.auditEntryShape().isEmpty,
                "\(AmbientInjectionAudit.auditEntryShape())")

        let store = try Self.temporaryStore()
        #expect(!(store is any Injector), "the ambient store is an Injector")
        #expect(!(store is any LatchDelivering), "the ambient store can deliver text")

        // And the reverse: the production injector cannot stand in for a transcript sink, so no
        // `AmbientWiring.attach(sink:)` call can be pointed at it.
        let injector: any Injector = TextInjector(system: MockSystemAccess())
        #expect(!(injector is any AmbientTranscriptSink), "an Injector is usable as an ambient sink")
    }

    /// The sink protocol's whole surface: one call, returning an id. Nothing that reports a delivery
    /// outcome, so nothing downstream can branch on "was it typed?".
    @Test("the transcript sink has no delivery surface at all")
    func theSinkHasNoDeliverySurface() throws {
        let store = try Self.temporaryStore()
        let sink: any AmbientTranscriptSink = store
        let id = try sink.store(AmbientEntry(speaker: .you, text: "hello", capturedAt: Date()))
        #expect(id.hasPrefix("ambient-"))
        #expect(!(sink is any Injector))
    }
}
