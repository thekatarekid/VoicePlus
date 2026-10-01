import Foundation
import NaturalLanguage
import Shared

// V5 M13 — descriptive speaker labels instead of "Others 2": each speaker's attributes (where they
// are, voice, pace, loudness, perceived gender, time span, role in the conversation, language, a
// first distinctive quote, a candidate name), and a label made of the 2–3 attributes that best tell
// them apart from everyone else in *this* meeting — e.g. "Deep voice · near the laptop · 11:02–11:40".
// Computed on this Mac, never sent anywhere. Perceived gender is a guess from pitch and always says
// "probably"; it is on by default and switchable (`perceivedGenderKey`).

/// One attribute of a speaker.
public enum SpeakerAttributeKind: String, Codable, CaseIterable, Sendable {
    case candidateName, location, pitch, gender, loudness, pace, timeSpan, language, talkShare, role, questions, quote
}

public struct SpeakerAttribute: Codable, Equatable, Sendable {
    public var kind: SpeakerAttributeKind
    /// What the label and hover card show ("Deep voice", "on the call (Zoom)").
    public var text: String
    /// Comparable value: two speakers with the same `key` are not told apart by this attribute.
    public var key: String
    public init(kind: SpeakerAttributeKind, text: String, key: String? = nil) {
        self.kind = kind; self.text = text; self.key = key ?? text
    }
}

/// A name another source suggests for a speaker (M10 library, M11 hints). Always a suggestion.
public struct SpeakerNameCandidate: Codable, Equatable, Sendable {
    public var name: String
    /// 0…1.
    public var confidence: Double
    /// "calendar", "active speaker", "addressed", "lips", "voiceprint".
    public var source: String
    public init(name: String, confidence: Double, source: String) {
        self.name = name; self.confidence = confidence; self.source = source
    }
}

public struct SpeakerDescriptor: Codable, Equatable, Sendable {
    public var speaker: String          // `MeetingSpeaker.label`
    public var attributes: [SpeakerAttribute]
    public var label: String
    /// First and last second the speaker was heard (meeting clock), for the snippet and time span.
    public var firstHeard: TimeInterval
    public var lastHeard: TimeInterval
    /// A 3 s stretch of their clearest speech (meeting clock), for the hover card's snippet.
    public var snippetStart: TimeInterval
    public var candidates: [SpeakerNameCandidate]

    public init(speaker: String, attributes: [SpeakerAttribute], label: String, firstHeard: TimeInterval,
                lastHeard: TimeInterval, snippetStart: TimeInterval, candidates: [SpeakerNameCandidate]) {
        self.speaker = speaker; self.attributes = attributes; self.label = label; self.firstHeard = firstHeard
        self.lastHeard = lastHeard; self.snippetStart = snippetStart; self.candidates = candidates
    }

    public func attribute(_ kind: SpeakerAttributeKind) -> SpeakerAttribute? { attributes.first { $0.kind == kind } }
}

/// `speaker-descriptors.json` beside the meeting.
public struct MeetingSpeakerDescriptors: Codable, Equatable, Sendable {
    public var descriptors: [SpeakerDescriptor]
    public init(descriptors: [SpeakerDescriptor] = []) { self.descriptors = descriptors }
    public static let fileName = "speaker-descriptors.json"

    public func descriptor(for speaker: MeetingSpeaker) -> SpeakerDescriptor? { descriptors.first { $0.speaker == speaker.label } }

    public static func load(from directory: URL) -> MeetingSpeakerDescriptors {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)),
              let d = try? JSONDecoder().decode(MeetingSpeakerDescriptors.self, from: data) else { return .init() }
        return d
    }

    public func save(to directory: URL) throws {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try enc.encode(self).write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
    }

    /// Labels as display names (the user keeps "You").
    public var labels: [String: String] {
        var out: [String: String] = [:]
        for d in descriptors where d.speaker != MeetingSpeaker.you.label { out[d.speaker] = d.label }
        return out
    }
}

