import FluidAudio
import Foundation
import Shared

// V5 M8 — final re-diarization.
//
// When a meeting finishes, the labeler gets one more pass over the whole thing: with the saved
// recording (M5) the audio is diarized again offline — the complete file, no 30 s streaming lag, no
// VAD gaps — and every utterance is relabelled from it. Without a recording the live labels are kept
// (settled against the live diarizer's own finished timeline, which only replaces the provisional
// labels of the first ~30 s). Nothing leaves the machine; the recording is only read.

/// Where a finished meeting's saved audio is. M5 owns the format; this reads what is there: one file
/// per leg (a name containing "mic" / "system") or one mixed file, any of `audioExtensions`.
public struct MeetingRecordingAudio: Equatable, Sendable {
    public var legs: [MeetingChannel: URL]
    public var mixed: URL?
    /// Seconds between the meeting's clock zero and the recording's first sample.
    public var offset: TimeInterval
    public init(legs: [MeetingChannel: URL] = [:], mixed: URL? = nil, offset: TimeInterval = 0) {
        self.legs = legs; self.mixed = mixed; self.offset = offset
    }

    public static let audioExtensions: Set<String> = ["wav", "caf", "m4a", "aif", "aiff"]

    /// The recording in a meeting's directory, if any.
    public static func locate(in directory: URL, fileManager: FileManager = .default) -> MeetingRecordingAudio? {
        let files = ((try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else { return nil }
        var r = MeetingRecordingAudio()
        for f in files {
            let name = f.deletingPathExtension().lastPathComponent.lowercased()
            if name.contains("system") || name.contains("remote") { r.legs[.system] = r.legs[.system] ?? f }
            else if name.contains("mic") { r.legs[.mic] = r.legs[.mic] ?? f }
            else { r.mixed = r.mixed ?? f }
        }
        if !r.legs.isEmpty { r.mixed = nil }   // per-leg files win over a mix
        return r
    }
}

/// A whole-file diarizer (testable without CoreML). Times are seconds from the file's start.
public protocol OfflineSpeakerDiarizing: AnyObject, Sendable {
    func diarize(_ samples: [Float]) async throws -> [SpeakerTurn]
}

/// Loads a recording as 16 kHz mono (testable seam).
public protocol MeetingAudioReading: Sendable {
    func samples(of url: URL) throws -> [Float]
}

public struct FluidAudioFileReader: MeetingAudioReading {
    public init() {}
    public func samples(of url: URL) throws -> [Float] {
        try AudioConverter(sampleRate: 16_000).resampleAudioFile(url)
    }
}

/// Implemented by labelers that can improve the transcript once the meeting is over.
/// `MeetingSession.finish` asks before writing notes; nil keeps the transcript as it is.
public protocol FinalSpeakerRelabeling: AnyObject, Sendable {
    func finalTranscript(for record: MeetingRecord, recordingIn directory: URL) async -> MeetingTranscript?
}

/// Relabels a transcript from diarizer turns. Utterances carry no leg, so each takes the (leg, slot)
/// with the most overlap across every leg; slots are numbered by first appearance in the transcript.
public enum TranscriptRelabeler {
    public static func relabel(_ transcript: MeetingTranscript, turns: [MeetingChannel: [SpeakerTurn]],
                               youSlots: Set<SpeakerSlotMap.Slot>) -> MeetingTranscript {
        var map = SpeakerSlotMap()
        for s in youSlots { map.markYou(s) }
        var out = transcript
        for i in out.utterances.indices {
            let u = out.utterances[i]
            if let slot = dominantSlot(turns, over: u.range) {
                out.utterances[i].speaker = map.speaker(for: slot)
            } else if case .others(let n) = u.speaker {
                // Not covered by the final pass: keep the live identity, numbered apart from the rest.
                out.utterances[i].speaker = map.speaker(for: .init(leg: .system, index: 1_000 + n))
            }
        }
        return out
    }

    public static func dominantSlot(_ turns: [MeetingChannel: [SpeakerTurn]], over range: ClosedRange<TimeInterval>) -> SpeakerSlotMap.Slot? {
        var best: (SpeakerSlotMap.Slot, Double)?
        for leg in MeetingChannel.allCases {
            guard let hit = StreamingDiarizer.dominant(in: turns[leg] ?? [], over: range) else { continue }
            if best == nil || hit.share > best!.1 { best = (.init(leg: leg, index: hit.index), hit.share) }
        }
        return best?.0
    }

    /// Without a voiceprint: a mic-leg slot is the user when it overlaps the utterances already
    /// labelled "You" more than the ones labelled anyone else.
    public static func youSlotsByVote(_ transcript: MeetingTranscript, turns: [MeetingChannel: [SpeakerTurn]]) -> Set<SpeakerSlotMap.Slot> {
        var score: [Int: Double] = [:]
        for u in transcript.utterances {
            for t in turns[.mic] ?? [] {
                let o = min(t.range.upperBound, u.range.upperBound) - max(t.range.lowerBound, u.range.lowerBound)
                guard o > 0 else { continue }
                score[t.speaker, default: 0] += u.speaker == .you ? o : -o
            }
        }
        return Set(score.filter { $0.value > 0 }.map { SpeakerSlotMap.Slot(leg: .mic, index: $0.key) })
    }

    /// With the user's voice: a mic-leg slot is the user when up to `maxSeconds` of its audio embeds
    /// within `threshold` of the voiceprint. nil when nothing could be embedded (fall back to the vote).
    public static func youSlotsByVoice(micSamples: [Float], micTurns: [SpeakerTurn], offset: TimeInterval,
                                       backend: any SpeakerEmbeddingBackend, enrolled: [Float],
                                       threshold: Float = DiarizationFactory.micThreshold,
                                       maxSeconds: TimeInterval = 8) -> Set<SpeakerSlotMap.Slot>? {
        var bySlot: [Int: [Float]] = [:]
        let cap = Int(maxSeconds * 16_000)
        for t in micTurns {
            let lo = max(0, Int((t.range.lowerBound - offset) * 16_000)), hi = min(micSamples.count, Int((t.range.upperBound - offset) * 16_000))
            guard hi > lo else { continue }
            let room = cap - (bySlot[t.speaker]?.count ?? 0)
            guard room > 0 else { continue }
            bySlot[t.speaker, default: []].append(contentsOf: micSamples[lo..<min(hi, lo + room)])
        }
        var embedded = false
        var you: Set<SpeakerSlotMap.Slot> = []
        for (slot, audio) in bySlot where audio.count >= 16_000 {
            guard let e = try? backend.embedding(for: audio), !e.isEmpty else { continue }
            embedded = true
            if EmbeddingMatch.cosine(e, enrolled) >= threshold { you.insert(.init(leg: .mic, index: slot)) }
        }
        return embedded ? you : nil
    }
}

/// M8 — the offline pass: each recorded leg (or the mix, treated as the mic leg) through the
/// offline diarizer, back on the meeting clock, and the user's slot by voice (when known) or by the
/// live labels' vote.
public struct FinalRediarizer: Sendable {
    public let diarizer: any OfflineSpeakerDiarizing
    public let reader: any MeetingAudioReading
    public let voice: (backend: any SpeakerEmbeddingBackend, enrolled: [Float])?

    public init(diarizer: any OfflineSpeakerDiarizing, reader: any MeetingAudioReading = FluidAudioFileReader(),
                voice: (backend: any SpeakerEmbeddingBackend, enrolled: [Float])? = nil) {
        self.diarizer = diarizer; self.reader = reader; self.voice = voice
    }

    public func relabel(_ transcript: MeetingTranscript, recording: MeetingRecordingAudio) async throws -> MeetingTranscript {
        var files = recording.legs
        if files.isEmpty, let mixed = recording.mixed { files[.mic] = mixed }
        var turns: [MeetingChannel: [SpeakerTurn]] = [:]
        var micSamples: [Float] = []
        for (leg, url) in files {
            let samples = try reader.samples(of: url)
            if leg == .mic { micSamples = samples }
            turns[leg] = try await diarizer.diarize(samples).map {
                SpeakerTurn(speaker: $0.speaker, range: ($0.range.lowerBound + recording.offset)...($0.range.upperBound + recording.offset))
            }
        }
        var you: Set<SpeakerSlotMap.Slot>?
        if let voice {
            try? await voice.backend.prepare()
            you = TranscriptRelabeler.youSlotsByVoice(micSamples: micSamples, micTurns: turns[.mic] ?? [], offset: recording.offset,
                                                      backend: voice.backend, enrolled: voice.enrolled)
        }
        return TranscriptRelabeler.relabel(transcript, turns: turns,
                                           youSlots: you ?? TranscriptRelabeler.youSlotsByVote(transcript, turns: turns))
    }
}

/// M8 — Sortformer over a whole recording: a fresh stream on the resident model
/// (`SortformerDiarizer.processComplete`), so no second model is downloaded. Cap: 4 speakers per leg.
public final class SortformerOfflineDiarizer: OfflineSpeakerDiarizing, @unchecked Sendable {
    let backend: SortformerBackend
    public init(backend: SortformerBackend) { self.backend = backend }
    public func diarize(_ samples: [Float]) async throws -> [SpeakerTurn] {
        try await backend.prepare()
        return try backend.diarizeComplete(samples)
    }
}

extension SortformerLabeler: FinalSpeakerRelabeling {
    /// With a recording in `directory`: offline re-diarization (`FinalRediarizer`). Without one: the
    /// live labels, settled against the live diarizer's finished timeline. nil when neither has turns.
    public func finalTranscript(for record: MeetingRecord, recordingIn directory: URL) async -> MeetingTranscript? {
        let live = diarizer.finish()
        if let recording = MeetingRecordingAudio.locate(in: directory), let offline = makeOffline() {
            do {
                return try await offline.relabel(record.transcript, recording: recording)
            } catch {
                Log.engine.warning("meeting: final re-diarization failed, keeping live labels: \(error)")
            }
        }
        guard live.values.contains(where: { !$0.isEmpty }) else { return nil }
        let you = userSlots.union(TranscriptRelabeler.youSlotsByVote(record.transcript, turns: live))
        return TranscriptRelabeler.relabel(record.transcript, turns: live, youSlots: you)
    }

    /// The offline pass for this labeler's backend: Sortformer's own (same resident model), the
    /// voiceprint from the wrapped embedding labeler when there is one. Tests inject their own.
    func makeOffline() -> FinalRediarizer? {
        if let injected = offlineOverride { return injected }
        guard let backend = diarizer.backend as? SortformerBackend else { return nil }
        let voice = (fallback as? EmbeddingLabeler).map { (backend: $0.backend, enrolled: $0.enrolled) }
        return FinalRediarizer(diarizer: SortformerOfflineDiarizer(backend: backend), voice: voice)
    }
}
