import Engine
import Shared
import SwiftUI

// V5 M13 (+ M10) — the meeting's speakers in the detail view: one chip per speaker with its
// descriptive label (or name), a hover card with every attribute, a 3 s snippet of their voice
// (when the recording was kept, M5) and "Map to…", which names the speaker in this meeting and saves
// their voice to the local voiceprint library so the next meeting recognises them.

@MainActor
final class MeetingSpeakersModel: ObservableObject {
    struct Row: Identifiable, Equatable {
        var id: String { speaker.label }
        var speaker: MeetingSpeaker
        var title: String
        /// Set when the title is a real name (mapped / applied by the library).
        var isNamed: Bool
        var descriptor: SpeakerDescriptor?
        var suggestion: String?
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var people: [String] = []
    @Published var error: String?
    let meetingID: String
    private let names: FileMeetingSpeakerNames
    private let library: () -> VoiceprintStore?

    init(meetingID: String, store: MeetingStore = MeetingStore(),
         library: @escaping () -> VoiceprintStore? = { try? VoiceprintStore() }) {
        self.meetingID = meetingID
        self.names = FileMeetingSpeakerNames(store: store)
        self.library = library
        reload()
    }

    func reload() {
        let dir = names.store.directory(for: meetingID)
        let descriptors = MeetingSpeakerDescriptors.load(from: dir)
        let voices = MeetingSpeakerVoices.load(from: dir)
        let saved = names.savedNames(for: meetingID)
        rows = descriptors.descriptors.compactMap { d in
            guard let speaker = MeetingVoiceMapping.speaker(forLabel: d.speaker) else { return nil }
            let name = saved.names[d.speaker]
            return Row(speaker: speaker, title: name ?? d.label, isNamed: name != nil, descriptor: d,
                       suggestion: voices.entry(for: speaker)?.suggestedName ?? d.candidates.max { $0.confidence < $1.confidence }?.name)
        }
        people = library()?.people().map(\.name) ?? []
    }

    /// Names `speaker` and saves their voice to the library.
    func map(_ speaker: MeetingSpeaker, to name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, let library = library() else { return }
        do {
            try MeetingVoiceMapping(library: library, names: names).map(speaker, to: n, meetingID: meetingID)
            error = nil
        } catch {
            self.error = "Couldn’t save the name: \(error.localizedDescription)"
        }
        reload()
    }
}

/// The strip above the transcript.
struct MeetingSpeakersStrip: View {
    @StateObject private var model: MeetingSpeakersModel
    /// Plays the recording from a time (nil when no recording was kept).
    var playSnippet: ((TimeInterval) -> Void)?
    var onNamesChanged: () -> Void

    init(meetingID: String, store: MeetingStore = MeetingStore(), playSnippet: ((TimeInterval) -> Void)?, onNamesChanged: @escaping () -> Void) {
        _model = StateObject(wrappedValue: MeetingSpeakersModel(meetingID: meetingID, store: store))
        self.playSnippet = playSnippet
        self.onNamesChanged = onNamesChanged
    }

    var body: some View {
        if !model.rows.isEmpty {
            VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                Text("Speakers")
                    .windowFont(Tokens.Typography.key)
                    .foregroundStyle(WindowColor.secondaryInk)
                FlowChips(rows: model.rows) { row in
                    MeetingSpeakerChip(row: row, people: model.people, playSnippet: playSnippet) { name in
                        model.map(row.speaker, to: name)
                        onNamesChanged()
                    }
                }
                if let error = model.error {
                    Text(error).windowFont(Tokens.Typography.meta).foregroundStyle(WindowColor.secondaryInk)
                }
            }
            .accessibilityIdentifier("meetings.transcript.speakers")
        }
    }
}

/// Chips wrapped onto as many lines as they need.
private struct FlowChips<Chip: View>: View {
    var rows: [MeetingSpeakersModel.Row]
    @ViewBuilder var chip: (MeetingSpeakersModel.Row) -> Chip
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Tokens.Spacing.s) { ForEach(rows) { chip($0) } }
            VStack(alignment: .leading, spacing: Tokens.Spacing.s) { ForEach(rows) { chip($0) } }
        }
    }
}

struct MeetingSpeakerChip: View {
    var row: MeetingSpeakersModel.Row
    var people: [String]
    var playSnippet: ((TimeInterval) -> Void)?
    var onMap: (String) -> Void
    @State private var hovering = false
    @State private var pinned = false

