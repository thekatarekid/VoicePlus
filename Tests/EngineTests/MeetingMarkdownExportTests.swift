import Foundation
import Testing
@testable import Engine

/// V5 M18 + M20 — export with M13 names, ticked action items; names file contract.
@Suite struct MeetingMarkdownExportTests {
    static let record: MeetingRecord = {
        let start = Date(timeIntervalSince1970: 1_758_196_800)   // 2025-09-18 12:00 UTC
        return MeetingRecord(id: "x", title: "Product standup", startedAt: start, endedAt: start.addingTimeInterval(24 * 60),
                             transcript: MeetingTranscript(utterances: [
                                MeetingUtterance(speaker: .you, text: "Ship it Friday.", range: 14...16, confidence: 0.9),
                                MeetingUtterance(speaker: .others(2), text: "I'll write the notes.", range: 724...726, confidence: 0.9,
                                                 tag: nil),
                             ]),
                             notes: MeetingNotes(summary: ["Shipping Friday."], actionItems: ["Priya: write the notes", "Me: ship"],
                                                 decisions: ["Ship Friday."], provider: "llm:test"))
    }()

    /// Verify fix: auto-export (Settings › Meetings folder) wrote the store's label-only Markdown;
    /// it now writes the named rendering Export… uses.
    @Test func autoExportWritesTheNamedMarkdown() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("m18-auto-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let md = MeetingMarkdownExport.markdown(Self.record, names: MeetingSpeakerNames([.others(2): "Priya"]))
        let url = try MeetingAutoExporter.export(Self.record, to: MeetingAutoExport(folder: dir, format: .markdown), markdown: md)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text == md && text.contains("**Priya** [12:04]"))
    }

    @Test func exportUsesNamesTimestampsAndTicks() {
        let names = MeetingSpeakerNames([.you: "Aditya", .others(2): "Priya"])
        let md = MeetingMarkdownExport.markdown(Self.record, names: names, completed: ["Me: ship"],
                                                timeZone: TimeZone(identifier: "UTC")!)
        #expect(md.hasPrefix("# Product standup\n\n_2025-09-18 12:00 · 24 min · Aditya, Priya_"))
        #expect(md.contains("**Aditya** [00:14] Ship it Friday."))
        #expect(md.contains("**Priya** [12:04] I'll write the notes."))
        #expect(md.contains("- [ ] Priya: write the notes"))
        #expect(md.contains("- [x] Me: ship"))
        #expect(md.contains("## Decisions\n- Ship Friday."))
    }

    @Test func unnamedSpeakersKeepTheirLabels() {
        let md = MeetingMarkdownExport.markdown(Self.record, timeZone: TimeZone(identifier: "UTC")!)
        #expect(md.contains("**You** [00:14]"))
        #expect(md.contains("**Others 2** [12:04]"))
    }

    @Test func namesFileRoundTripsBesideTheMeeting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("m18-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = FileMeetingSpeakerNames(store: MeetingStore(root: root))
        #expect(source.names(for: "x").isEmpty)
        try source.save(MeetingSpeakerNames([.others(1): "  Sam ", .others(3): " "]), for: "x")
        let back = source.names(for: "x")
        #expect(back.name(for: .others(1)) == "Sam")
        #expect(back.name(for: .others(3)) == "Others 3", "a blank name is not a name")
        let json = try String(contentsOf: source.url(for: "x"), encoding: .utf8)
        #expect(json.contains("\"Others\" : \"Sam\""))
    }
}
