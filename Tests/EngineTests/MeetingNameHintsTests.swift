import Foundation
import Shared
import Testing
@testable import Engine

/// V5 M11 — name hints: each source on synthetic input (calendar, active-speaker samples
/// time-correlated with the transcript, addressed / introduced names, lips), fusion, and the
/// end-to-end path into the M13 descriptors as suggestions only. No EventKit, AX, camera or GLiNER2
/// here — those are protocol fakes; the live readers need a real call (T1).
@Suite("V5 M11 — speaker name hints")
struct MeetingNameHintsTests {
    static func u(_ s: MeetingSpeaker, _ text: String, _ lo: Double, _ hi: Double) -> MeetingUtterance {
        MeetingUtterance(speaker: s, text: text, range: lo...hi, confidence: 1)
    }
    static let origin = Date(timeIntervalSince1970: 1_790_000_000)
    static let transcript = MeetingTranscript(utterances: [
        u(.you, "Hi everyone. Thanks, Priya, can you start with the numbers?", 0, 4),
        u(.others(1), "Sure. Revenue is up eleven percent this quarter", 4, 12),
        u(.others(2), "I'm Rahul from finance, quick question on that", 12, 16),
        u(.others(1), "Go ahead", 16, 17),
        u(.you, "Rahul, what do you need?", 17, 19),
        u(.others(2), "The breakdown by region please", 19, 24),
    ])

    struct Attendees: MeetingAttendeeSource { let names: [String]; func attendees(of event: CalendarMeeting) -> [String] { names } }
    struct NoSpeaker: ActiveSpeakerSource { func activeSpeaker() -> ActiveSpeakerReading? { nil } }
    struct Lips: MeetingLipSource {
        let userTalking: ClosedRange<Double>
        func lipActivity(from: Date, to: Date) -> LipActivity? {
            let mid = (from.timeIntervalSince(MeetingNameHintsTests.origin) + to.timeIntervalSince(MeetingNameHintsTests.origin)) / 2
            return userTalking.contains(mid) ? LipActivity(correlation: 0.8, mouthMotion: 1, faceCoverage: 1, verdict: .userSpeaking)
                                             : LipActivity(correlation: 0, mouthMotion: 0, faceCoverage: 1, verdict: .notUser)
        }
    }

    @Test("addressed and introduced names; the speaker after 'Thanks, Priya' is Priya, 'I'm Rahul' names Rahul")
    func addressed() async {
        let out = await MeetingNameHints.addressed(Self.transcript, vocabulary: ["Priya Sharma", "Rahul Mehta"], typer: nil)
        #expect(out[.others(1)]?.contains { $0.name == "Priya" && $0.source == "addressed" } == true)
        #expect(out[.others(2)]?.contains { $0.name == "Rahul" && $0.source == "introduced" } == true)
        #expect(out[.others(2)]?.contains { $0.name == "Rahul" && $0.source == "addressed" } == true)
        #expect(out[.you] == nil)
        // Unknown capitalised words are not names unless the typer says person.
        let unknown = await MeetingNameHints.addressed(Self.transcript, vocabulary: [], typer: nil)
        #expect(unknown.isEmpty)
        let typed = await MeetingNameHints.addressed(Self.transcript, vocabulary: [], typer: HeuristicEntityTyper(people: ["priya"]))
        #expect(typed[.others(1)]?.first?.name == "Priya")
        #expect(MeetingNameHints.mentions("Okay, so this is fine").isEmpty)
        #expect(MeetingNameHints.mentions("thank you Asha").map(\.0) == ["Asha"])
        #expect(MeetingNameHints.mentions("what do you think, Meera?").map(\.0) == ["Meera"])
        #expect(MeetingNameHints.mentions("This is Kiran speaking").first! == ("Kiran", true))
    }

    @Test("active-speaker samples are time-correlated with the transcript's speakers")
    func activeSpeaker() {
        var samples: [ActiveSpeakerTimeline.Sample] = []
        for t in stride(from: 4.0, through: 12, by: 1) { samples.append(.init(at: Self.origin.addingTimeInterval(t), reading: .init(name: "Priya Sharma", app: "Zoom"))) }
        for t in stride(from: 19.0, through: 24, by: 1) { samples.append(.init(at: Self.origin.addingTimeInterval(t), reading: .init(name: "Rahul Mehta", app: "Zoom"))) }
        samples.append(.init(at: Self.origin.addingTimeInterval(13), reading: .init(name: "Priya Sharma", app: "Zoom")))   // lag noise
        let out = MeetingNameHints.activeSpeaker(Self.transcript, samples: samples, origin: Self.origin)
        #expect(out[.others(1)]?.first?.name == "Priya Sharma" && (out[.others(1)]?.first?.confidence ?? 0) > 0.8)
        #expect(out[.others(2)]?.first?.name == "Rahul Mehta")
        #expect(out[.others(2)]?.contains { $0.name == "Priya Sharma" } != true, "one stray sample is not enough")
        let tl = ActiveSpeakerTimeline(source: NoSpeaker())
        tl.record(nil); tl.record(.init(name: "A", app: "Meet"))
        #expect(tl.all.count == 1)
    }

