import Foundation
import Shared
#if canImport(EventKit)
import EventKit
#endif

// V5 M11 — name hints for a meeting's speakers. Every source yields candidates with a confidence;
// they are fused per speaker and shown only as suggestions ("maybe Priya") — never applied:
//   * calendar attendees (EventKit, read-only with access already granted): the meeting's invitees
//     are the vocabulary; in a 1:1 the one other attendee is a direct candidate;
//   * active-speaker highlight in Zoom / Meet / Teams (Accessibility: the name label of the
//     highlighted tile), sampled once a second while the meeting runs and time-correlated with the
//     final transcript's speakers. OCR is only a fallback hook for when the user opted into Screen
//     Recording; none ships here;
//   * names addressed in the transcript ("Thanks, Priya" → the next speaker; "I'm Priya" → this one),
//     person-typed by GLiNER2 when its weights are on disk, else the attendee / library / heuristic list;
//   * lip activity (LR1): a non-"You" speaker whose talk lines up with the user's moving lips is
//     probably the user.
// Screen and transcript text is data, never instructions: only names are taken from it.

/// What the call app shows as the active speaker right now (nil when nothing is highlighted).
public protocol ActiveSpeakerSource: Sendable {
    func activeSpeaker() -> ActiveSpeakerReading?
}

public struct ActiveSpeakerReading: Equatable, Sendable {
    public var name: String
    /// "Zoom", "Meet", "Teams".
    public var app: String
    public init(name: String, app: String) { self.name = name; self.app = app }
}

/// Attendee names of a calendar event (the user excluded).
public protocol MeetingAttendeeSource: Sendable {
    func attendees(of event: CalendarMeeting) -> [String]
}

/// Lip activity over a wall-clock interval (nil while the camera is off).
public protocol MeetingLipSource: Sendable {
    func lipActivity(from: Date, to: Date) -> LipActivity?
}

/// Active-speaker samples on the wall clock.
public final class ActiveSpeakerTimeline: @unchecked Sendable {
    public struct Sample: Equatable, Sendable { public var at: Date; public var reading: ActiveSpeakerReading }
    private let lock = NSLock()
    private var samples: [Sample] = []
    private var timer: DispatchSourceTimer?
    public let source: any ActiveSpeakerSource
    public let interval: TimeInterval

    public init(source: any ActiveSpeakerSource, interval: TimeInterval = 1) {
        self.source = source; self.interval = interval
    }

    public func record(_ reading: ActiveSpeakerReading?, at date: Date = Date()) {
        guard let reading else { return }
        lock.withLock { samples.append(Sample(at: date, reading: reading)); if samples.count > 20_000 { samples.removeFirst(5_000) } }
    }

    public var all: [Sample] { lock.withLock { samples } }

    public func start() {
        lock.withLock {
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            t.schedule(deadline: .now(), repeating: interval)
            t.setEventHandler { [weak self] in guard let self else { return }; self.record(self.source.activeSpeaker()) }
            t.resume()
            timer = t
        }
    }

    public func stop() { lock.withLock { timer?.cancel(); timer = nil } }
    deinit { timer?.cancel() }
}

public final class MeetingNameHints: SpeakerNameHinting, @unchecked Sendable {
    public let attendees: (any MeetingAttendeeSource)?
    public let timeline: ActiveSpeakerTimeline?
    public let typer: (any EntityTypeClassifier)?
    public let lips: (any MeetingLipSource)?
    /// Known people (voiceprint library, contacts) — names the addressed-name pass may accept.
    public let knownNames: @Sendable () -> [String]

    public init(attendees: (any MeetingAttendeeSource)? = nil, activeSpeaker: (any ActiveSpeakerSource)? = nil,
                typer: (any EntityTypeClassifier)? = nil, lips: (any MeetingLipSource)? = nil,
                knownNames: @escaping @Sendable () -> [String] = { [] }) {
        self.attendees = attendees
        self.timeline = activeSpeaker.map { ActiveSpeakerTimeline(source: $0) }
        self.typer = typer; self.lips = lips; self.knownNames = knownNames
    }

