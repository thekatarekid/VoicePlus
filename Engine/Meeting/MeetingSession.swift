import Foundation
import Shared

/// Transcribes a chunk. Bound to `ASRRuntime` at integration; tests use a fake.
public protocol MeetingTranscriber: Sendable {
    func transcribe(_ chunk: AudioChunk) async throws -> [TranscriptSpan]
}

/// A captured meeting: metadata + transcript + notes. Stored as JSON + Markdown locally.
public struct MeetingRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var startedAt: Date
    public var endedAt: Date?
    public var event: CalendarMeeting?
    public var transcript: MeetingTranscript
    public var notes: MeetingNotes?
    public var labeler: String
    public init(id: String = UUID().uuidString, title: String, startedAt: Date = Date(), endedAt: Date? = nil,
                event: CalendarMeeting? = nil, transcript: MeetingTranscript = MeetingTranscript(), notes: MeetingNotes? = nil, labeler: String = "channel") {
        self.id = id; self.title = title; self.startedAt = startedAt; self.endedAt = endedAt
        self.event = event; self.transcript = transcript; self.notes = notes; self.labeler = labeler
    }

    public var markdown: String {
        let f = ISO8601DateFormatter()
        var s = "# \(title)\n\n_\(f.string(from: startedAt))"
        if let e = endedAt { s += " – \(f.string(from: e))" }
        s += "_\n\n"
        if let notes { s += notes.markdown + "\n" }
        s += "## Transcript\n"
        for u in transcript.utterances {
            let tag = u.tagLabel.map { " _(\($0))_" } ?? ""   // V5 O2
            s += "- **\(u.speaker.label)** [\(Self.clock(u.range.lowerBound))]\(tag) \(u.text)\n"
        }
        return s
    }

    static func clock(_ t: TimeInterval) -> String {
        let m = Int(t) / 60, sec = Int(t) % 60
        return String(format: "%02d:%02d", m, sec)
    }
}

/// Filesystem persistence under `AppPaths.supportDirectory()/Meetings/<id>/`
/// (`meeting.json` + `meeting.md`). Nothing leaves the machine.
public struct MeetingStore: Sendable {
    public let root: URL
    public init(root: URL? = nil) {
        self.root = root ?? AppPaths.supportDirectory().appendingPathComponent("Meetings", isDirectory: true)
    }

    public func directory(for id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }

