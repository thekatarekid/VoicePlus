import Foundation

// MARK: - V5 M18 + M20 · Markdown export with names
//
// What Export… saves: title, date, duration,
// notes with ticked action items, then the transcript with M13 names and timestamps. The store's
// own `meeting.md` (the recovery text copy, `MeetingTextRecovery`) is untouched: it keeps the
// speaker labels the recovery parser reads back. Auto-export after each meeting is lane 6c's
// `MeetingAutoExporter` (Settings › Meetings folder + format); it can render with this too.

public enum MeetingMarkdownExport {
    public static func markdown(_ record: MeetingRecord, names: MeetingSpeakerNames = .init(),
                                completed: Set<String> = [], timeZone: TimeZone = .current) -> String {
        var s = "# \(record.title)\n\n"
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        var meta = f.string(from: record.startedAt)
        if let end = record.endedAt {
            meta += " · \(max(1, Int((end.timeIntervalSince(record.startedAt) / 60).rounded()))) min"
        }
        let speakers = orderedSpeakers(record.transcript).map { names.name(for: $0) }
        if !speakers.isEmpty { meta += " · " + speakers.joined(separator: ", ") }
        s += "_\(meta)_\n\n"
        if let notes = record.notes {
            s += "## Summary\n"
            s += notes.summary.isEmpty ? "_(nothing captured)_\n" : notes.summary.map { "- \($0)" }.joined(separator: "\n") + "\n"
            if !notes.decisions.isEmpty { s += "\n## Decisions\n" + notes.decisions.map { "- \($0)" }.joined(separator: "\n") + "\n" }
            if !notes.actionItems.isEmpty {
                s += "\n## Action items\n"
                s += notes.actionItems.map { "- [\(completed.contains($0) ? "x" : " ")] \($0)" }.joined(separator: "\n") + "\n"
            }
            s += "\n"
        }
        s += "## Transcript\n\n"
        for u in record.transcript.utterances {
            let tag = u.tagLabel.map { " _(\($0))_" } ?? ""
            s += "**\(names.name(for: u.speaker))** [\(MeetingClock.text(u.range.lowerBound))]\(tag) \(u.text)\n\n"
        }
        return s
    }

    static func orderedSpeakers(_ t: MeetingTranscript) -> [MeetingSpeaker] {
        var seen: [MeetingSpeaker] = []
        for u in t.utterances where !seen.contains(u.speaker) { seen.append(u.speaker) }
        return seen
    }
}
