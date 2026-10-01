import Foundation
import Shared
import Testing
@testable import Engine

/// V5 M10 — the voiceprint library: SQLite round trip, auto-match bands, quality-weighted mean,
/// per-embedder isolation, one person per meeting speaker, local-only by default.
@Suite("V5 M10 — voiceprint library")
struct VoiceprintStoreTests {
    static func store() throws -> (VoiceprintStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("m10-\(UUID().uuidString)", isDirectory: true)
        return (try VoiceprintStore(url: dir.appendingPathComponent("v.sqlite")), dir)
    }

    /// A unit vector at `degrees` from the x axis in the x/y plane (cosine to x = cos(degrees)).
    static func at(_ degrees: Double, embedder: String = "fluid-wespeaker") -> SpeakerEmbedding {
        let r = degrees * .pi / 180
        return SpeakerEmbedding(vector: [Float(cos(r)), Float(sin(r)), 0, 0], embedder: embedder)
    }

    @Test("mapping saves a centroid; ≥ 0.75 applied, 0.6–0.75 suggested, else new")
    func bands() throws {
        let (store, dir) = try Self.store(); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(store.match(Self.at(0)) == .new)
        let priya = try store.person(named: "Priya")
        try store.map(Self.at(0), to: priya.id)
        guard case .applied(let p, let s) = store.match(Self.at(30)) else { Issue.record("cos 30° = 0.87 → applied"); return }
        #expect(p == priya && abs(s - 0.866) < 0.01)
        guard case .suggested(let q, _) = store.match(Self.at(50)) else { Issue.record("cos 50° = 0.64 → suggested"); return }
        #expect(q == priya)
        #expect(store.match(Self.at(60)) == .new)   // cos 60° = 0.5
        #expect(store.match(Self.at(0, embedder: "fluid-campplus")) == .new, "other model's space is never compared")
        #expect(VoiceprintMatch.new.person == nil)
    }

    @Test("persists across opens; running mean weighted; sample count and last seen")
    func persistsAndAverages() throws {
        let (store, dir) = try Self.store(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = try store.person(named: "Rahul")
        #expect(try store.person(named: " rahul ") == p, "case-insensitive, one person per name")
        try store.map(Self.at(0), weight: 1, to: p.id, at: Date(timeIntervalSince1970: 100))
        let v = try store.map(Self.at(90), weight: 1, to: p.id, at: Date(timeIntervalSince1970: 200))
        #expect(v.sampleCount == 2 && v.totalWeight == 2)
        #expect(abs(v.centroid[0] - v.centroid[1]) < 0.001, "equal weights → halfway (45°)")
        let low = try store.map(Self.at(0), weight: 0.1, to: p.id)
        #expect(low.centroid[0] > low.centroid[1] && low.centroid[0] - low.centroid[1] < 0.2, "a low-quality sample moves it a little")

        let reopened = try VoiceprintStore(url: store.url)
        #expect(reopened.people() == [p])
        let saved = try #require(reopened.voiceprints(embedder: "fluid-wespeaker").first)
        #expect(saved.sampleCount == 3 && saved.centroid.count == 4)
        try reopened.rename(p.id, to: "Rahul K")
        #expect(reopened.people().first?.name == "Rahul K")
        try reopened.forget(p.id)
        #expect(reopened.people().isEmpty && reopened.voiceprints(embedder: "fluid-wespeaker").isEmpty)
        #expect(throws: VoiceprintError.emptyEmbedding) { try reopened.map(SpeakerEmbedding(vector: [], embedder: "x"), to: "id") }
    }

    @Test("meeting auto-match: one person applied to one speaker, the runner-up only suggested; You never matched")
    func meetingAutoMatch() throws {
        let (store, dir) = try Self.store(); defer { try? FileManager.default.removeItem(at: dir) }
        let priya = try store.person(named: "Priya")
        try store.map(Self.at(0), to: priya.id)
        let m = store.match(speakers: [.others(1): Self.at(10), .others(2): Self.at(25), .others(3): Self.at(80), .you: Self.at(0)])
        #expect(m[.others(1)]?.person == priya)
        if case .applied = m[.others(1)] {} else { Issue.record("closest is applied") }
        if case .suggested = m[.others(2)] {} else { Issue.record("runner-up downgraded to a suggestion") }
        #expect(m[.others(3)] == .new)
        #expect(m[.you] == nil)
    }

    @Test("local only: sync off by default, file excluded from backup")
    func localOnly() throws {
        let (store, dir) = try Self.store(); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(store.syncAllowed == false)
        store.syncAllowed = true
        #expect(try VoiceprintStore(url: store.url).syncAllowed)
        let values = try store.url.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
        #expect(VoiceprintStore.defaultURL().path.contains("Voiceprints"))
    }

    @Test("meeting flow: mapping a cluster names it and saves it; the next meeting is auto-matched")
    func mappingFlow() throws {
        let (library, dir) = try Self.store(); defer { try? FileManager.default.removeItem(at: dir) }
        let meetings = MeetingStore(root: dir.appendingPathComponent("Meetings"))
        let mapping = MeetingVoiceMapping(library: library, names: FileMeetingSpeakerNames(store: meetings))
        // Meeting 1: two voices, nobody known.
        try MeetingSpeakerVoices(voices: ["Others": .init(embedding: Self.at(0), seconds: 60),
                                          "Others 2": .init(embedding: Self.at(90), seconds: 12)])
            .save(to: meetings.directory(for: "m1"))
        #expect(mapping.autoMatch(meetingID: "m1").values.allSatisfy { $0 == .new })
        let priya = try mapping.map(.others(1), to: "Priya", meetingID: "m1")
        #expect(FileMeetingSpeakerNames(store: meetings).names(for: "m1").name(for: .others(1)) == "Priya")
        #expect(library.voiceprints(embedder: "fluid-wespeaker").first?.personID == priya.id)

        // Meeting 2: Priya again (applied, numbered differently), someone close-ish (suggested).
        try MeetingSpeakerVoices(voices: ["Others 3": .init(embedding: Self.at(20), seconds: 40),
                                          "Others": .init(embedding: Self.at(48), seconds: 40),
                                          "You": .init(embedding: Self.at(0), seconds: 40)])
            .save(to: meetings.directory(for: "m2"))
        let m = mapping.autoMatch(meetingID: "m2")
        #expect(m[.others(3)]?.person == priya && m[.you] == nil)
        let names = FileMeetingSpeakerNames(store: meetings).names(for: "m2")
        #expect(names.name(for: .others(3)) == "Priya")
        #expect(names.name(for: .others(1)) == "Others", "a suggestion is never applied")
        let voices = MeetingSpeakerVoices.load(from: meetings.directory(for: "m2"))
        #expect(voices.entry(for: .others(1))?.suggestedName == "Priya")
        // A name the user chose is never overwritten by a later auto-match.
        var renamed = names; renamed.names["Others 3"] = "P. Sharma"
        try FileMeetingSpeakerNames(store: meetings).save(renamed, for: "m2")
        mapping.autoMatch(meetingID: "m2")
        #expect(FileMeetingSpeakerNames(store: meetings).names(for: "m2").name(for: .others(3)) == "P. Sharma")
        #expect(MeetingVoiceMapping.speaker(forLabel: "Others 7") == .others(7) && MeetingVoiceMapping.speaker(forLabel: "x") == nil)
        #expect(VoiceprintWeight.forSeconds(60) == 1 && VoiceprintWeight.forSeconds(0) == 0.05)
    }
}
