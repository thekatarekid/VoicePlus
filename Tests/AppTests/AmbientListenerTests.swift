import Engine
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// V5 L3 — ambient on the always-on capture (X13). The listener is a recorder on O1's broadcaster,
/// segments on VAD edges, transcribes only closed speech segments, and runs the speaker verdict on
/// each segment's own samples — so an enrolled user's ambient speech is kept (X13 discarded it all).
@Suite("V5 L3 AmbientListener")
struct AmbientListenerTests {
    // MARK: Rig

    /// A capture you drive by hand: `attachAmbient` hands out a stream the test yields into.
    final class FakeCapture: AmbientAudioAttaching, @unchecked Sendable {
        private let lock = NSLock()
        private var cont: AsyncStream<AudioPipelineEvent>.Continuation?
        var failWith: Error?
        private(set) var attaches = 0
        private(set) var detaches = 0

        func attachAmbient() throws -> AmbientAudioAttachment {
            if let failWith { throw failWith }
            let (stream, c) = AsyncStream<AudioPipelineEvent>.makeStream(bufferingPolicy: .unbounded)
            lock.withLock { cont = c; attaches += 1 }
            return AmbientAudioAttachment(events: stream) { [weak self] in
                self?.lock.withLock { self?.detaches += 1; self?.cont?.finish(); self?.cont = nil }
            }
        }

