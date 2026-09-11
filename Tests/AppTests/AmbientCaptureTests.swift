import Engine
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// R8.1 — the opt-in and the speaker rule. V3 §8: "Ambient off by default, separate opt-in. When on:
/// transcript only, enrolled user only, seven-day retention, no sync. Other speakers discarded unless
/// broader capture is explicitly enabled."
///
/// The interesting assertions here are all about what does *not* happen: nothing is captured by
/// default, no switch implies another, and a machine that cannot identify a voice never claims one.
@Suite("Ambient opt-in and enrolled-speaker capture (V3 §8)")
struct AmbientCaptureTests {

    // MARK: Speaker fixtures — no microphone on this machine, so these are embeddings, not audio

    static func embedding(_ v: [Float]) -> SpeakerEmbedding {
        SpeakerEmbedding(vector: v, embedder: "test", metric: .cosine)
    }

    static var enrolledProfile: SpeakerProfile {
        SpeakerProfile(centroid: embedding([1, 0, 0, 0]), utteranceCount: 12, enrolledAt: Date())
    }

    /// Filtering "on", weights present, somebody enrolled — `SpeakerFilter.Status.active`.
    static var identifyingFilter: SpeakerFilter {
        SpeakerFilter(isOn: true, gate: SpeakerGate(profile: enrolledProfile), canIdentify: true)
    }

    static func gate(enabled: Bool = true, everySpeaker: Bool = false,
                     filter: SpeakerFilter = identifyingFilter) -> AmbientCaptureGate {
        AmbientCaptureGate(isEnabled: enabled, capturesEverySpeaker: everySpeaker, filter: filter)
    }

    static let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: Off by default, and behind its own switch

    @Test("ambient capture is off by default, with no settings written at all")
    func offByDefault() {
        #expect(AmbientCaptureSettings.isEnabled(nil) == false)
        #expect(AmbientCaptureSettings.isEnabled(InMemorySettingsStore()) == false)
        #expect(AmbientCaptureSettings.capturesEverySpeaker(InMemorySettingsStore()) == false)
        // And the gate refuses before it looks at anything else, including a voice it would allow.
        let decision = Self.gate(enabled: false).decide(text: "anything", verdict: .user(similarity: 0.99), at: Self.now)
        #expect(decision.discardReason == .captureOff)
        #expect(decision.kept == nil)
    }

    @Test("ambient capture, broader capture and audio retention are three separate switches")
    func threeDistinctSwitches() {
        let store = InMemorySettingsStore()
        #expect(Set(AmbientCaptureSettings.allKeys).count == AmbientCaptureSettings.allKeys.count,
                "two ambient switches share a key")
        #expect(AmbientCaptureSettings.enabledKey == "ambient.capture.enabled")
        #expect(AmbientCaptureSettings.everySpeakerKey == "ambient.capture.everySpeaker")
        // Audio retention is the *existing* recorder key, so ambient gets no second, quieter way to
        // start writing audio to disk.
        #expect(AmbientCaptureSettings.audioRetentionKey == UtteranceRecorder.defaultsKey)
        #expect(AmbientCaptureSettings.audioRetentionKey != AmbientCaptureSettings.enabledKey)
        #expect(AmbientCaptureSettings.retentionDaysKey == "ambient.retention.days")

