import Foundation
import Shared

// V5 M10 + M13 (+ M11 hints) — wraps the meeting's labeler: passes every label through unchanged,
// measures each labelled chunk (`SpeakerAcoustics`, plus a voice embedding when a backend is given),
// and when the meeting finishes — after the M8 final pass settled the speakers — writes beside it:
//   speaker-voices.json       per-speaker embedding centroid (M10)
//   speaker-names.json        names the voiceprint library applied (M10, never over a user's name)
//   speaker-descriptors.json  attributes + unique descriptive labels (M13), with name candidates
//                             from the library's middle band and the M11 hint sources.
// Nothing here changes the transcript; nothing leaves the machine.

/// M11 — something that suggests names for a finished meeting's speakers.
public protocol SpeakerNameHinting: Sendable {
    func candidates(for record: MeetingRecord, directory: URL) async -> [MeetingSpeaker: [SpeakerNameCandidate]]
}

public final class DescribingLabeler: SpeakerLabeler, FinalSpeakerRelabeling, @unchecked Sendable {
    public let inner: any SpeakerLabeler
    public var name: String { inner.name }
    let voices: (any SpeakerEmbeddingBackend)?
    let voiceEmbedder: String
    let library: (@Sendable () -> VoiceprintStore?)
    let hints: (any SpeakerNameHinting)?
    let context: @Sendable (MeetingRecord) -> SpeakerDescriptionContext
    private let lock = NSLock()
    private var chunks: [ChunkAcoustics] = []
    private var embeddings: [(start: TimeInterval, end: TimeInterval, vector: [Float])] = []
    private var voicesReady: Bool?

    public init(inner: any SpeakerLabeler, voices: (any SpeakerEmbeddingBackend)? = nil, voiceEmbedder: String = MeetingEmbeddingChoice.wespeaker.embedderID,
                library: @escaping @Sendable () -> VoiceprintStore? = { try? VoiceprintStore() },
                hints: (any SpeakerNameHinting)? = nil,
                context: @escaping @Sendable (MeetingRecord) -> SpeakerDescriptionContext = {
                    SpeakerDescriptionContext(title: $0.title, startedAt: $0.startedAt,
                                              perceivedGender: SpeakerDescriptorBuilder.perceivedGenderEnabled())
                }) {
        self.inner = inner; self.voices = voices; self.voiceEmbedder = voiceEmbedder
        self.library = library; self.hints = hints; self.context = context
    }

    public func label(_ batch: [MeetingChunk]) async throws -> [LabeledChunk] {
        let out = try await inner.label(batch)
        var ready = lock.withLock { voicesReady }
        if ready == nil, let voices {
            ready = (try? await voices.prepare()) != nil
            lock.withLock { voicesReady = ready }
        }
        for c in batch {
            let a = SpeakerAcoustics.measure(c.chunk.samples, start: c.range.lowerBound, channel: c.channel)
            var v: [Float]?
            if ready == true, a.levelDB != nil, let e = try? voices?.embedding(for: c.chunk.samples), !e.isEmpty { v = e }
            lock.withLock {
                chunks.append(a)
                if let v { embeddings.append((a.start, a.end, v)) }
            }
        }
        return out
    }

    public var measuredChunks: [ChunkAcoustics] { lock.withLock { chunks } }

    public func finalTranscript(for record: MeetingRecord, recordingIn directory: URL) async -> MeetingTranscript? {
        let relabelled = await (inner as? any FinalSpeakerRelabeling)?.finalTranscript(for: record, recordingIn: directory)
        var final = record
        if let relabelled { final.transcript = relabelled }
        await describe(final, directory: directory)
        return relabelled
    }

    /// The finish-time pass (public so the app can re-run it, e.g. after a manual relabel).
    public func describe(_ record: MeetingRecord, directory: URL) async {
        let (chunks, embeddings) = lock.withLock { (self.chunks, self.embeddings) }
        // M10 — per-speaker centroids from the chunks each speaker owns in the final transcript.
        var voices = MeetingSpeakerVoices()
        for (speaker, (sum, seconds)) in Self.centroids(embeddings, transcript: record.transcript) {
            voices.voices[speaker.label] = .init(embedding: SpeakerEmbedding(vector: sum, embedder: voiceEmbedder), seconds: seconds)
        }
        try? voices.save(to: directory)
        let names = FileMeetingSpeakerNames(store: MeetingStore(root: directory.deletingLastPathComponent()))
        var candidates: [MeetingSpeaker: [SpeakerNameCandidate]] = [:]
        if !voices.voices.isEmpty, let library = library() {
            let mapping = MeetingVoiceMapping(library: library, names: names)
            for (speaker, m) in mapping.autoMatch(meetingID: record.id) {
                if case .suggested(let p, let s) = m {
                    candidates[speaker, default: []].append(SpeakerNameCandidate(name: p.name, confidence: Double(s), source: "voiceprint"))
                }
            }
        }
        // M11 — hint sources; a speaker already named (library / user) needs no candidate.
        if let hints {
            let named = names.savedNames(for: record.id)
            for (speaker, cs) in await hints.candidates(for: record, directory: directory) where named.names[speaker.label] == nil {
                candidates[speaker, default: []] += cs
            }
        }
        var ctx = context(record)
        for (s, cs) in candidates { ctx.candidates[s, default: []] += cs }
        let descriptors = SpeakerDescriptorBuilder.describe(record.transcript, chunks: chunks, context: ctx)
        try? descriptors.save(to: directory)
    }

    /// Embeddings → speakers by overlap with the transcript; mean vector and seconds per speaker.
    static func centroids(_ es: [(start: TimeInterval, end: TimeInterval, vector: [Float])],
                          transcript: MeetingTranscript) -> [MeetingSpeaker: ([Float], Double)] {
        var out: [MeetingSpeaker: ([Float], Double)] = [:]
        for e in es {
            var best: (MeetingSpeaker, Double)?
            for u in transcript.utterances {
                let o = min(e.end, u.range.upperBound) - max(e.start, u.range.lowerBound)
                if o > 0, o > (best?.1 ?? 0) { best = (u.speaker, o) }
            }
            guard let (s, _) = best else { continue }
            let d = e.end - e.start
            if let (sum, secs) = out[s], sum.count == e.vector.count {
                out[s] = (zip(sum, e.vector).map { $0 + $1 * Float(d) }, secs + d)
            } else if out[s] == nil {
                out[s] = (e.vector.map { $0 * Float(d) }, d)
            }
        }
        return out
    }
}
