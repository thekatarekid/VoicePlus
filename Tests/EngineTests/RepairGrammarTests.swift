import Foundation
import Testing
import Shared
@testable import Engine

@Suite("P1.6 T3 — repair grammar routing")
struct RepairGrammarTests {
    /// Scripted commands: the 10 `Fixtures/audio/commands` transcripts (repair ones + non-repair
    /// ones that must NOT parse) plus voice variants. Target ≥ 98 % routing accuracy.
    static let scripted: [(String, RepairCommand?)] = [
        // From Fixtures/audio/commands/manifest.json
        ("no, Thursday", .snap("thursday")), ("scratch that", .scratch), ("put it back", .undo), ("not that one", .cycle),
        ("make this shorter", nil), ("delete the last sentence", .scratch), ("undo that", .undo),
        ("replace Monday with Friday", .snap("friday")), ("make it more formal", nil), ("new paragraph", nil),
        // snap variants
        ("No, Kothari.", .snap("kothari")), ("no kothari", .snap("kothari")), ("nope, Priya", .snap("priya")),
        ("no I said Kothari", .snap("kothari")), ("no I meant TeamViewer", .snap("teamviewer")), ("no it's Priya", .snap("priya")),
        ("no, it is Priya", .snap("priya")), ("I said Rishi", .snap("rishi")), ("I meant kubectl", .snap("kubectl")),
        ("um no, Daniel", .snap("daniel")), ("no that's Samantha", .snap("samantha")), ("change that to Friday", .snap("friday")),
        ("change it to Tuesday", .snap("tuesday")), ("it should be Kothari", .snap("kothari")), ("no, TeamViewer AG", .snap("teamviewer ag")),
        ("swap Monday to Friday", .snap("friday")), ("no make it Thursday", .snap("thursday")), ("nope I said March", .snap("march")),
        ("No—Kothari", .snap("kothari")), ("no, it's spelled Priya", .snap("spelled priya")),
        // cycle variants
        ("not that", .cycle), ("Not that one!", .cycle), ("next one", .cycle), ("the other one", .cycle), ("try again", .cycle),
        ("uh not that one", .cycle), ("no not that one", .cycle), ("the next one", .cycle), ("another one", .cycle), ("next", .cycle),
        // scratch variants
        ("Scratch that.", .scratch), ("strike that", .scratch), ("erase that", .scratch), ("delete that", .scratch), ("never mind", .scratch),
        ("nevermind", .scratch), ("delete the last phrase", .scratch), ("forget that", .scratch), ("um scratch that", .scratch), ("cancel that", .scratch),
        // undo variants
        ("undo", .undo), ("put that back", .undo), ("go back", .undo), ("revert", .undo), ("bring it back", .undo), ("change it back", .undo),
        ("no put it back", .undo), ("undo it", .undo), ("Put it back, please", .undo), ("please put it back", .undo),
        // numbered picks
        ("number two", .pick(2)), ("the second one", .pick(2)), ("option three", .pick(3)), ("pick the first one", .pick(1)),
        ("two", .pick(2)), ("three", .pick(3)), ("choose 3", .pick(3)), ("the third one", .pick(3)), ("number one", .pick(1)), ("take the fourth one", .pick(4)),
        // Not repairs (dictation / transforms that reach the stage by mistake)
        ("send the report to Kothari tomorrow", nil), ("rewrite this", nil), ("I think we should ship on Thursday", nil),
        ("summarize the thread", nil), ("the meeting moved to two thirty", nil), ("we need two more reviewers before Friday", nil),
        ("translate this to French", nil), ("no worries, I'll handle it and send the update tonight", nil), ("", nil),
        ("one moment I will check the calendar and get back to you", nil),
    ]

    @Test func routingAccuracyAtLeast98Percent() {
        var wrong: [String] = []
        for (text, expected) in Self.scripted where RepairGrammar.parse(text) != expected {
            wrong.append("\(text) → \(String(describing: RepairGrammar.parse(text))) expected \(String(describing: expected))")
        }
        let accuracy = Double(Self.scripted.count - wrong.count) / Double(Self.scripted.count)
        #expect(Self.scripted.count >= 50)
        #expect(accuracy >= 0.98, "accuracy \(accuracy): \(wrong)")
    }

    @Test func commandFixtureTranscriptsAgreeWithManifest() throws {
        let url = try #require(AppPaths.fixturesDirectory()).appendingPathComponent("audio/commands/manifest.json")
        struct Entry: Decodable { let file: String; let transcript: String }
        let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: url))
        #expect(entries.count >= 10)
        for e in entries {
            let scripted = Self.scripted.first { $0.0 == e.transcript }
            #expect(scripted != nil, "fixture \(e.file) transcript \"\(e.transcript)\" not covered")
        }
    }

    @Test func stageHonoursFlagAndRoute() async throws {
        let sink = InMemoryReplaceRangeSink(document: "meet kothari")
        let session = RepairSession(replaceSink: sink)
        var u = Utterance(spans: [
            TranscriptSpan(text: "meet", confidence: 0.9, audioRange: 0...0.2),
            TranscriptSpan(text: "kothari", confidence: 0.3, audioRange: 0.3...0.7, alternates: [Alternate(text: "Cotari", score: 0.5, source: .beam)]),
        ])
        u.route = .dictate
        session.land(u, fieldOffset: 0)
        let stage = RepairStage(session: session)
        let cmd = [TranscriptSpan(text: "not that one", confidence: 0.9, audioRange: 0...0.5, provenance: [.asr, .gatekeeper])]

        // Flag off → pass-through, provenance still appended.
        let off = try await stage.process(cmd, context: StageContext(flags: [FeatureFlag.voiceRepair.id: false]))
        #expect(off[0].provenance == [.asr, .gatekeeper, .repair] && session.lastResult == .ignored(reason: "flag-off"))
        #expect(ConfidenceContract.verify(input: cmd, output: off).isEmpty)

        // Gatekeeper said dictate → not consumed.
        _ = try await stage.process(cmd, context: StageContext(extra: ["gatekeeper.route": "dictate"]))
        #expect(!session.lastResult.consumedUtterance)

        // Gatekeeper said repairCommand → applied.
        _ = try await stage.process(cmd, context: StageContext(extra: ["gatekeeper.route": "repairCommand"]))
        #expect(session.lastResult == .replaced(spanIndex: 1, from: "kothari", to: "Cotari"))
        #expect(sink.document == "meet Cotari")

        // Dictation with no grammar match → ignored.
        let dict = [TranscriptSpan(text: "see you at noon", confidence: 0.9, audioRange: 0...1)]
        _ = try await stage.process(dict, context: StageContext(extra: ["gatekeeper.route": "repairCommand"]))
        #expect(session.lastResult == .ignored(reason: "no-grammar-match"))
    }
}