        func send(_ e: AudioPipelineEvent) { _ = lock.withLock { cont }?.yield(e) }
        func end() { lock.withLock { cont }?.finish() }
    }

    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var _asr: [Int] = []
        private var _verdict: [Int] = []
        private var _heard: [AmbientHeard] = []
        var asr: [Int] { lock.withLock { _asr } }
        var verdictSamples: [Int] { lock.withLock { _verdict } }
        var heard: [AmbientHeard] { lock.withLock { _heard } }
        func noteASR(_ n: Int) { lock.withLock { _asr.append(n) } }
        func noteVerdict(_ n: Int) { lock.withLock { _verdict.append(n) } }
        func noteHeard(_ h: AmbientHeard) { lock.withLock { _heard.append(h) } }
    }

    static let block = 800   // 50 ms at 16 kHz

    /// `seconds` of audio blocks from `start`, value `level`.
    static func audio(_ capture: FakeCapture, from start: TimeInterval, seconds: TimeInterval, level: Float = 0.1) {
        let blocks = Int((seconds / 0.05).rounded())
        for i in 0..<blocks {
            capture.send(.audio(samples: [Float](repeating: level, count: block), position: start + Double(i) * 0.05))
        }
    }

    static func listener(_ capture: FakeCapture, calls: Calls, listens: @escaping () -> Bool = { true },
                         claimed: @escaping () -> Bool = { false },
                         verdict: SpeakerGate.Verdict = .user(similarity: 0.9),
                         text: String = "remember to call mum") -> AmbientListener {
        AmbientListener(audio: capture, listens: listens, claimed: claimed,
                        transcribe: { { samples in
                            calls.noteASR(samples.count)
                            return [TranscriptSpan(text: text, confidence: 0.9, audioRange: 0...1, provenance: [.asr])]
                        } },
                        verdict: { samples in calls.noteVerdict(samples.count); return verdict },
                        deliver: { calls.noteHeard($0) })
    }

    /// Waits until the listener's reader has consumed what was sent, then for the segment chain.
    static func drain(_ listener: AmbientListener, _ capture: FakeCapture) async {
        capture.end()
        for _ in 0..<200 where listener.isAttached { try? await Task.sleep(nanoseconds: 5_000_000) }
        await listener.settle()
    }

    // MARK: Segmenter

    @Test("segments open on speechStart with pre-roll and close on speechEnd")
    func segmenterCuts() {
        var s = AmbientSegmenter()
        _ = s.handle(.started(device: nil))
        var out: [AmbientSpeechSegment] = []
        for i in 0..<20 { out += s.handle(.audio(samples: [Float](repeating: 0, count: 800), position: Double(i) * 0.05)) }
        out += s.handle(.vad(.speechStart(at: 0.8)))
        #expect(s.isInSpeech)
        for i in 20..<40 { out += s.handle(.audio(samples: [Float](repeating: 0.2, count: 800), position: Double(i) * 0.05)) }
        out += s.handle(.vad(.speechEnd(at: 1.9)))
        #expect(out.count == 1)
        let seg = try! #require(out.first)
        #expect(abs(seg.start - 0.5) < 0.001, "pre-roll 0.3 s before the VAD edge")
        #expect(abs(seg.end - 2.0) < 0.001)
        #expect(!s.isInSpeech)
    }

    @Test("a click shorter than minSeconds is not a segment; capture stop flushes an open one")
    func segmenterBounds() {
        var s = AmbientSegmenter(config: .init(preRoll: 0, maxSeconds: 30, minSeconds: 0.4))
        _ = s.handle(.vad(.speechStart(at: 0)))
        for i in 0..<4 { _ = s.handle(.audio(samples: [Float](repeating: 0.2, count: 800), position: Double(i) * 0.05)) }
        #expect(s.handle(.vad(.speechEnd(at: 0.2))).isEmpty)
        _ = s.handle(.vad(.speechStart(at: 0.2)))
        for i in 4..<20 { _ = s.handle(.audio(samples: [Float](repeating: 0.2, count: 800), position: Double(i) * 0.05)) }
        #expect(s.handle(.stopped(totalSamples: 16_000)).count == 1)
    }

    @Test("speech longer than maxSeconds is cut into pieces without losing audio")
    func segmenterMax() {
        var s = AmbientSegmenter(config: .init(preRoll: 0, maxSeconds: 1, minSeconds: 0.1))
        _ = s.handle(.vad(.speechStart(at: 0)))
        var out: [AmbientSpeechSegment] = []
        for i in 0..<50 { out += s.handle(.audio(samples: [Float](repeating: 0.2, count: 800), position: Double(i) * 0.05)) }
        out += s.handle(.vad(.speechEnd(at: 2.5)))
        #expect(out.map(\.samples.count).reduce(0, +) == 50 * 800)
        #expect(out.count == 3)
        #expect(out[1].start == 1)
    }

    // MARK: Listener — L3 + L5

    @Test("silence only: attached, audio flows, and ASR / verdict never run (L5)")
    func silenceRunsNothing() async {
        let capture = FakeCapture(), calls = Calls()
        let l = Self.listener(capture, calls: calls)
        l.refresh()
        #expect(l.isAttached)
        Self.audio(capture, from: 0, seconds: 3)
        await Self.drain(l, capture)
        #expect(l.stats.audioBlocks == 60)
        #expect(calls.asr.isEmpty)
        #expect(calls.verdictSamples.isEmpty)
    }

    @Test("one speech segment → one ASR run and one verdict, both on the segment's samples")
    func oneSegment() async throws {
        let capture = FakeCapture(), calls = Calls()
        let l = Self.listener(capture, calls: calls)
        l.refresh()
        Self.audio(capture, from: 0, seconds: 1, level: 0)
        capture.send(.vad(.speechStart(at: 1.0)))
        Self.audio(capture, from: 1, seconds: 1.5)
        capture.send(.vad(.speechEnd(at: 2.5)))
        Self.audio(capture, from: 2.5, seconds: 1, level: 0)
        await Self.drain(l, capture)
        #expect(calls.asr.count == 1)
        #expect(calls.verdictSamples == calls.asr, "the verdict ran on the same samples ASR heard")
        #expect(try #require(calls.asr.first) >= Int(1.5 * 16_000))
        let heard = try #require(calls.heard.first)
        #expect(heard.text == "remember to call mum")
        #expect(heard.verdict == .user(similarity: 0.9))
        #expect(heard.duration >= 1.5)
    }

    @Test("speech an explicit claim owns (hold / latch / act key) is not transcribed or decided again")
    func claimedSkipped() async {
        let capture = FakeCapture(), calls = Calls()
        let claim = Flag(true)
        let l = Self.listener(capture, calls: calls, claimed: { claim.value })
        l.refresh()
        capture.send(.vad(.speechStart(at: 0)))
        Self.audio(capture, from: 0, seconds: 1)
        capture.send(.vad(.speechEnd(at: 1)))
        await Self.drain(l, capture)
        #expect(calls.asr.isEmpty)
        #expect(l.stats.claimedSegments == 1)
    }

    @Test("mode Off detaches; an unavailable microphone leaves it detached and quiet")
    func followsMode() async {
        let capture = FakeCapture(), calls = Calls()
        let on = Flag(true)
        let l = Self.listener(capture, calls: calls, listens: { on.value })
        l.refresh(); l.refresh()
        #expect(capture.attaches == 1, "refresh is idempotent")
        on.value = false
        l.refresh()
        #expect(!l.isAttached)
        #expect(capture.detaches == 1)
        on.value = true
        capture.failWith = AmbientAttachError.muted
        l.refresh()
        #expect(!l.isAttached)
        capture.failWith = nil
        l.refresh()
        #expect(l.isAttached)
        #expect(capture.attaches == 2)
    }

    @Test("no recognizer yet → segments are dropped, never faked")
    func noModel() async {
        let capture = FakeCapture()
        let l = AmbientListener(audio: capture, listens: { true }, transcribe: { nil },
                                verdict: { _ in .user(similarity: 1) }, deliver: { _ in Issue.record("delivered without ASR") })
        l.refresh()
        capture.send(.vad(.speechStart(at: 0)))
        Self.audio(capture, from: 0, seconds: 1)
        capture.send(.vad(.speechEnd(at: 1)))
        await Self.drain(l, capture)
        #expect(l.stats.segments == 1)
        #expect(l.stats.transcriptions == 0)
    }

    // MARK: X13 — end to end through the gate and the decision pipeline

    final class Embedder: SpeakerEmbedder, @unchecked Sendable {
        let name = "fake-identifying"
        let dimension = 2
        var identifiesSpeakers: Bool { true }
        /// Level 0.1 audio is "the user", anything else another voice.
        func embed(_ samples: [Float]) throws -> SpeakerEmbedding {
            let user = (samples.max() ?? 0) <= 0.1
            return SpeakerEmbedding(vector: user ? [1, 0] : [0, 1], embedder: name)
        }
    }

    static func enrolledFilter() -> SpeakerFilter {
        let profile = SpeakerProfile(centroid: SpeakerEmbedding(vector: [1, 0], embedder: "fake-identifying"),
                                     utteranceCount: 5, enrolledAt: Date())
        return SpeakerFilter(isOn: true, gate: SpeakerGate(profile: profile), canIdentify: true)
    }

    @Test("X13: the enrolled user's ambient speech is kept and noted; another voice is discarded")
    func x13Fixed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("l3-\(UUID().uuidString)")
        let store = AmbientTranscriptStore(meetings: MeetingStore(root: root), database: try AppDatabase.inMemory(),
                                          retention: { AmbientRetentionPolicy(days: 7) })
        let rig = AmbientGuaranteesTests.Rig(mode: .listenAndNote, verdict: .unknown)
        let filter = Self.enrolledFilter()
        let gate = AmbientCaptureGate(isEnabled: true, capturesEverySpeaker: false, filter: filter)
        let embedder = Embedder()
        let capture = FakeCapture()
        let decisions = DecisionsSeen()
        let l = AmbientWiring.listener(audio: capture, sink: store, gate: { gate },
                                       transcribe: { { samples in
                                           [TranscriptSpan(text: (samples.max() ?? 0) <= 0.1 ? "buy oat milk" : "pass the salt",
                                                           confidence: 0.9, audioRange: 0...1, provenance: [.asr])]
                                       } },
                                       verdict: AmbientWiring.verdict(filter: { filter }, embedder: { embedder }),
                                       decisions: rig.pipeline, onDecision: { decisions.add($0) })
        l.refresh()
        capture.send(.vad(.speechStart(at: 0)))
        Self.audio(capture, from: 0, seconds: 1, level: 0.1)     // the user
        capture.send(.vad(.speechEnd(at: 1)))
        capture.send(.vad(.speechStart(at: 2)))
        Self.audio(capture, from: 1, seconds: 2, level: 0.5)     // someone else
        capture.send(.vad(.speechEnd(at: 3)))
        await Self.drain(l, capture)
        await rig.pipeline.settle()
        #expect(decisions.all.map(\.discardReason) == [nil, .anotherVoice])
        #expect(store.entries().map(\.text) == ["buy oat milk"])
        #expect(rig.notes.texts == ["buy oat milk"], "the verdict travelled with the utterance (pipeline fallback was .unknown)")
        #expect(rig.delivery.got.isEmpty)
    }

    @Test("verdict: no profile or a non-identifying embedder → .unknown without embedding")
    func verdictHonest() {
        let embedder = Embedder()
        let none = AmbientWiring.verdict(filter: { SpeakerFilter(isOn: true, gate: SpeakerGate(profile: nil), canIdentify: true) },
                                         embedder: { embedder })
        #expect(none([0.1]) == .unknown)
        let mfcc = AmbientWiring.verdict(filter: {
            var f = Self.enrolledFilter(); f.canIdentify = false; return f
        }, embedder: { embedder })
        #expect(mfcc([0.1]) == .unknown)
        let real = AmbientWiring.verdict(filter: { Self.enrolledFilter() }, embedder: { embedder })
        #expect(real([0.1]).isUser)
        #expect(!real([0.5]).isUser)
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var v: Bool
        init(_ v: Bool) { self.v = v }
        var value: Bool { get { lock.withLock { v } } set { lock.withLock { v = newValue } } }
    }

    final class DecisionsSeen: @unchecked Sendable {
        private let lock = NSLock()
        private var _all: [AmbientCaptureDecision] = []
        var all: [AmbientCaptureDecision] { lock.withLock { _all } }
        func add(_ d: AmbientCaptureDecision) { lock.withLock { _all.append(d) } }
    }
}
