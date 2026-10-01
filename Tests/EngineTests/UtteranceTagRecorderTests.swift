import Engine
import Foundation
import Shared
import Testing

/// V5 O2 — recorders vs capabilities: a capability's claim on an utterance is rendered by the meeting
/// recorder on the span it already holds, once, tagged.
@Suite("V5 O2 — utterance tags on recorders")
struct UtteranceTagRecorderTests {
    /// The mic leg says what the user dictated; the system leg is the other party.
    struct FakeASR: MeetingTranscriber {
        func transcribe(_ chunk: AudioChunk) async throws -> [TranscriptSpan] {
            let level = chunk.samples.first ?? 0
            let text = level > 0.5 ? "please send the report by friday" : level > 0 ? "sounds good to me" : "great thanks"
            return [TranscriptSpan(text: text, confidence: 0.9, audioRange: 0...chunk.duration)]
        }
    }

    final class Rig {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vp-o2-\(UUID().uuidString)")
        let store: MeetingStore
        let session: MeetingSession
        init() {
            store = MeetingStore(root: root)
            session = MeetingSession(title: "Standup", transcriber: FakeASR(), labeler: ChannelLabeler(), store: store)
        }
        deinit { try? FileManager.default.removeItem(at: root) }

        func chunk(_ ch: MeetingChannel, _ level: Float, _ t: TimeInterval, _ d: TimeInterval = 3) -> MeetingChunk {
            MeetingChunk(channel: ch, chunk: AudioChunk(samples: [Float](repeating: level, count: Int(16_000 * d)),
                                                        range: t...(t + d), reason: .speechEnd))
        }

        func tag(_ owner: UtteranceOwner, _ from: TimeInterval, _ to: TimeInterval, id: String = UUID().uuidString) async -> UtteranceTag {
            let origin = await session.record.startedAt
            return UtteranceTag(utteranceID: id, owner: owner,
                                range: origin.addingTimeInterval(from)...origin.addingTimeInterval(to))
        }
    }

    @Test("a dictation during a meeting appears once, tagged, in the meeting transcript (tag first)")
    func dictationDuringMeetingTagFirst() async throws {
        let rig = Rig()
        // The user speaks to the meeting, then holds the key and dictates (10–13 s), then the others reply.
        await rig.session.tag(await rig.tag(.dictate, 10, 13))
        try await rig.session.ingest([rig.chunk(.mic, 0.1, 0), rig.chunk(.mic, 0.9, 10), rig.chunk(.system, -0.1, 14)])
        let rec = try await rig.session.finish(at: Date())
        let dictated = rec.transcript.utterances.filter { $0.text.contains("send the report") }
        #expect(dictated.count == 1)
        #expect(dictated.first?.tag == .dictate)
        #expect(dictated.first?.tagLabel == "dictated")
        #expect(rec.transcript.utterances.map(\.tag) == [nil, .dictate, nil])
        let transcriptMD = rec.markdown.components(separatedBy: "## Transcript").last ?? ""
        #expect(transcriptMD.components(separatedBy: "send the report").count == 2)        // once
        #expect(rec.markdown.contains("**You** [00:10] _(dictated)_ please send the report by friday"))
        #expect(try rig.store.load(id: rec.id).transcript.utterances[1].tag == .dictate)    // persisted
    }

    @Test("a tag that settles after the span was transcribed labels it in place")
    func dictationDuringMeetingTagAfter() async throws {
        let rig = Rig()
        try await rig.session.ingest([rig.chunk(.mic, 0.9, 20), rig.chunk(.system, -0.1, 24)])
        await rig.session.tag(await rig.tag(.note, 20.2, 22.8))
        let rec = await rig.session.record
        #expect(rec.transcript.utterances.map(\.tag) == [.note, nil])
        #expect(rec.markdown.contains("_(note)_ please send"))
    }

    @Test("a claimed span never merges into the user's adjacent conversation")
    func taggedSpanDoesNotMerge() async throws {
        let rig = Rig()
        await rig.session.tag(await rig.tag(.act, 3.5, 6.5))
        try await rig.session.ingest([rig.chunk(.mic, 0.1, 0), rig.chunk(.mic, 0.9, 3.5)])
        let us = await rig.session.record.transcript.utterances
        #expect(us.count == 2)
        #expect(us.map(\.tag) == [nil, .act])
        #expect(us[1].tagLabel == "command")
    }

    @Test("only the user's own voice can be claimed; ignore labels nothing; a span keeps its first owner")
    func claimRules() {
        let origin = Date(timeIntervalSince1970: 1_800_000_000)
        var t = MeetingTranscript(utterances: [
            MeetingUtterance(speaker: .others(1), text: "a", range: 0...3, confidence: 1),
            MeetingUtterance(speaker: .you, text: "b", range: 0...3, confidence: 1),
            MeetingUtterance(speaker: .you, text: "c", range: 10...20, confidence: 1),
        ])
        let tag = { (o: UtteranceOwner, a: TimeInterval, b: TimeInterval) in
            UtteranceTag(utteranceID: "u", owner: o, range: origin.addingTimeInterval(a)...origin.addingTimeInterval(b))
        }
        #expect(t.apply(tag(.ignore, 0, 3), origin: origin) == 0)
        #expect(t.apply(tag(.dictate, 0, 3), origin: origin) == 1)
        #expect(t.utterances.map(\.tag) == [nil, .dictate, nil])
        #expect(t.apply(tag(.note, 0, 3), origin: origin) == 0)          // one owner per span
        #expect(t.apply(tag(.ask, 10, 13), origin: origin) == 0)         // covers < half of a 10 s span
        #expect(t.apply(tag(.ask, 9.8, 17), origin: origin) == 1)
        #expect(UtteranceOwner.allCases.compactMap(\.recorderLabel) == ["dictated", "command", "command", "note", "asked"])
    }

    @Test("records written before O2 still decode; untagged spans encode no tag key")
    func codableBackCompat() throws {
        let old = #"{"speaker":{"you":{}},"text":"hi","range":[0,1],"confidence":1}"#
        let u = try JSONDecoder().decode(MeetingUtterance.self, from: Data(old.utf8))
        #expect(u.tag == nil && u.text == "hi")
        let enc = String(decoding: try JSONEncoder().encode(u), as: UTF8.self)
        #expect(!enc.contains("tag"))
        var tagged = u; tagged.tag = .dictate
        #expect(try JSONDecoder().decode(MeetingUtterance.self, from: JSONEncoder().encode(tagged)).tag == .dictate)
    }
}