    @discardableResult
    public func save(_ record: MeetingRecord) throws -> URL {
        let dir = directory(for: record.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
        try enc.encode(record).write(to: dir.appendingPathComponent("meeting.json"), options: .atomic)
        try record.markdown.data(using: .utf8)!.write(to: dir.appendingPathComponent("meeting.md"), options: .atomic)
        return dir
    }

    public func load(id: String) throws -> MeetingRecord {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try dec.decode(MeetingRecord.self, from: Data(contentsOf: directory(for: id).appendingPathComponent("meeting.json")))
    }

    public func list() -> [MeetingRecord] {
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return ids.compactMap { try? load(id: $0) }.sorted { $0.startedAt > $1.startedAt }
    }

    public func delete(id: String) throws { try FileManager.default.removeItem(at: directory(for: id)) }
}

/// Drives one meeting: chunks → transcriber → labeler → transcript; on `finish` → notes → store.
/// Streams `onUtterance` for the live "speakers being separated" bar and `onFinished` for the
/// post-call notification.
public actor MeetingSession {
    public private(set) var record: MeetingRecord
    private let transcriber: any MeetingTranscriber
    private let labeler: any SpeakerLabeler
    private let notesProvider: any MeetingNotesProvider
    private let store: MeetingStore
    public var onUtterance: (@Sendable (MeetingUtterance) -> Void)?
    public var onFinished: (@Sendable (MeetingRecord) -> Void)?
    /// V5 O2 — capability tags not yet matched to a transcribed span (the claim usually settles
    /// before the meeting's chunk is transcribed). Kept for `pendingTagWindow` seconds.
    private var pendingTags: [UtteranceTag] = []
    static let pendingTagWindow: TimeInterval = 120

    public init(title: String, event: CalendarMeeting? = nil, transcriber: any MeetingTranscriber,
                labeler: any SpeakerLabeler, notesProvider: any MeetingNotesProvider = ExtractiveNotesProvider(),
                store: MeetingStore = MeetingStore()) {
        record = MeetingRecord(title: title, event: event, labeler: labeler.name)
        self.transcriber = transcriber; self.labeler = labeler; self.notesProvider = notesProvider; self.store = store
    }

    public func setHandlers(onUtterance: (@Sendable (MeetingUtterance) -> Void)? = nil, onFinished: (@Sendable (MeetingRecord) -> Void)? = nil) {
        self.onUtterance = onUtterance; self.onFinished = onFinished
    }

    /// Transcribe + label a batch of chunks (already sorted by time) and append to the transcript.
    public func ingest(_ chunks: [MeetingChunk]) async throws {
        guard !chunks.isEmpty else { return }
        let labeled = try await labeler.label(chunks)
        for l in labeled {
            let spans = try await transcriber.transcribe(l.chunk.chunk)
            let text = spans.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            let conf = spans.isEmpty ? 0 : spans.map(\.confidence).reduce(0, +) / Float(spans.count)
            let base = l.chunk.range.lowerBound
            let lo = base + (spans.first?.audioRange.lowerBound ?? 0)
            let hi = base + (spans.last?.audioRange.upperBound ?? l.chunk.chunk.duration)
            let u = MeetingUtterance(speaker: l.speaker, text: text, range: lo...max(lo, hi), confidence: conf * l.confidence)
            append(u)
        }
    }

    /// V5 O2 — a capability (dictation, edit, act, note, ask) claimed an utterance while this meeting
    /// was recording. The meeting already holds the words (its mic leg heard them on the shared
    /// capture graph); the tag only labels that span, so the dictation appears once, tagged.
    public func tag(_ tag: UtteranceTag) {
        guard tag.owner != .ignore else { return }
        let tagged = record.transcript.apply(tag, origin: record.startedAt)
        if tagged > 0 { _ = try? store.save(record) }
        // Later chunks of the same claim may still be in flight: keep the tag for them too.
        let horizon = tag.range.upperBound.addingTimeInterval(-Self.pendingTagWindow)
        pendingTags.removeAll { $0.range.upperBound < horizon || $0.utteranceID == tag.utteranceID }
        pendingTags.append(tag)
    }

    private func append(_ u: MeetingUtterance) {
        var u = u
        if u.tag == nil, let claim = pendingTags.first(where: {
            MeetingTranscript.claims($0, speaker: u.speaker, range: u.range, origin: record.startedAt)
        }) { u.tag = claim.owner }
        // Merge with the previous utterance when same speaker and contiguous (< 1 s gap) — and, since
        // O2, the same owner: a dictated span never merges into the conversation around it.
        if var last = record.transcript.utterances.last, last.speaker == u.speaker, last.tag == u.tag,
           u.range.lowerBound - last.range.upperBound < 1 {
            last.text += " " + u.text
            last.range = last.range.lowerBound...max(last.range.upperBound, u.range.upperBound)
            last.confidence = min(last.confidence, u.confidence)
            record.transcript.utterances[record.transcript.utterances.count - 1] = last
        } else {
            record.transcript.utterances.append(u)
        }
        // Always save the live transcript so a crash loses nothing.
        _ = try? store.save(record)
        onUtterance?(u)
    }

    @discardableResult
    public func finish(at now: Date = Date()) async throws -> MeetingRecord {
        record.endedAt = now
        record.notes = try await notesProvider.notes(for: record.transcript)
        try store.save(record)
        onFinished?(record)
        Log.engine.notice("meeting: finished \(record.id) (\(record.transcript.utterances.count) utterances)")
        return record
    }
}
