import Engine
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// V5 M13 (+ M10) — the detail view's speaker chips: rows from the meeting's descriptor / voice /
/// name files, "Map to…" names the speaker and saves the voice, picker options.
@Suite("V5 M13 — meeting speaker chips")
@MainActor
struct MeetingsSpeakerLabelsTests {
    @Test("rows show labels, real names win, suggestion offered; mapping names the speaker and saves the voice")
    func rowsAndMapping() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("m13app-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root.appendingPathComponent("Meetings"))
        let library = try VoiceprintStore(url: root.appendingPathComponent("lib.sqlite"))
        let dir = store.directory(for: "m")
        try MeetingSpeakerDescriptors(descriptors: [
            SpeakerDescriptor(speaker: "You", attributes: [], label: "You", firstHeard: 0, lastHeard: 3, snippetStart: 0, candidates: []),
            SpeakerDescriptor(speaker: "Others", attributes: [SpeakerAttribute(kind: .pitch, text: "Deep voice")],
                              label: "Deep voice · on the call", firstHeard: 3, lastHeard: 9, snippetStart: 4,
                              candidates: [SpeakerNameCandidate(name: "Priya", confidence: 0.4, source: "calendar")]),
        ]).save(to: dir)
        try MeetingSpeakerVoices(voices: ["Others": .init(embedding: SpeakerEmbedding(vector: [1, 0], embedder: "fluid-wespeaker"), seconds: 30)])
            .save(to: dir)
        let model = MeetingSpeakersModel(meetingID: "m", store: store, library: { library })
        #expect(model.rows.map(\.title) == ["You", "Deep voice · on the call"])
        #expect(model.rows[1].suggestion == "Priya" && !model.rows[1].isNamed)
        model.map(.others(1), to: "Priya ")
        #expect(model.rows[1].title == "Priya" && model.rows[1].isNamed)
        #expect(model.people == ["Priya"])
        #expect(library.voiceprints(embedder: "fluid-wespeaker").count == 1)
        #expect(FileMeetingSpeakerNames(store: store).names(for: "m").name(for: .others(1)) == "Priya")
    }

    @Test("picker options: suggestion first, then library people matching the typed text, at most five")
    func options() {
        #expect(MeetingSpeakerCard.options(people: ["Asha", "Priya", "Ravi"], suggestion: "Priya", typed: "") == ["Priya", "Asha", "Ravi"])
        #expect(MeetingSpeakerCard.options(people: ["Asha", "Priya", "Ravi"], suggestion: nil, typed: "ra") == ["Ravi"])
        #expect(MeetingSpeakerCard.options(people: (1...9).map { "P\($0)" }, suggestion: nil, typed: "").count == 5)
        #expect(MeetingSpeakerCard.caption(.location) == "Where")
    }
}
