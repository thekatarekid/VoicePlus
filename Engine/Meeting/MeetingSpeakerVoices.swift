import Foundation
import Shared

// V5 M10 — a meeting's speakers ↔ the voiceprint library.
//
// At the end of a meeting each speaker's embedding centroid is written beside the meeting as
// `speaker-voices.json` (local, like the transcript). `MeetingVoiceMapping` then
//   * auto-matches every speaker against `VoiceprintStore`: an applied match names the speaker in
//     `speaker-names.json` (the M18 contract), a middle-band match is kept as a suggestion;
//   * saves a mapping the user makes ("Others 2" → Priya) into the library, so the next meeting
//     recognises her.

/// Per-speaker voices of one meeting (`speaker-voices.json`).
public struct MeetingSpeakerVoices: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var embedding: SpeakerEmbedding
        /// Seconds of speech averaged into `embedding`.
        public var seconds: Double
        /// Library suggestion from the last auto-match ("maybe Priya"), never applied by itself.
        public var suggestedName: String?
        public var suggestedSimilarity: Float?
        public init(embedding: SpeakerEmbedding, seconds: Double, suggestedName: String? = nil, suggestedSimilarity: Float? = nil) {
            self.embedding = embedding; self.seconds = seconds
            self.suggestedName = suggestedName; self.suggestedSimilarity = suggestedSimilarity
        }
    }

    /// Keyed by `MeetingSpeaker.label`, like `MeetingSpeakerNames`.
    public var voices: [String: Entry]
    public init(voices: [String: Entry] = [:]) { self.voices = voices }

    public static let fileName = "speaker-voices.json"

    public func entry(for speaker: MeetingSpeaker) -> Entry? { voices[speaker.label] }

    public static func load(from directory: URL) -> MeetingSpeakerVoices {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)),
              let v = try? JSONDecoder().decode(MeetingSpeakerVoices.self, from: data) else { return .init() }
        return v
    }

    public func save(to directory: URL) throws {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try enc.encode(self).write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
    }
}

/// Library weight of one meeting's cluster: speech seconds / 30, in 0.05…1.
public enum VoiceprintWeight {
    public static func forSeconds(_ s: Double) -> Float { Float(max(0.05, min(1, s / 30))) }
}

public struct MeetingVoiceMapping: Sendable {
    public let library: VoiceprintStore
    public let names: FileMeetingSpeakerNames

    public init(library: VoiceprintStore, names: FileMeetingSpeakerNames = FileMeetingSpeakerNames()) {
        self.library = library; self.names = names
    }

    private func directory(_ meetingID: String) -> URL { names.store.directory(for: meetingID) }

    /// Matches the meeting's speakers against the library. Applied names go into
    /// `speaker-names.json` unless the speaker already has a name there (a user's choice is never
    /// overwritten); suggestions are stored in `speaker-voices.json`. Returns the matches.
    @discardableResult
    public func autoMatch(meetingID: String) -> [MeetingSpeaker: VoiceprintMatch] {
        let dir = directory(meetingID)
        var voices = MeetingSpeakerVoices.load(from: dir)
        var speakers: [MeetingSpeaker: SpeakerEmbedding] = [:]
        for label in voices.voices.keys {
            if let s = Self.speaker(forLabel: label), let e = voices.voices[label]?.embedding { speakers[s] = e }
        }
        let matches = library.match(speakers: speakers)
        var current = names.names(for: meetingID)
        for (speaker, m) in matches {
            switch m {
            case .applied(let p, _):
                if current.names[speaker.label] == nil { current.names[speaker.label] = p.name }
                library.touch(p.id)
                voices.voices[speaker.label]?.suggestedName = nil
                voices.voices[speaker.label]?.suggestedSimilarity = nil
            case .suggested(let p, let s):
                voices.voices[speaker.label]?.suggestedName = p.name
                voices.voices[speaker.label]?.suggestedSimilarity = s
            case .new:
                voices.voices[speaker.label]?.suggestedName = nil
                voices.voices[speaker.label]?.suggestedSimilarity = nil
            }
        }
        try? voices.save(to: dir)
        try? names.save(current, for: meetingID)
        return matches
    }

    /// The user mapped `speaker` to `name`: name it in this meeting and save its voice to the
    /// library (when the meeting has one for it). Returns the person.
    @discardableResult
    public func map(_ speaker: MeetingSpeaker, to name: String, meetingID: String) throws -> VoiceprintPerson {
        let person = try library.person(named: name)
        var current = names.names(for: meetingID)
        current.names[speaker.label] = person.name
        try names.save(current, for: meetingID)
        let dir = directory(meetingID)
        var voices = MeetingSpeakerVoices.load(from: dir)
        if let entry = voices.voices[speaker.label], speaker != .you {
            try library.map(entry.embedding, weight: VoiceprintWeight.forSeconds(entry.seconds), to: person.id)
            voices.voices[speaker.label]?.suggestedName = nil
            voices.voices[speaker.label]?.suggestedSimilarity = nil
            try voices.save(to: dir)
        }
        return person
    }

    /// `MeetingSpeaker.label` back to the speaker ("You", "Others", "Others 3").
    public static func speaker(forLabel label: String) -> MeetingSpeaker? {
        if label == MeetingSpeaker.you.label { return .you }
        if label == MeetingSpeaker.others(1).label { return .others(1) }
        let prefix = "Others "
        guard label.hasPrefix(prefix), let n = Int(label.dropFirst(prefix.count)), n > 1 else { return nil }
        return .others(n)
    }
}