/// What the builder knows about the meeting.
public struct SpeakerDescriptionContext: Sendable {
    public var title: String?
    /// Call app ("Zoom", "Meet", "Teams") when known.
    public var app: String?
    public var startedAt: Date
    public var perceivedGender: Bool
    public var candidates: [MeetingSpeaker: [SpeakerNameCandidate]]
    public var timeZone: TimeZone
    public init(title: String? = nil, app: String? = nil, startedAt: Date, perceivedGender: Bool = true,
                candidates: [MeetingSpeaker: [SpeakerNameCandidate]] = [:], timeZone: TimeZone = .current) {
        self.title = title; self.app = app; self.startedAt = startedAt; self.perceivedGender = perceivedGender
        self.candidates = candidates; self.timeZone = timeZone
    }
}

public enum SpeakerDescriptorBuilder {
    /// UserDefaults key for Settings › Meetings "Describe voices as probably man / woman" (default on).
    public static let perceivedGenderKey = "meeting.speakerLabels.perceivedGender"
    public static func perceivedGenderEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: perceivedGenderKey) as? Bool ?? true
    }

    // Thresholds (documented so the hover card can say what a word means).
    public static let lowPitchBelow: Float = 145, highPitchAbove: Float = 195
    public static let probablyManBelow: Float = 155, probablyWomanAbove: Float = 175
    public static let fastWPM = 170.0, slowWPM = 115.0
    public static let loudnessBandDB: Float = 6

    /// Per-speaker aggregate of the chunks assigned to them.
    struct Acoustic {
        var system = 0.0, mic = 0.0
        var levels: [Float] = [], dynamics: [Float] = [], f0: [Float] = []
        var bestChunk: (TimeInterval, Float)?
    }

    /// Chunks → speakers by overlap with the (final) transcript's utterances.
    static func assign(_ chunks: [ChunkAcoustics], to transcript: MeetingTranscript) -> [MeetingSpeaker: Acoustic] {
        var out: [MeetingSpeaker: Acoustic] = [:]
        for c in chunks {
            var best: (MeetingSpeaker, Double)?
            for u in transcript.utterances {
                let o = min(c.end, u.range.upperBound) - max(c.start, u.range.lowerBound)
                if o > 0, o > (best?.1 ?? 0) { best = (u.speaker, o) }
            }
            guard let (speaker, _) = best else { continue }
            var a = out[speaker] ?? Acoustic()
            let d = c.end - c.start
            if c.channel == .system { a.system += d } else { a.mic += d }
            if let l = c.levelDB { a.levels.append(l) }
            if let y = c.dynamicsDB { a.dynamics.append(y) }
            if let f = c.f0Hz, c.voicedFrames >= 3 { a.f0.append(f) }
            if let l = c.levelDB, l > (a.bestChunk?.1 ?? -200) { a.bestChunk = (c.start, l) }
            out[speaker] = a
        }
        return out
    }

    static func median(_ v: [Float]) -> Float? { v.isEmpty ? nil : v.sorted()[v.count / 2] }

    public static func describe(_ transcript: MeetingTranscript, chunks: [ChunkAcoustics],
                                context: SpeakerDescriptionContext) -> MeetingSpeakerDescriptors {
        let acoustic = assign(chunks, to: transcript)
        var order: [MeetingSpeaker] = []
        var spoken: [MeetingSpeaker: Double] = [:], words: [MeetingSpeaker: Int] = [:], questions: [MeetingSpeaker: Int] = [:]
        var first: [MeetingSpeaker: TimeInterval] = [:], last: [MeetingSpeaker: TimeInterval] = [:]
        var texts: [MeetingSpeaker: [String]] = [:]
        for u in transcript.utterances {
            if !order.contains(u.speaker) { order.append(u.speaker) }
            spoken[u.speaker, default: 0] += max(0.1, u.range.upperBound - u.range.lowerBound)
            words[u.speaker, default: 0] += u.text.split(whereSeparator: \.isWhitespace).count
            questions[u.speaker, default: 0] += Self.questionCount(u.text)
            first[u.speaker] = min(first[u.speaker] ?? .infinity, u.range.lowerBound)
            last[u.speaker] = max(last[u.speaker] ?? 0, u.range.upperBound)
            texts[u.speaker, default: []].append(u.text)
        }
        let total = spoken.values.reduce(0, +)
        let youLevel = acoustic[.you].flatMap { median($0.levels) }
        let youDynamics = acoustic[.you].flatMap { median($0.dynamics) }
        let allLevels = order.compactMap { acoustic[$0].flatMap { median($0.levels) } }
        let meetingLevel = median(allLevels)
        let mostQuestions = questions.max { $0.value < $1.value }.flatMap { $0.value > 0 ? $0.key : nil }
        let lastSpeaker = transcript.utterances.last?.speaker

        var descriptors: [SpeakerDescriptor] = []
        for s in order {
            var attrs: [SpeakerAttribute] = []
            let a = acoustic[s]
            if let c = context.candidates[s]?.max(by: { $0.confidence < $1.confidence }) {
                attrs.append(SpeakerAttribute(kind: .candidateName, text: "maybe \(c.name)", key: c.name.lowercased()))
            }
            if let a, let loc = location(a, app: context.app, youLevel: s == .you ? nil : youLevel,
                                         youDynamics: s == .you ? nil : youDynamics) {
                attrs.append(loc)
            }
            let f0 = a.flatMap { median($0.f0) }
            if let f0 {
                let band = f0 < lowPitchBelow ? "Deep voice" : (f0 > highPitchAbove ? "Higher voice" : "Mid-pitch voice")
                attrs.append(SpeakerAttribute(kind: .pitch, text: band))
                if context.perceivedGender {
                    if f0 < probablyManBelow { attrs.append(SpeakerAttribute(kind: .gender, text: "probably man")) }
                    else if f0 > probablyWomanAbove { attrs.append(SpeakerAttribute(kind: .gender, text: "probably woman")) }
                }
            }
            if let l = a.flatMap({ median($0.levels) }), let m = meetingLevel, allLevels.count > 1 {
                if l >= m + loudnessBandDB { attrs.append(SpeakerAttribute(kind: .loudness, text: "Loud voice")) }
                else if l <= m - loudnessBandDB { attrs.append(SpeakerAttribute(kind: .loudness, text: "Soft voice")) }
            }
            let secs = spoken[s] ?? 0
            if secs >= 10, let w = words[s] {
                let wpm = Double(w) / secs * 60
                if wpm >= fastWPM { attrs.append(SpeakerAttribute(kind: .pace, text: "Fast talker")) }
                else if wpm <= slowWPM { attrs.append(SpeakerAttribute(kind: .pace, text: "Slow, measured")) }
            }
            if let lo = first[s], let hi = last[s] {
                attrs.append(SpeakerAttribute(kind: .timeSpan, text: span(lo, hi, context)))
            }
            if let lang = language(texts[s] ?? []) { attrs.append(SpeakerAttribute(kind: .language, text: lang)) }
            if total > 0 {
                let share = Int((secs / total * 100).rounded())
                attrs.append(SpeakerAttribute(kind: .talkShare, text: "\(share)% of the talking", key: "\(share / 5)"))
            }
            if s == order.first { attrs.append(SpeakerAttribute(kind: .role, text: "spoke first")) }
            else if s == lastSpeaker { attrs.append(SpeakerAttribute(kind: .role, text: "spoke last")) }
            if let q = questions[s], q > 0 {
                attrs.append(SpeakerAttribute(kind: .questions, text: s == mostQuestions ? "asked the most questions" : "asked \(q) question\(q == 1 ? "" : "s")",
                                              key: s == mostQuestions ? "most" : "some"))
            }
            if let quote = quote(texts[s] ?? []) { attrs.append(SpeakerAttribute(kind: .quote, text: "“\(quote)”")) }
            let snippet = a?.bestChunk?.0 ?? first[s] ?? 0
            descriptors.append(SpeakerDescriptor(speaker: s.label, attributes: attrs, label: s.label,
                                                 firstHeard: first[s] ?? 0, lastHeard: last[s] ?? 0, snippetStart: snippet,
                                                 candidates: context.candidates[s] ?? []))
        }
        return MeetingSpeakerDescriptors(descriptors: label(descriptors))
    }

    // MARK: attributes

    static func location(_ a: Acoustic, app: String?, youLevel: Float?, youDynamics: Float?) -> SpeakerAttribute? {
        if a.system > a.mic {
            return SpeakerAttribute(kind: .location, text: app.map { "on the call (\($0))" } ?? "on the call", key: "call")
        }
        guard let level = median(a.levels) else { return nil }
        let dyn = median(a.dynamics) ?? 0
        let near: Bool, far: Bool
        if let youLevel {
            // Relative to the user, who sits at the laptop.
            near = level >= youLevel - 6 && dyn >= (youDynamics ?? dyn) - 6
            far = level <= youLevel - 12 || dyn <= (youDynamics ?? dyn) - 10
        } else {
            near = level >= -32 && dyn >= 20
            far = level <= -40 || dyn <= 12
        }
        if far { return SpeakerAttribute(kind: .location, text: "across the room", key: "far") }
        if near { return SpeakerAttribute(kind: .location, text: "near the laptop", key: "near") }
        return SpeakerAttribute(kind: .location, text: "in the room", key: "room")
    }

    static func span(_ lo: TimeInterval, _ hi: TimeInterval, _ c: SpeakerDescriptionContext) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB"); f.timeZone = c.timeZone; f.dateFormat = "HH:mm"
        let a = f.string(from: c.startedAt.addingTimeInterval(lo)), b = f.string(from: c.startedAt.addingTimeInterval(hi))
        return a == b ? a : "\(a)–\(b)"
    }

    static let questionStarts: Set<String> = ["what", "why", "how", "when", "where", "who", "which", "can", "could", "should",
                                              "would", "do", "does", "did", "is", "are", "will", "kya", "kyun", "kaise", "kab", "kahan"]

    static func questionCount(_ text: String) -> Int {
        let q = text.filter { $0 == "?" }.count
        if q > 0 { return q }
        let firstWord = text.split(whereSeparator: { !$0.isLetter }).first.map { $0.lowercased() } ?? ""
        return questionStarts.contains(firstWord) && text.split(separator: " ").count >= 4 ? 1 : 0
    }

    static func language(_ texts: [String]) -> String? {
        let all = texts.joined(separator: " ")
        guard all.split(separator: " ").count >= 8 else { return nil }
        let devanagari = all.unicodeScalars.filter { (0x0900...0x097F).contains($0.value) }.count
        let letters = max(1, all.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count)
        let r = NLLanguageRecognizer()
        r.processString(all)
        let hyps = r.languageHypotheses(withMaximum: 3)
        let hi = (hyps[.hindi] ?? 0) + Double(devanagari) / Double(letters)
        let en = hyps[.english] ?? 0
        if hi > 0.2 && (en > 0.2 || devanagari < letters / 2) && devanagari < letters * 9 / 10 { return "speaks Hindi-English" }
        if hi > 0.5 { return "speaks Hindi" }
        guard let dominant = r.dominantLanguage, dominant != .english, (hyps[dominant] ?? 0) > 0.6,
              let name = Locale(identifier: "en").localizedString(forLanguageCode: dominant.rawValue) else { return nil }
        return "speaks \(name)"
    }

    static let fillers: Set<String> = ["yeah", "yes", "ok", "okay", "right", "sure", "hmm", "um", "uh", "so", "and", "thanks",
                                       "thank", "you", "hi", "hello", "bye", "the", "a", "i", "it", "is", "that", "haan", "accha"]

    /// The first utterance with ≥ 3 non-filler words, cut to 8 words.
    static func quote(_ texts: [String]) -> String? {
        for t in texts {
            let words = t.split(whereSeparator: \.isWhitespace).map(String.init)
            let content = words.filter { !fillers.contains($0.lowercased().trimmingCharacters(in: .punctuationCharacters)) }
            guard content.count >= 3 else { continue }
            let cut = words.prefix(8).joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ",;:"))
            return words.count > 8 ? cut + "…" : cut
        }
        return nil
    }

    // MARK: label

    /// Attribute kinds a label may use, in order of preference when two tell speakers apart equally.
    static let labelKinds: [SpeakerAttributeKind] = [.candidateName, .pitch, .location, .gender, .loudness, .pace, .language,
                                                     .timeSpan, .questions, .role, .talkShare]

    /// How natural an attribute reads in a label: a voice or a place beats "23% of the talking"
    /// even when the share happens to separate more speakers.
    static let labelWeight: [SpeakerAttributeKind: Double] = [
        .candidateName: 1.5, .pitch: 1.2, .location: 1.2, .gender: 1.0, .loudness: 1.0, .pace: 0.9, .language: 0.9,
        .timeSpan: 0.8, .questions: 0.7, .role: 0.6, .talkShare: 0.4]

    /// Each speaker's label: greedily the attributes that distinguish them from the most speakers not
    /// yet told apart (weighted by `labelWeight`), 2–3 of them, unique within the meeting; "You"
    /// stays "You". A duplicate that survives gets the time span, then a number.
    static func label(_ ds: [SpeakerDescriptor]) -> [SpeakerDescriptor] {
        var out = ds
        for i in out.indices where out[i].speaker != MeetingSpeaker.you.label {
            let others = out.indices.filter { $0 != i }
            var undistinguished = Set(others)
            var chosen: [SpeakerAttribute] = []
            let pool = labelKinds.compactMap { k in out[i].attribute(k) }
            while chosen.count < 3 {
                var best: (SpeakerAttribute, Int, Double)?
                for a in pool where !chosen.contains(a) {
                    let n = undistinguished.filter { out[$0].attribute(a.kind)?.key != a.key }.count
                    let score = (Double(n) + 0.1) * (labelWeight[a.kind] ?? 0.5)
                    if score > (best?.2 ?? -1) { best = (a, n, score) }
                }
                guard let (a, n, _) = best else { break }
                if n == 0 && chosen.count >= 2 { break }
                chosen.append(a)
                undistinguished = undistinguished.filter { out[$0].attribute(a.kind)?.key == a.key }
                if undistinguished.isEmpty && chosen.count >= 2 { break }
            }
            // Read in a natural order: name, voice, gender, where, then the rest.
            chosen.sort { (labelKinds.firstIndex(of: $0.kind) ?? 99) < (labelKinds.firstIndex(of: $1.kind) ?? 99) }
            if chosen.isEmpty { continue }
            var text = chosen.map(\.text).joined(separator: " · ")
            if let first = text.first { text = first.uppercased() + text.dropFirst() }
            out[i].label = text
        }
        // Uniqueness within the meeting.
        var seen: [String: Int] = [:]
        for i in out.indices {
            let base = out[i].label
            if let n = seen[base] {
                if let span = out[i].attribute(.timeSpan), !base.contains(span.text) {
                    out[i].label = base + " · " + span.text
                } else {
                    out[i].label = base + " (\(n + 1))"
                }
                seen[base] = n + 1
            } else {
                seen[base] = 1
            }
        }
        return out
    }
}