    var body: some View {
        Button { pinned.toggle() } label: {
            HStack(spacing: Tokens.Spacing.xs) {
                Image(systemName: row.isNamed ? "person.fill" : "person.wave.2")
                Text(row.title).lineLimit(1)
            }
            .windowFont(Tokens.Typography.meta)
            .padding(.horizontal, Tokens.Spacing.s)
            .padding(.vertical, Tokens.Spacing.xs)
            .background(Capsule().fill(WindowColor.accent.opacity(row.isNamed ? 0.16 : 0.08)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .popover(isPresented: Binding(get: { hovering || pinned }, set: { if !$0 { pinned = false; hovering = false } })) {
            MeetingSpeakerCard(row: row, people: people, playSnippet: playSnippet, onMap: { name in
                pinned = false; hovering = false; onMap(name)
            })
            .onHover { inside in if inside { hovering = true } }
        }
        .accessibilityLabel("Speaker \(row.title)")
        .accessibilityIdentifier("meetings.speaker.\(row.speaker.label)")
    }
}

/// The hover card: every attribute, the snippet, "Map to…".
struct MeetingSpeakerCard: View {
    var row: MeetingSpeakersModel.Row
    var people: [String]
    var playSnippet: ((TimeInterval) -> Void)?
    var onMap: (String) -> Void
    @State private var mapping = false
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Text(row.title).windowFont(Tokens.Typography.body).bold()
            if row.isNamed, let label = row.descriptor?.label { Text(label).foregroundStyle(WindowColor.secondaryInk) }
            if let d = row.descriptor {
                ForEach(Array(d.attributes.enumerated()), id: \.offset) { _, a in
                    HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.s) {
                        Text(Self.caption(a.kind)).foregroundStyle(WindowColor.secondaryInk).frame(width: 90, alignment: .leading)
                        Text(a.text)
                    }
                    .windowFont(Tokens.Typography.meta)
                }
                if let playSnippet {
                    Button { playSnippet(d.snippetStart) } label: { Label("Play 3 s of their voice", systemImage: "play.circle") }
                        .accessibilityIdentifier("meetings.speaker.snippet")
                }
            }
            if row.speaker != .you {
                Divider()
                if mapping {
                    TextField("Name", text: $name).textFieldStyle(.roundedBorder).frame(width: 220)
                        .onSubmit { onMap(name) }
                    let options = Self.options(people: people, suggestion: row.suggestion, typed: name)
                    ForEach(options, id: \.self) { option in
                        Button(option) { onMap(option) }.buttonStyle(.link)
                    }
                    HStack {
                        Button("Cancel") { mapping = false }
                        Button("Save") { onMap(name) }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                            .keyboardShortcut(.defaultAction)
                    }
                } else {
                    Button(row.isNamed ? "Change name…" : "Map to…") { name = row.suggestion ?? ""; mapping = true }
                        .accessibilityIdentifier("meetings.speaker.mapTo")
                    Text("Saves their voice on this Mac so the next meeting recognises them.")
                        .windowFont(Tokens.Typography.meta).foregroundStyle(WindowColor.secondaryInk)
                }
            }
        }
        .padding(Tokens.Spacing.m)
        .frame(minWidth: 260, alignment: .leading)
    }

    /// Up to five names: the suggestion first, then library people matching what was typed.
    static func options(people: [String], suggestion: String?, typed: String) -> [String] {
        let q = typed.trimmingCharacters(in: .whitespaces).lowercased()
        var out: [String] = suggestion.map { [$0] } ?? []
        for p in people where !out.contains(p) && (q.isEmpty || p.lowercased().contains(q)) { out.append(p) }
        return Array(out.prefix(5))
    }

    static func caption(_ k: SpeakerAttributeKind) -> String {
        switch k {
        case .candidateName: return "Name hint"
        case .location: return "Where"
        case .pitch: return "Voice"
        case .gender: return "Perceived"
        case .loudness: return "Loudness"
        case .pace: return "Pace"
        case .timeSpan: return "Heard"
        case .language: return "Language"
        case .talkShare: return "Talk share"
        case .role: return "Role"
        case .questions: return "Questions"
        case .quote: return "First said"
        }
    }
}

/// Settings › Meetings — the perceived-gender switch (on by default, owner decision M13).
struct MeetingSpeakerLabelSettingsSection: View {
    @AppStorage(SpeakerDescriptorBuilder.perceivedGenderKey) private var perceivedGender = true
    var body: some View {
        Section("Speaker labels") {
            Toggle("Describe voices as “probably man / woman”", isOn: $perceivedGender)
                .accessibilityIdentifier("meetings.settings.perceivedGender")
            Text("Speakers are labelled by how they sound and where they are (“Deep voice · near the laptop”). The guess comes from pitch, is often wrong, and always says “probably”. Computed on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