    public func meetingProgressed() { timeline?.start() }

    public var callApp: String? {
        let apps = timeline?.all.map(\.reading.app) ?? []
        return Dictionary(grouping: apps, by: { $0 }).max { $0.value.count < $1.value.count }?.key
    }

    public func candidates(for record: MeetingRecord, directory: URL) async -> [MeetingSpeaker: [SpeakerNameCandidate]] {
        timeline?.stop()
        let invitees = record.event.flatMap { e in attendees?.attendees(of: e) } ?? []
        var all: [[MeetingSpeaker: [SpeakerNameCandidate]]] = []
        all.append(Self.calendar(record.transcript, attendees: invitees))
        if let samples = timeline?.all, !samples.isEmpty {
            all.append(Self.activeSpeaker(record.transcript, samples: samples, origin: record.startedAt))
        }
        let vocabulary = invitees + knownNames()
        all.append(await Self.addressed(record.transcript, vocabulary: vocabulary, typer: typer))
        if let lips { all.append(Self.lips(record.transcript, origin: record.startedAt, source: lips)) }
        return Self.fuse(all, attendees: invitees)
    }

    // MARK: sources

    /// 1:1 — one other attendee, one other speaker → that attendee (0.6). Otherwise invitees only
    /// confirm names other sources propose (`fuse`).
    public static func calendar(_ t: MeetingTranscript, attendees: [String]) -> [MeetingSpeaker: [SpeakerNameCandidate]] {
        let others = Set(t.utterances.map(\.speaker)).subtracting([.you])
        guard attendees.count == 1, others.count == 1, let s = others.first else { return [:] }
        return [s: [SpeakerNameCandidate(name: attendees[0], confidence: 0.6, source: "calendar")]]
    }

    /// For each speaker, the share of their speech during which the call app highlighted a name
    /// (samples within their utterances, ±0.5 s for the highlight's lag); ≥ 3 samples and ≥ 40 %.
    public static func activeSpeaker(_ t: MeetingTranscript, samples: [ActiveSpeakerTimeline.Sample],
                                     origin: Date) -> [MeetingSpeaker: [SpeakerNameCandidate]] {
        var counts: [MeetingSpeaker: [String: Int]] = [:], totals: [MeetingSpeaker: Int] = [:]
        for s in samples {
            let t0 = s.at.timeIntervalSince(origin)
            guard let u = t.utterances.first(where: { t0 >= $0.range.lowerBound - 0.5 && t0 <= $0.range.upperBound + 0.5 }) else { continue }
            counts[u.speaker, default: [:]][s.reading.name, default: 0] += 1
            totals[u.speaker, default: 0] += 1
        }
        var out: [MeetingSpeaker: [SpeakerNameCandidate]] = [:]
        for (speaker, names) in counts where speaker != .you {
            let total = Double(totals[speaker] ?? 1)
            for (name, n) in names where n >= 3 && Double(n) / total >= 0.4 {
                out[speaker, default: []].append(SpeakerNameCandidate(name: name, confidence: 0.9 * Double(n) / total, source: "active speaker"))
            }
        }
        return out
    }

    static let addressCues = ["thanks", "thank you", "hi", "hey", "hello", "over to you", "go ahead", "welcome", "sorry", "bye"]
    static let introCues = ["i'm", "i am", "this is", "my name is", "mera naam"]

    static func regex(_ cues: [String]) -> NSRegularExpression {
        let alt = cues.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        return try! NSRegularExpression(pattern: "(?i:\\b(?:\(alt))\\b)[ ,]+(\\p{Lu}[\\p{L}'-]+)")
    }
    static let addressRegex = regex(addressCues)
    static let introRegex = regex(introCues)
    /// "Priya, what…" (leading) and "…, Priya?" (trailing question).
    static let leadingRegex = try! NSRegularExpression(pattern: "^(\\p{Lu}[\\p{L}'-]+),")
    static let trailingRegex = try! NSRegularExpression(pattern: ",\\s*(\\p{Lu}[\\p{L}'-]+)\\s*\\?\\s*$")

