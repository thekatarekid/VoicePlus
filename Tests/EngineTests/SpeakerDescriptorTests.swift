import Foundation
import Shared
import Testing
@testable import Engine

/// V5 M13 — descriptive speaker labels: acoustic measurements on synthetic audio, descriptors on
/// synthetic features, uniqueness within a meeting, the gender switch, and the finish-time pass
/// (M10 voices + library suggestions + M11 hints) writing the files the transcript reads.
@Suite("V5 M13 — descriptive speaker labels")
struct SpeakerDescriptorTests {
    static let sr = 16_000

    /// A voiced "syllable train": `hz` harmonic tone gated on/off at 4 Hz, peak `amp`.
    static func voice(hz: Double, amp: Float, seconds: Double = 3, reverb: Float = 0) -> [Float] {
        let n = Int(seconds * Double(sr))
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / Double(sr)
            let gate: Float = (Int(t * 8) % 2 == 0) ? 1 : 0
            let tone = sin(2 * .pi * hz * t) + 0.5 * sin(4 * .pi * hz * t) + 0.25 * sin(6 * .pi * hz * t)
            out[i] = amp * gate * Float(tone) / 1.75
        }
        guard reverb > 0 else { return out }
        // Crude room: a decaying (~250 ms) smear fills the gaps between syllables.
        var tail: Float = 0
        let decay = Float(exp(-1.0 / (0.25 * Double(sr))))
        var wet = out
        for i in 0..<n {
            tail = tail * decay + abs(out[i]) * (1 - decay) * 6
            wet[i] = out[i] + reverb * tail * Float(sin(Double(i) * 1.3))
        }
        return wet
    }

    @Test("acoustics: F0 within 5 %, level follows amplitude, reverberation lowers the envelope depth")
    func acoustics() {
        let low = SpeakerAcoustics.medianF0(Self.voice(hz: 110, amp: 0.3))
        let high = SpeakerAcoustics.medianF0(Self.voice(hz: 230, amp: 0.3))
        #expect(abs((low.0 ?? 0) - 110) < 5.5 && low.1 >= 3)
        #expect(abs((high.0 ?? 0) - 230) < 11.5)
        let (loud, dryDyn) = SpeakerAcoustics.levelAndDynamics(Self.voice(hz: 150, amp: 0.5))
        let (quiet, _) = SpeakerAcoustics.levelAndDynamics(Self.voice(hz: 150, amp: 0.05))
        let (_, wetDyn) = SpeakerAcoustics.levelAndDynamics(Self.voice(hz: 150, amp: 0.5, reverb: 0.6))
        #expect((loud ?? -99) - (quiet ?? 0) > 18)
        #expect((dryDyn ?? 0) - (wetDyn ?? 99) > 10, "dry \(dryDyn ?? 0) vs reverberant \(wetDyn ?? 0)")
        #expect(SpeakerAcoustics.levelAndDynamics([Float](repeating: 0, count: 16_000)).0 == nil)
        #expect(SpeakerAcoustics.medianF0([Float](repeating: 0, count: 16_000)).0 == nil)
        let m = SpeakerAcoustics.measure(Self.voice(hz: 110, amp: 0.3), start: 5, channel: .system)
        #expect(m.start == 5 && abs(m.end - 8) < 0.001 && m.channel == .system)
    }

    static func u(_ s: MeetingSpeaker, _ text: String, _ lo: Double, _ hi: Double) -> MeetingUtterance {
        MeetingUtterance(speaker: s, text: text, range: lo...hi, confidence: 1)
    }
    static func c(_ lo: Double, _ hi: Double, _ ch: MeetingChannel, level: Float, dyn: Float, f0: Float?) -> ChunkAcoustics {
        ChunkAcoustics(start: lo, end: hi, channel: ch, levelDB: level, dynamicsDB: dyn, f0Hz: f0, voicedFrames: f0 == nil ? 0 : 20)
    }

    /// A four-person hybrid meeting: You at the laptop, a deep voice on the call, a high voice
    /// across the room, a high voice near the laptop.
    static func meeting() -> (MeetingTranscript, [ChunkAcoustics]) {
        let t = MeetingTranscript(utterances: [
            u(.you, "Okay let's start with the launch plan for October", 0, 4),
            u(.others(1), "Thanks. The launch plan is mostly ready from our side", 4, 9),
            u(.others(2), "What about the pricing page? Is it final?", 9, 13),
            u(.others(3), "Design signed off on the pricing page yesterday afternoon", 13, 18),
            u(.others(1), "Great, then we ship on the twelfth as discussed", 18, 22),
        ])
        let chunks = [c(0, 4, .mic, level: -20, dyn: 30, f0: 120),
                      c(4, 9, .system, level: -24, dyn: 28, f0: 105), c(18, 22, .system, level: -24, dyn: 28, f0: 108),
                      c(9, 13, .mic, level: -38, dyn: 12, f0: 215),
                      c(13, 18, .mic, level: -22, dyn: 29, f0: 210)]
        return (t, chunks)
    }

    static let start = Date(timeIntervalSince1970: 1_790_000_000)   // a fixed instant; UTC formatting below
    static func ctx(gender: Bool = true, candidates: [MeetingSpeaker: [SpeakerNameCandidate]] = [:]) -> SpeakerDescriptionContext {
        SpeakerDescriptionContext(title: "Launch sync", app: "Zoom", startedAt: start, perceivedGender: gender,
                                  candidates: candidates, timeZone: TimeZone(identifier: "UTC")!)
    }

    @Test("descriptors: where, pitch, gender, role, questions, quote; labels distinguish, You stays You")
    func descriptors() throws {
        let (t, chunks) = Self.meeting()
        let d = SpeakerDescriptorBuilder.describe(t, chunks: chunks, context: Self.ctx())
        let call = try #require(d.descriptor(for: .others(1)))
        let far = try #require(d.descriptor(for: .others(2)))
        let near = try #require(d.descriptor(for: .others(3)))
        #expect(call.attribute(.location)?.text == "on the call (Zoom)")
        #expect(call.attribute(.pitch)?.text == "Deep voice" && call.attribute(.gender)?.text == "probably man")
        #expect(far.attribute(.location)?.text == "across the room")
        #expect(far.attribute(.pitch)?.text == "Higher voice" && far.attribute(.gender)?.text == "probably woman")
        #expect(far.attribute(.questions)?.text == "asked the most questions")
        #expect(far.attribute(.loudness)?.text == "Soft voice")
        #expect(near.attribute(.location)?.text == "near the laptop")
        #expect(near.attribute(.quote)?.text.hasPrefix("“Design signed off") == true)
        #expect(call.attribute(.timeSpan) != nil && call.firstHeard == 4 && call.lastHeard == 22)
        #expect(d.descriptor(for: .you)?.attribute(.role)?.text == "spoke first")
        #expect(d.descriptor(for: .you)?.label == "You")
        // Labels: 2–3 attributes, unique within the meeting.
        let labels = [call, far, near].map(\.label)
        #expect(Set(labels).count == 3, "\(labels)")
        for l in labels { #expect((2...3).contains(l.components(separatedBy: " · ").count), "\(l)") }
        #expect(call.label.contains("on the call"))
        #expect(far.label.contains("across the room") || far.label.contains("Soft voice"))
        #expect(near.label.contains("near the laptop"))
        #expect(d.labels["You"] == nil && d.labels.count == 3)
    }

    @Test("uniqueness: identical voices still get different labels; gender off removes the guess; candidate name leads")
    func uniquenessGenderAndCandidates() throws {
        let t = MeetingTranscript(utterances: [Self.u(.others(1), "first person talks about the roadmap today", 0, 5),
                                               Self.u(.others(2), "second person talks about the roadmap too", 600, 605)])
        let chunks = [Self.c(0, 5, .system, level: -24, dyn: 28, f0: 120), Self.c(600, 605, .system, level: -24, dyn: 28, f0: 120)]
        let d = SpeakerDescriptorBuilder.describe(t, chunks: chunks, context: Self.ctx(gender: false))
        let a = try #require(d.descriptor(for: .others(1))), b = try #require(d.descriptor(for: .others(2)))
        #expect(a.label != b.label, "\(a.label) / \(b.label)")
        #expect(a.attribute(.gender) == nil && b.attribute(.gender) == nil)

        let named = SpeakerDescriptorBuilder.describe(t, chunks: chunks, context: Self.ctx(candidates: [
            .others(2): [SpeakerNameCandidate(name: "Priya", confidence: 0.4, source: "calendar"),
                         SpeakerNameCandidate(name: "Asha", confidence: 0.2, source: "addressed")]]))
        let p = try #require(named.descriptor(for: .others(2)))
        #expect(p.label.hasPrefix("Maybe Priya"))
        #expect(p.candidates.count == 2)
        #expect(SpeakerDescriptorBuilder.perceivedGenderEnabled(UserDefaults(suiteName: "m13-\(UUID().uuidString)")!), "on by default")
    }

    @Test("language and quote helpers")
    func helpers() {
        #expect(SpeakerDescriptorBuilder.language(["मैं कल ऑफिस आऊँगा and then we can discuss the plan with everyone"]) == "speaks Hindi-English")
        #expect(SpeakerDescriptorBuilder.language(["we should ship the launch plan on the twelfth of October"]) == nil)
        #expect(SpeakerDescriptorBuilder.quote(["yeah okay", "Design signed off on the pricing page yesterday afternoon at five"])
                == "Design signed off on the pricing page yesterday…")
        #expect(SpeakerDescriptorBuilder.questionCount("Is it final?") == 1)
        #expect(SpeakerDescriptorBuilder.questionCount("what do we do next then") == 1)
        #expect(SpeakerDescriptorBuilder.questionCount("we do it next") == 0)
    }

    // MARK: finish-time pass

    final class VoiceEmbedding: SpeakerEmbeddingBackend, @unchecked Sendable {
        func embedding(for samples: [Float]) throws -> [Float] {
            let f = SpeakerAcoustics.medianF0(samples).0 ?? 0
            return f < 160 ? [1, 0.05, 0] : [0.05, 1, 0]
        }
    }

    struct FixedHints: SpeakerNameHinting {
        let out: [MeetingSpeaker: [SpeakerNameCandidate]]
        func candidates(for record: MeetingRecord, directory: URL) async -> [MeetingSpeaker: [SpeakerNameCandidate]] { out }
    }

    @Test("finish: voices, library suggestion, hints and labels written; transcript names show labels, real names win")
    func finishPass() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("m13-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try VoiceprintStore(url: root.appendingPathComponent("lib.sqlite"))
        let ravi = try library.person(named: "Ravi")
        try library.map(SpeakerEmbedding(vector: [1, 1.1, 0], embedder: "fluid-wespeaker"), to: ravi.id)   // cos 0.71 to voice A: suggested
        let store = MeetingStore(root: root.appendingPathComponent("Meetings"))
        let labeler = DescribingLabeler(inner: ChannelLabeler(), voices: VoiceEmbedding(), library: { library },
                                        hints: FixedHints(out: [.others(1): [SpeakerNameCandidate(name: "Priya", confidence: 0.3, source: "calendar")]]),
                                        context: { r in SpeakerDescriptionContext(title: r.title, startedAt: r.startedAt,
                                                                                    timeZone: TimeZone(identifier: "UTC")!) })
        #expect(labeler.name == "channel")
        let mic = MeetingChunk(channel: .mic, chunk: AudioChunk(samples: Self.voice(hz: 230, amp: 0.4), range: 0...3, reason: .speechEnd))
        let sys = MeetingChunk(channel: .system, chunk: AudioChunk(samples: Self.voice(hz: 110, amp: 0.4), range: 3...6, reason: .speechEnd))
        let labelled = try await labeler.label([mic, sys])
        #expect(labelled.map(\.speaker) == [.you, .others(1)], "labels pass through unchanged")
        #expect(labeler.measuredChunks.count == 2)

        var record = MeetingRecord(id: "m", title: "Sync", startedAt: Self.start)
        record.transcript = MeetingTranscript(utterances: [Self.u(.you, "hello there everyone welcome", 0, 3),
                                                           Self.u(.others(1), "thanks for having me on the call today", 3, 6)])
        let dir = store.directory(for: "m")
        #expect(await labeler.finalTranscript(for: record, recordingIn: dir) == nil, "the transcript itself is untouched")
        let voices = MeetingSpeakerVoices.load(from: dir)
        #expect(voices.entry(for: .others(1))?.embedding.embedder == "fluid-wespeaker" && voices.entry(for: .others(1))?.seconds == 3)
        let d = try #require(MeetingSpeakerDescriptors.load(from: dir).descriptor(for: .others(1)))
        #expect(Set(d.candidates.map(\.source)) == ["voiceprint", "calendar"], "\(d.candidates)")
        #expect(d.attribute(.location)?.text == "on the call")
        #expect(d.attribute(.pitch)?.text == "Deep voice")
        let names = FileMeetingSpeakerNames(store: store)
        #expect(names.names(for: "m").name(for: .others(1)) == d.label)
        #expect(names.savedNames(for: "m").isEmpty, "a label is never saved as a name")
        #expect(names.names(for: "m").name(for: .you) == "You")
        try MeetingVoiceMapping(library: library, names: names).map(.others(1), to: "Ravi", meetingID: "m")
        #expect(names.names(for: "m").name(for: .others(1)) == "Ravi")
        #expect(library.voiceprints(embedder: "fluid-wespeaker").first?.sampleCount == 2)
    }

    @Test("factory: describe wraps the labeler (name kept, final pass forwarded); without it, unchanged")
    func factoryWraps() {
        let plain = DiarizationFactory.make(enrolledUserEmbedding: nil, locate: { nil }, sortformer: { nil })
        #expect(plain is ChannelLabeler)
        let wrapped = DiarizationFactory.make(enrolledUserEmbedding: nil, locate: { nil }, sortformer: { nil },
                                              describe: .init(library: { nil }))
        #expect(wrapped.name == "channel" && (wrapped as? DescribingLabeler)?.inner is ChannelLabeler)
        #expect(wrapped is any FinalSpeakerRelabeling)
    }
}