        // Turning the Timeline on widens nothing and saves no audio.
        AmbientCaptureSettings.setEnabled(true, store: store)
        #expect(AmbientCaptureSettings.isEnabled(store))
        #expect(AmbientCaptureSettings.capturesEverySpeaker(store) == false)
        #expect(store.values[AmbientCaptureSettings.audioRetentionKey] == nil,
                "turning ambient capture on touched the audio-retention switch")

        // Widening capture does not turn capture on by itself either.
        let other = InMemorySettingsStore()
        AmbientCaptureSettings.setCapturesEverySpeaker(true, store: other)
        #expect(AmbientCaptureSettings.isEnabled(other) == false)
    }

    /// The switch used to write the `directedSpeech` feature flag — the hands-free experiment V3 §8
    /// says "stays off", and the flag `LatchController.isEnabled` reads. Turning on a transcript
    /// Timeline must not arm a hands-free path.
    @Test("the Privacy switch writes ambient.capture.enabled and never the directedSpeech flag")
    @MainActor func privacySwitchIsItsOwnKey() {
        let settings = InMemorySettingsStore()
        let flags = FeatureFlagService.inMemory()
        let model = PrivacySectionViewModel(settings: settings, flags: flags)

        #expect(model.ambientCapture == false, "ambient capture is on by default")
        model.ambientCapture = true
        #expect(model.ambientCapture)
        #expect(settings.bool(AmbientCaptureSettings.enabledKey) == true)
        #expect(flags.isEnabled(.directedSpeech) == false,
                "turning ambient capture on armed the hands-free experiment")

        #expect(model.capturesEverySpeaker == false)
        model.capturesEverySpeaker = true
        #expect(settings.bool(AmbientCaptureSettings.everySpeakerKey) == true)
        #expect(model.ambientCapture, "widening capture turned the opt-in off")

        model.ambientCapture = false
        #expect(AmbientCaptureSettings.isEnabled(settings) == false)
        #expect(flags.isEnabled(.directedSpeech) == false)
    }

    // MARK: Enrolled speaker only

    @Test("the enrolled voice is kept, and labelled as the user")
    func enrolledVoiceIsKept() throws {
        let decision = Self.gate().decide(text: "  what I said  ", verdict: .user(similarity: 0.9), at: Self.now)
        let entry = try #require(decision.kept)
        #expect(entry.text == "what I said", "the stored text was not trimmed")
        #expect(entry.speaker == .you)
        #expect(entry.sourceLabel == AmbientEntry.enrolledSource)
    }

    @Test("another voice is discarded, and so is a voice the filter could not confirm")
    func otherAndUncertainVoicesAreDiscarded() {
        let mismatch = Self.gate().decide(text: "a colleague talking", verdict: .other(similarity: 0.2), at: Self.now)
        #expect(mismatch.discardReason == .anotherVoice)
        #expect(mismatch.kept == nil, "another person's speech was stored")

        // Uncertain is not yes (V3 §8: "never silently save another person's speech").
        let uncertain = Self.gate().decide(text: "something short", verdict: .unknown, at: Self.now)
        #expect(uncertain.discardReason == .uncertainVoice)
        #expect(uncertain.kept == nil)
    }

    /// R3's `SpeakerFilter` is off by default and allows every voice when off — right for
    /// hold-to-talk, and exactly what ambient may not inherit.
    @Test("ambient requires identification even when speaker filtering is switched off")
    func filteringOffDoesNotMeanAmbientKeepsEveryone() {
        let off = SpeakerFilter(isOn: false, gate: SpeakerGate(profile: Self.enrolledProfile), canIdentify: true)
        #expect(off.status == .off)
        #expect(off.decide(.other(similarity: 0.1)).allowsInsertion, "R3's filter changed; this test's premise is stale")

        let ambient = Self.gate(filter: off)
        #expect(ambient.effectiveFilter.status == .active, "ambient did not evaluate the filter as if it were on")
        #expect(ambient.decide(text: "a colleague", verdict: .other(similarity: 0.1), at: Self.now).kept == nil,
                "ambient kept another voice because speaker filtering happened to be off")
        #expect(ambient.decide(text: "me", verdict: .user(similarity: 0.9), at: Self.now).kept?.speaker == .you)
    }

    @Test("no enrolled voice: nothing is captured, and the user is told why")
    func withoutEnrollmentNothingIsCaptured() {
        let unenrolled = SpeakerFilter(isOn: true, gate: SpeakerGate(profile: nil), canIdentify: true)
        let decision = Self.gate(filter: unenrolled).decide(text: "anyone", verdict: .unknown, at: Self.now)
        #expect(decision.discardReason == .notEnrolled)
        #expect(decision.discardReason?.message == SpeakerFilter.notEnrolledMessage)
        #expect(Self.gate(filter: unenrolled).statusMessage == SpeakerFilter.notEnrolledMessage)
    }

    /// The honesty rule. On this machine the WeSpeaker weights are absent, so `canIdentify` is false.
    /// That must never become "enrolled".
    @Test(".modelUnavailable is a discard and never silently becomes “enrolled”")
    func modelUnavailableIsNeverTreatedAsEnrolled() {
        let noWeights = SpeakerFilter(isOn: true, gate: SpeakerGate(profile: Self.enrolledProfile), canIdentify: false)
        #expect(noWeights.status == .modelUnavailable)

        let gate = Self.gate(filter: noWeights)
        for verdict: SpeakerGate.Verdict in [.user(similarity: 1), .other(similarity: 0), .unknown] {
            let decision = gate.decide(text: "words", verdict: verdict, at: Self.now)
            #expect(decision.kept == nil, "ambient stored speech with no way to identify the speaker")
            #expect(decision.discardReason == .speakerModelUnavailable)
            #expect(decision.discardReason?.message == SpeakerFilter.modelUnavailableMessage)
        }
        #expect(gate.statusMessage == SpeakerFilter.modelUnavailableMessage)

        // Broader capture keeps the speech, but still refuses to call it the enrolled user.
        let wide = Self.gate(everySpeaker: true, filter: noWeights)
        let kept = wide.decide(text: "words", verdict: .user(similarity: 1), at: Self.now).kept
        #expect(kept?.speaker != .you, "a machine that cannot identify voices labelled one as the user")
        #expect(kept?.sourceLabel == AmbientEntry.otherVoiceSource)
    }

    @Test("broader capture keeps other voices, and labels them as other voices")
    func broaderCaptureKeepsOthersAndLabelsThem() throws {
        let wide = Self.gate(everySpeaker: true)
        let other = try #require(wide.decide(text: "a colleague", verdict: .other(similarity: 0.1), at: Self.now).kept)
        #expect(other.speaker == .others(1))
        #expect(other.sourceLabel == AmbientEntry.otherVoiceSource)
        #expect(other.sourceLabel != AmbientEntry.enrolledSource, "another voice reads as if it were the user")

        let mine = try #require(wide.decide(text: "me", verdict: .user(similarity: 0.95), at: Self.now).kept)
        #expect(mine.speaker == .you)
    }

    @Test("silence is not an entry")
    func emptyTextIsDiscarded() {
        for text in ["", "   ", "\n\t "] {
            #expect(Self.gate().decide(text: text, verdict: .user(similarity: 1), at: Self.now).discardReason == .emptyText)
        }
    }

    /// Ambient must not invent a second vocabulary for a verdict R3 already named — a discard reason
    /// that drifted from the filter's would be a user-facing sentence nobody checked.
    @Test("every R3 suppression reason maps to exactly one ambient discard reason")
    func suppressionReasonsMapOneToOne() {
        var mapped: Set<AmbientDiscardReason> = []
        for reason in SpeakerFilter.SuppressionReason.allCases {
            let ambient = AmbientDiscardReason(reason)
            #expect(ambient.rawValue == reason.rawValue, "\(reason) got a second name")
            mapped.insert(ambient)
        }
        #expect(mapped.count == SpeakerFilter.SuppressionReason.allCases.count)
        #expect(AmbientDiscardReason(.modelUnavailable) == .speakerModelUnavailable)
        // The two reasons that are not about a speaker at all are the only extras.
        #expect(Set(AmbientDiscardReason.allCases).subtracting(mapped) == [.captureOff, .emptyText])
        #expect(AmbientDiscardReason.allCases.allSatisfy { !$0.message.isEmpty })
    }

    // MARK: Transcript only

    @Test("capture writes transcript and never audio, whatever the audio-retention switch says")
    func captureIsTranscriptOnly() throws {
        let suite = "r81-audio-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        UtteranceRecorder.setEnabled(true, defaults)
        #expect(AmbientCaptureSettings.retainsAudio(defaults), "the recorder switch did not take")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("r81-transcript-\(UUID().uuidString)", isDirectory: true)
        let store = AmbientTranscriptStore(meetings: MeetingStore(root: root),
                                          database: try AppDatabase.inMemory())
        try store.store(AmbientEntry(speaker: .you, text: "said out loud", capturedAt: Self.now))

        let written = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? [])
            .filter { !$0.hasDirectoryPath }
            .map(\.lastPathComponent)
        #expect(Set(written) == ["meeting.json", "meeting.md"], "ambient wrote \(written)")
        #expect(written.allSatisfy { !$0.hasSuffix(".wav") && !$0.hasSuffix(".caf") && !$0.hasSuffix(".m4a") },
                "ambient capture wrote audio")
        defaults.removePersistentDomain(forName: suite)
    }

    // MARK: Storage reuse

    @Test("ambient reuses the meeting store, in its own root so it is not listed as a meeting")
    func reusesMeetingStorageWithoutBecomingAMeeting() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("r81-reuse-\(UUID().uuidString)", isDirectory: true)
        let meetings = MeetingStore(root: root)
        let store = AmbientTranscriptStore(meetings: meetings, database: try AppDatabase.inMemory())
        try store.store(AmbientEntry(speaker: .you, text: "one", capturedAt: Self.now))
        try store.store(AmbientEntry(speaker: .others(1), text: "two", capturedAt: Self.now.addingTimeInterval(30)))

        // The same types, the same files, one record per day — no parallel transcript format.
        let records = meetings.list()
        #expect(records.count == 1)
        let record = try #require(records.first)
        #expect(record.transcript.utterances.map(\.text) == ["one", "two"])
        #expect(record.id.hasPrefix("ambient-"))
        #expect(record.labeler == "ambient")
        #expect(record.transcript.utterances.map(\.speaker) == [.you, .others(1)])

        // …and not in the Meetings root, so the Meetings section cannot list it.
        #expect(AmbientTranscriptStore.defaultRoot().lastPathComponent == "Ambient")
        #expect(AmbientTranscriptStore.defaultRoot() != MeetingStore().root,
                "ambient days would be listed by the Meetings section")
    }
}