    @Test("calendar 1:1, lips → You, fusion: noisy-OR, invitee boost, one speaker per name, top 3")
    func calendarLipsFusion() {
        let oneOnOne = MeetingTranscript(utterances: [Self.u(.you, "hello", 0, 1), Self.u(.others(1), "hi there", 1, 2)])
        #expect(MeetingNameHints.calendar(oneOnOne, attendees: ["Asha Rao"])[.others(1)]?.first?.name == "Asha Rao")
        #expect(MeetingNameHints.calendar(Self.transcript, attendees: ["Asha Rao"]).isEmpty, "two other speakers: not a 1:1")

        let lips = MeetingNameHints.lips(Self.transcript, origin: Self.origin, source: Lips(userTalking: 12...24))
        #expect(lips[.others(2)]?.first?.name == "You", "user's lips move while 'Others 2' talks: a mislabelled user")
        #expect(lips[.others(1)] == nil)

        let fused = MeetingNameHints.fuse([
            [.others(1): [SpeakerNameCandidate(name: "Priya", confidence: 0.35, source: "addressed")]],
            [.others(1): [SpeakerNameCandidate(name: "Priya", confidence: 0.35, source: "addressed")],
             .others(2): [SpeakerNameCandidate(name: "Priya", confidence: 0.2, source: "addressed"),
                          SpeakerNameCandidate(name: "Rahul", confidence: 0.6, source: "introduced")]],
        ], attendees: ["Priya Sharma"])
        let p = try? #require(fused[.others(1)]?.first)
        #expect(p?.name == "Priya" && abs((p?.confidence ?? 0) - min(0.95, (1 - 0.65 * 0.65) * 1.2)) < 0.001)
        #expect(fused[.others(2)]?.map(\.name) == ["Rahul"], "Priya fits Others 1 better")
    }

    @Test("end to end: hints reach the descriptors as 'maybe …', never the names file; call app fills 'on the call (…)'")
    func endToEnd() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("m11-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let hints = MeetingNameHints(attendees: Attendees(names: ["Priya Sharma", "Rahul Mehta"]), activeSpeaker: NoSpeaker())
        hints.timeline?.record(.init(name: "Priya Sharma", app: "Zoom"), at: Self.origin.addingTimeInterval(5))
        let labeler = DescribingLabeler(inner: ChannelLabeler(), library: { nil }, hints: hints,
                                        context: { r in SpeakerDescriptionContext(startedAt: r.startedAt, timeZone: TimeZone(identifier: "UTC")!) })
        let sys = MeetingChunk(channel: .system, chunk: AudioChunk(samples: [Float](repeating: 0.1, count: 16_000 * 8), range: 4...12, reason: .speechEnd))
        _ = try await labeler.label([sys])
        var record = MeetingRecord(id: "m", title: "Numbers", startedAt: Self.origin,
                                   event: CalendarMeeting(id: "e", title: "Numbers", start: Self.origin, end: Self.origin.addingTimeInterval(1800)))
        record.transcript = Self.transcript
        _ = await labeler.finalTranscript(for: record, recordingIn: store.directory(for: "m"))
        let d = MeetingSpeakerDescriptors.load(from: store.directory(for: "m"))
        let priya = try #require(d.descriptor(for: .others(1)))
        #expect(priya.attribute(.candidateName)?.text == "maybe Priya")
        #expect(priya.label.hasPrefix("Maybe Priya"))
        #expect(priya.attribute(.location)?.text == "on the call (Zoom)")
        #expect(d.descriptor(for: .others(2))?.attribute(.candidateName)?.text == "maybe Rahul")
        #expect(FileMeetingSpeakerNames(store: store).savedNames(for: "m").isEmpty, "always suggestions")
    }

    @Test("active-speaker label parsing (Zoom / Teams / Meet wordings)")
    func parsing() {
        #expect(ActiveSpeakerParsing.name(in: ["Mute", "Priya Sharma, Active speaker"]) == "Priya Sharma")
        #expect(ActiveSpeakerParsing.name(in: ["Rahul Mehta is speaking"]) == "Rahul Mehta")
        #expect(ActiveSpeakerParsing.name(in: ["Active speaker: Asha"]) == "Asha")
        #expect(ActiveSpeakerParsing.name(in: ["Kiran (speaking)"]) == "Kiran")
        #expect(ActiveSpeakerParsing.name(in: ["You are speaking", "Share screen", "Speaking: You"]) == nil)
        #expect(ActiveSpeakerParsing.name(in: ["Participants (4)", "Chat"]) == nil)
    }

    @Test("lazy GLiNER2 typer: loads once, heuristic answers when the weights are absent")
    func lazyTyper() async {
        let counter = Counter()
        let t = LazyPersonTyper(people: ["meera"], load: { await counter.bump(); return nil })
        await t.prepare(["Meera"], context: "thanks Meera")
        await t.prepare(["Meera"], context: "thanks Meera")
        #expect(await counter.n == 1)
        #expect(t.cachedType(for: "Meera") == .person)
    }
    actor Counter { var n = 0; func bump() { n += 1 } }
}
