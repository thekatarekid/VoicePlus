import Foundation
import Testing
@testable import Engine

/// V5 M-d follow-up — Markdown has one renderer (`MeetingMarkdownExport`): auto-export and the
/// post-meeting hook payload never fall back to the store's recovery `record.markdown`; and the
/// browser list the detector recognises is the one source the "Don't notify" list reads.
@Suite("Meeting export: one renderer (M-d)")
struct MeetingExportOneRendererTests {
    let record = MeetingRecord(id: "m1", title: "Design review", startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                               endedAt: Date(timeIntervalSince1970: 1_700_001_800))

    @Test func autoExportWithoutMarkdownUsesTheExportRenderer() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("md-one-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try MeetingAutoExporter.export(record, to: MeetingAutoExport(folder: dir, format: .markdown))
        #expect(try String(contentsOf: url, encoding: .utf8) == MeetingMarkdownExport.markdown(record))
    }

    @Test func hookPayloadCarriesTheExportRendering() {
        #expect(PostMeetingHookPayload(record: record).markdown == MeetingMarkdownExport.markdown(record))
        #expect(PostMeetingHookPayload(record: record, markdown: "# Named").markdown == "# Named")
    }

    @Test func everyRecognisedBrowserHasAName() {
        #expect(BrowserMeetingClassifier.browserBundleIDs == Set(BrowserMeetingClassifier.browserNames.keys))
        #expect(BrowserMeetingClassifier.browserNames.values.allSatisfy { !$0.isEmpty })
        #expect(BrowserMeetingClassifier.isBrowser("com.vivaldi.Vivaldi"))
    }
}