    /// Names in the transcript: "Thanks, Priya" / "Priya, what do you think?" / "…, Priya?" address
    /// the next (different) speaker (0.35 each); "I'm Priya" names the speaker (0.6).
    public static func addressed(_ t: MeetingTranscript, vocabulary: [String],
                                 typer: (any EntityTypeClassifier)?) async -> [MeetingSpeaker: [SpeakerNameCandidate]] {
        let known = Set(vocabulary.flatMap { full in [full.lowercased()] + full.split(separator: " ").map { $0.lowercased() } })
        var found: [(index: Int, name: String, intro: Bool)] = []
        for (i, u) in t.utterances.enumerated() {
            for (name, intro) in mentions(u.text) { found.append((i, name, intro)) }
        }
        guard !found.isEmpty else { return [:] }
        if let typer {
            await typer.prepare(Array(Set(found.map(\.name))), context: t.utterances.map(\.text).joined(separator: "\n"))
        }
        var out: [MeetingSpeaker: [SpeakerNameCandidate]] = [:]
        for f in found {
            let isPerson = known.contains(f.name.lowercased()) || typer?.cachedType(for: f.name) == .person
            guard isPerson else { continue }
            let speaker = t.utterances[f.index].speaker
            if f.intro {
                out[speaker, default: []].append(SpeakerNameCandidate(name: f.name, confidence: 0.6, source: "introduced"))
            } else if let next = t.utterances[(f.index + 1)...].first(where: { $0.speaker != speaker }) {
                out[next.speaker, default: []].append(SpeakerNameCandidate(name: f.name, confidence: 0.35, source: "addressed"))
            }
        }
        out[.you] = nil
        return out
    }

    /// Capitalised names in vocative / self-introduction position (bool: self-introduction).
    static func mentions(_ text: String) -> [(String, Bool)] {
        let ns = text as NSString, all = NSRange(location: 0, length: ns.length)
        func names(_ re: NSRegularExpression) -> [String] {
            re.matches(in: text, range: all).map { ns.substring(with: $0.range(at: 1)) }
        }
        var out = names(introRegex).map { ($0, true) }
        out += (names(addressRegex) + names(leadingRegex) + names(trailingRegex)).map { ($0, false) }
        let stop: Set<String> = ["I", "We", "You", "So", "And", "But", "Okay", "OK", "Yes", "No", "Thanks", "Hi", "Hey", "Hello",
                                 "Sorry", "Well", "Right", "Great", "Everyone", "All", "Guys", "Team", "There", "Going", "Not", "Here"]
        return out.filter { !stop.contains($0.0) && $0.0.count >= 2 }
    }

    /// The user's moving lips during a non-"You" speaker's talk (≥ 60 % of their judged time) → "You".
    public static func lips(_ t: MeetingTranscript, origin: Date, source: any MeetingLipSource) -> [MeetingSpeaker: [SpeakerNameCandidate]] {
        var yes: [MeetingSpeaker: Double] = [:], judged: [MeetingSpeaker: Double] = [:]
        for u in t.utterances where u.speaker != .you {
            guard let a = source.lipActivity(from: origin.addingTimeInterval(u.range.lowerBound),
                                             to: origin.addingTimeInterval(u.range.upperBound)),
                  let score = a.decisionScore else { continue }
            let d = u.range.upperBound - u.range.lowerBound
            judged[u.speaker, default: 0] += d
            if score >= 0.5 { yes[u.speaker, default: 0] += d }
        }
        var out: [MeetingSpeaker: [SpeakerNameCandidate]] = [:]
        for (s, j) in judged where j > 0 {
            let share = (yes[s] ?? 0) / j
            if share >= 0.6 { out[s] = [SpeakerNameCandidate(name: MeetingSpeaker.you.label, confidence: 0.8 * share, source: "lips")] }
        }
        return out
    }

