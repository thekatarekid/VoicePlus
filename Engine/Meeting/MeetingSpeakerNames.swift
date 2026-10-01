import Foundation

// MARK: - V5 M18 · speaker names for a meeting
//
// M13 (lane 6b) produces descriptive labels / names for a meeting's speakers. This is the read
// contract the transcript, search, export, notes and Ask use: a map from `MeetingSpeaker` to a
// display name, stored beside the meeting as `speaker-names.json`. A speaker without a name keeps
// its `label` ("You", "Others 2"). M13 writes the file (or conforms its own store to
// `MeetingSpeakerNameSource`); nothing here guesses a name.

public struct MeetingSpeakerNames: Codable, Equatable, Sendable {
    /// Keyed by `MeetingSpeaker.label` so the JSON stays readable: {"You": "Aditya", "Others 2": "Priya"}.
    public var names: [String: String]

    public init(_ names: [MeetingSpeaker: String] = [:]) {
        var out: [String: String] = [:]
        for (speaker, name) in names {
            let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !n.isEmpty { out[speaker.label] = n }
        }
        self.names = out
    }

    public var isEmpty: Bool { names.isEmpty }

    /// The name for `speaker`, else its label.
    public func name(for speaker: MeetingSpeaker) -> String {
        names[speaker.label] ?? speaker.label
    }

    public static let fileName = "speaker-names.json"
}

/// Where a meeting's speaker names come from.
public protocol MeetingSpeakerNameSource: Sendable {
    func names(for meetingID: String) -> MeetingSpeakerNames
}

/// `speaker-names.json` in the meeting's directory (`MeetingStore.directory(for:)`).
public struct FileMeetingSpeakerNames: MeetingSpeakerNameSource {
    public let store: MeetingStore
    public init(store: MeetingStore = MeetingStore()) { self.store = store }

    public func url(for meetingID: String) -> URL {
        store.directory(for: meetingID).appendingPathComponent(MeetingSpeakerNames.fileName)
    }

    /// Names to show: what the user / voiceprint library named (`speaker-names.json`), else the
    /// speaker's M13 descriptive label (`speaker-descriptors.json`), else nothing (the caller shows
    /// "Others 2").
    public func names(for meetingID: String) -> MeetingSpeakerNames {
        var out = savedNames(for: meetingID)
        for (label, text) in MeetingSpeakerDescriptors.load(from: store.directory(for: meetingID)).labels where out.names[label] == nil {
            out.names[label] = text
        }
        return out
    }

    /// V5 M13 — only the names in `speaker-names.json` (real names). Load-modify-save goes through
    /// this, so a descriptive label is never saved as though it were a name.
    public func savedNames(for meetingID: String) -> MeetingSpeakerNames {
        guard let data = try? Data(contentsOf: url(for: meetingID)),
              let names = try? JSONDecoder().decode(MeetingSpeakerNames.self, from: data) else { return .init() }
        return names
    }

    public func save(_ names: MeetingSpeakerNames, for meetingID: String) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: store.directory(for: meetingID), withIntermediateDirectories: true)
        try enc.encode(names).write(to: url(for: meetingID), options: .atomic)
    }
}
