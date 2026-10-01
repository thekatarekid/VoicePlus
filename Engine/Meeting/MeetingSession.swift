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
    /// V5 M1–M4 — how the meeting was captured (the last mode in force). Nil for pre-V5 records.
    public var mode: MeetingMode?
    public init(id: String = UUID().uuidString, title: String, startedAt: Date = Date(), endedAt: Date? = nil,
                event: CalendarMeeting? = nil, transcript: MeetingTranscript = MeetingTranscript(), notes: MeetingNotes? = nil,
                labeler: String = "channel", mode: MeetingMode? = nil) {
        self.id = id; self.title = title; self.startedAt = startedAt; self.endedAt = endedAt
        self.event = event; self.transcript = transcript; self.notes = notes; self.labeler = labeler; self.mode = mode
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
    /// V5 M14 — the transcript changed other than by appending (a late tag, an echo veto): the
    /// panel replaces what it shows with this.
    public var onTranscript: (@Sendable (MeetingTranscript) -> Void)?
    /// V5 M1–M3 — the mode in force; hybrid turns the cross-leg echo veto on.
    public private(set) var mode: MeetingMode
    /// V5 M14 — "Show my dictations in meeting transcripts" off: spans tagged "dictated" are left
    /// out of the saved transcript (and so of notes and exports) when the meeting finishes.
    public var keepsDictations = true
    /// V5 M3 — mic lines vetoed as echo of the system leg (diagnostics, tests).
    public private(set) var vetoedEchoes = 0
    /// V5 M3 — recent mic segments that had system energy near them: a system line that arrives in a
    /// later drain can still veto them.
    private var echoSuspects: [MeetingUtterance] = []
    /// V5 M3 — recent system-leg lines (the veto's reference), pruned to `echoHistory`.
    private var systemLines: [MeetingUtterance] = []
    static let echoHistory: TimeInterval = 30
    /// V5 O2 — capability tags not yet matched to a transcribed span (the claim usually settles
    /// before the meeting's chunk is transcribed). Kept for `pendingTagWindow` seconds.
    private var pendingTags: [UtteranceTag] = []
    static let pendingTagWindow: TimeInterval = 120
    /// V5 O2 — every transcribed span as appended, before merging, so a tag that settles after its
    /// span was merged can still label exactly that span (`tag(_:)` re-merges from these).
    private var segments: [MeetingUtterance] = []

    public init(title: String, event: CalendarMeeting? = nil, transcriber: any MeetingTranscriber,
                labeler: any SpeakerLabeler, notesProvider: any MeetingNotesProvider = ExtractiveNotesProvider(),
                store: MeetingStore = MeetingStore(), mode: MeetingMode = .videoCall) {
        record = MeetingRecord(title: title, event: event, labeler: labeler.name, mode: mode)
        self.mode = mode
        self.transcriber = transcriber; self.labeler = labeler; self.notesProvider = notesProvider; self.store = store
    }

    public func setHandlers(onUtterance: (@Sendable (MeetingUtterance) -> Void)? = nil, onFinished: (@Sendable (MeetingRecord) -> Void)? = nil,
                            onTranscript: (@Sendable (MeetingTranscript) -> Void)? = nil) {
        self.onUtterance = onUtterance; self.onFinished = onFinished; self.onTranscript = onTranscript
    }

    /// V5 M4 — the user's override (or the auto-pick at start). Recorded on the meeting.
    public func setMode(_ next: MeetingMode) {
        guard next != mode else { return }
        mode = next
        record.mode = next
        _ = try? store.save(record)
        Log.engine.info("meeting: mode \(next.rawValue)")
    }

    public func setKeepsDictations(_ keep: Bool) { keepsDictations = keep }

    /// Transcribe + label a batch of chunks (already sorted by time) and append to the transcript.
    /// In hybrid mode a mic line that repeats a system line with system energy within 150 ms is
    /// dropped (V5 M3), whichever drain the system line arrives in.
    public func ingest(_ chunks: [MeetingChunk]) async throws {
        guard !chunks.isEmpty else { return }
        let labeled = try await labeler.label(chunks)
        var lines: [(MeetingUtterance, MeetingChunk)] = []
        for l in labeled {
            let spans = try await transcriber.transcribe(l.chunk.chunk)
            let text = spans.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            let conf = spans.isEmpty ? 0 : spans.map(\.confidence).reduce(0, +) / Float(spans.count)
            let base = l.chunk.range.lowerBound
            let lo = base + (spans.first?.audioRange.lowerBound ?? 0)
            let hi = base + (spans.last?.audioRange.upperBound ?? l.chunk.chunk.duration)
            let u = MeetingUtterance(speaker: l.speaker, text: text, range: lo...max(lo, hi), confidence: conf * l.confidence)
            lines.append((u, l.chunk))
        }
        let batchSystem = lines.filter { $0.1.channel == .system }.map(\.0)
        let horizon = (lines.map(\.0.range.lowerBound).min() ?? 0) - Self.echoHistory
        defer {
            systemLines += batchSystem
            systemLines.removeAll { $0.range.upperBound < horizon }
        }
        guard mode.legs.echoVeto else {
            for (u, _) in lines { append(u) }
            return
        }
        let recentSystem = systemLines
        for (u, chunk) in lines {
            if chunk.channel == .mic, MeetingEchoVeto.systemEnergyNear(u.range, activity: chunk.systemActivity) {
                if MeetingEchoVeto.duplicates(u, of: batchSystem + recentSystem) {
                    vetoedEchoes += 1
                    continue
                }
                echoSuspects.append(u)
            }
            append(u)
        }
        retractEchoes(of: batchSystem)
        echoSuspects.removeAll { $0.range.upperBound < horizon }
    }

    /// A system line that arrived after its mic echo was appended: take the echo back out.
    private func retractEchoes(of system: [MeetingUtterance]) {
        guard !system.isEmpty, !echoSuspects.isEmpty else { return }
        let echoes = echoSuspects.filter { MeetingEchoVeto.duplicates($0, of: system) }
        guard !echoes.isEmpty else { return }
        echoSuspects.removeAll { echoes.contains($0) }
        let before = segments.count
        segments.removeAll { echoes.contains($0) }
        guard segments.count != before else { return }
        vetoedEchoes += before - segments.count
        record.transcript.utterances = Self.merged(segments)
        _ = try? store.save(record)
        onTranscript?(record.transcript)
    }

    /// V5 O2 — a capability (dictation, edit, act, note, ask) claimed an utterance while this meeting
    /// was recording. The meeting already holds the words (its mic leg heard them on the shared
    /// capture graph); the tag only labels that span, so the dictation appears once, tagged.
    public func tag(_ tag: UtteranceTag) {
        guard tag.owner != .ignore else { return }
        // Tag the transcribed *segments* (one per chunk), then re-merge: a span merged into the
        // user's adjacent conversation before the claim settled is split back out, and the remark
        // it was merged with is never dragged into "dictated".
        var raw = MeetingTranscript(utterances: segments)
        if raw.apply(tag, origin: record.startedAt) > 0 {
            segments = raw.utterances
            record.transcript.utterances = Self.merged(segments)
            _ = try? store.save(record)
            onTranscript?(record.transcript)   // V5 M14 — the panel shows the tag
        }
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
        segments.append(u)
        if var last = record.transcript.utterances.last, Self.merges(last, u) {
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

    /// Merge with the previous utterance when same speaker and contiguous (< 1 s gap) — and, since
    /// O2, the same owner: a dictated span never merges into the conversation around it.
    static func merges(_ last: MeetingUtterance, _ u: MeetingUtterance) -> Bool {
        last.speaker == u.speaker && last.tag == u.tag && u.range.lowerBound - last.range.upperBound < 1
    }

    /// The transcript as `append` builds it, from the unmerged segments (V5 O2 late tags).
    static func merged(_ segments: [MeetingUtterance]) -> [MeetingUtterance] {
        var out: [MeetingUtterance] = []
        for u in segments {
            if var last = out.last, merges(last, u) {
                last.text += " " + u.text
                last.range = last.range.lowerBound...max(last.range.upperBound, u.range.upperBound)
                last.confidence = min(last.confidence, u.confidence)
                out[out.count - 1] = last
            } else {
                out.append(u)
            }
        }
        return out
    }

    @discardableResult
    public func finish(at now: Date = Date()) async throws -> MeetingRecord {
        record.endedAt = now
        if !keepsDictations {   // V5 M14
            record.transcript.utterances.removeAll { $0.tag == .dictate }
        }
        // V5 M8 — final re-diarization (offline over the saved recording, else the settled live labels).
        if let final = labeler as? any FinalSpeakerRelabeling,
           let relabelled = await final.finalTranscript(for: record, recordingIn: store.directory(for: record.id)) {
            record.transcript = relabelled
        }
        record.notes = try await notesProvider.notes(for: record.transcript)
        try store.save(record)
        onFinished?(record)
        Log.engine.notice("meeting: finished \(record.id) (\(record.transcript.utterances.count) utterances)")
        return record
    }
}