    /// Per speaker and name: noisy-OR of the sources' confidences, × 1.2 when the name is an invitee
    /// (≤ 0.95); a name keeps only the speaker it fits best; top 3 per speaker.
    public static func fuse(_ parts: [[MeetingSpeaker: [SpeakerNameCandidate]]], attendees: [String]) -> [MeetingSpeaker: [SpeakerNameCandidate]] {
        let invitees = Set(attendees.flatMap { full in [full.lowercased()] + full.split(separator: " ").map { $0.lowercased() } })
        var miss: [MeetingSpeaker: [String: (Double, Set<String>, String)]] = [:]
        for part in parts {
            for (s, cs) in part {
                for c in cs {
                    let key = c.name.lowercased()
                    var (m, sources, display) = miss[s]?[key] ?? (1, [], c.name)
                    m *= (1 - min(0.99, max(0, c.confidence)))
                    sources.insert(c.source)
                    if c.name.count > display.count { display = c.name }
                    miss[s, default: [:]][key] = (m, sources, display)
                }
            }
        }
        var scored: [(MeetingSpeaker, SpeakerNameCandidate)] = []
        for (s, names) in miss {
            for (key, (m, sources, display)) in names {
                var conf = 1 - m
                if invitees.contains(key) { conf = min(0.95, conf * 1.2) }
                scored.append((s, SpeakerNameCandidate(name: display, confidence: conf, source: sources.sorted().joined(separator: "+"))))
            }
        }
        var bestSpeaker: [String: (MeetingSpeaker, Double)] = [:]
        for (s, c) in scored where c.name != MeetingSpeaker.you.label {
            let k = c.name.lowercased()
            if c.confidence > (bestSpeaker[k]?.1 ?? -1) { bestSpeaker[k] = (s, c.confidence) }
        }
        var out: [MeetingSpeaker: [SpeakerNameCandidate]] = [:]
        for (s, c) in scored {
            if c.name != MeetingSpeaker.you.label, bestSpeaker[c.name.lowercased()]?.0 != s { continue }
            out[s, default: []].append(c)
        }
        for s in out.keys { out[s] = Array(out[s]!.sorted { $0.confidence > $1.confidence }.prefix(3)) }
        return out
    }
}

#if canImport(EventKit)
/// The event's attendees through EventKit — only with full access already granted; never prompts.
public struct EventKitMeetingAttendees: MeetingAttendeeSource {
    public init() {}
    public func attendees(of event: CalendarMeeting) -> [String] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        let store = EKEventStore()
        guard let e = store.event(withIdentifier: event.id) else { return [] }
        return (e.attendees ?? []).compactMap { a in
            guard !a.isCurrentUser, let n = a.name, !n.contains("@") else { return nil }
            return n
        }
    }
}
#endif

/// GLiNER2 person typing for the addressed-name pass, loaded through `ModelResidency` on first use
/// and only when its weights are already on disk (`GLiNER2EntityTyper.load`); the heuristic answers
/// otherwise.
public final class LazyPersonTyper: EntityTypeClassifier, @unchecked Sendable {
    private let lock = NSLock()
    private var model: GLiNER2EntityTyper?
    private var tried = false
    private let heuristic: HeuristicEntityTyper
    private let load: @Sendable () async -> GLiNER2EntityTyper?

    public init(people: [String] = [], load: @escaping @Sendable () async -> GLiNER2EntityTyper? = { await GLiNER2EntityTyper.load() }) {
        self.heuristic = HeuristicEntityTyper(people: people); self.load = load
    }

    public var isAvailable: Bool { true }

    public func cachedType(for candidate: String) -> EntityType? {
        LayeredEntityTyper(model: lock.withLock { model }, heuristic: heuristic).cachedType(for: candidate)
    }

    public func prepare(_ candidates: [String], context: String) async {
        if lock.withLock({ defer { tried = true }; return !tried }) {
            let m = await load()
            lock.withLock { model = m }
        }
        await LayeredEntityTyper(model: lock.withLock { model }, heuristic: heuristic).prepare(candidates, context: context)
    }
}
