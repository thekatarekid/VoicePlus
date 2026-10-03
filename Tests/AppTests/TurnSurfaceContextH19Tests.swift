import Engine
import Foundation
import Injection
import Testing
import Shared
@testable import Pipeline
@testable import VoicePlusApp

/// H19 — near-caret context → repair evidence → the context repair stage with the real Double
/// Metaphone. Replays fixture 135111-082 ("whole to talk" → "hold-to-talk") and checks a corpus of
/// unrelated dictations against unrelated near-caret text for zero wrong swaps.
@Suite struct TurnSurfaceContextH19Tests {
    struct Fixture: Decodable {
        var before: String, after: String, raw: String, uncertain: [String], expected: String, expectedTerm: String
    }

    static func fixture() throws -> Fixture {
        let url = try #require(AppPaths.fixturesDirectory()).appendingPathComponent("context/regression/135111-082.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    /// Recognised words → spans; words listed as uncertain get confidence 0.3.
    static func spans(_ raw: String, uncertain: Set<String>) -> [TranscriptSpan] {
        raw.split(separator: " ").enumerated().map { i, w in
            let key = ContextRepairStage.Word(String(w)).key
            return TranscriptSpan(text: String(w), confidence: uncertain.contains(key) ? 0.3 : 0.92,
                                  audioRange: Double(i) * 0.4...Double(i) * 0.4 + 0.35, provenance: [.asr])
        }
    }

    static func near(_ before: String, after: String = "", secure: Bool = false) -> TurnSurfaceContext.NearCaretContext {
        .init(before: secure ? "" : before, after: secure ? "" : after, appName: "Claude",
              surfaceKind: secure ? .secure : .chatComposer, isSecure: secure)
    }

    static func run(_ spans: [TranscriptSpan], near: TurnSurfaceContext.NearCaretContext) -> ContextRepairStage.Outcome {
        guard let e = TurnSurfaceContext.repairEvidence(near) else { return .init(spans: spans, swaps: []) }
        return ContextRepairStage.repair(spans, evidence: e, phonetic: TurnSurfaceContext.phoneticCodes)
    }

    @Test func replay135111_082BecomesHoldToTalk() throws {
        let f = try Self.fixture()
        let spans = Self.spans(f.raw, uncertain: Set(f.uncertain))
        let out = Self.run(spans, near: Self.near(f.before, after: f.after))
        #expect(out.spans.renderedText == f.expected || out.spans.map(\.text).joined(separator: " ") == f.expected)
        #expect(out.swaps.count == 1)
        #expect(out.swaps.first?.written.hasPrefix(f.expectedTerm) == true)
        #expect(ConfidenceContract.verify(input: spans, output: out.spans).isEmpty)
        // The merged span covers exactly the replaced words' audio.
        let merged = try #require(out.spans.first { $0.text.hasPrefix("hold-to-talk") })
        #expect(merged.audioRange.lowerBound == spans[3].audioRange.lowerBound)
        #expect(merged.audioRange.upperBound == spans[5].audioRange.upperBound)
    }

    @Test func replayThroughTheStageContextAndStage() async throws {
        let f = try Self.fixture()
        let spans = Self.spans(f.raw, uncertain: Set(f.uncertain))
        var ctx = StageContext()
        try #require(TurnSurfaceContext.repairEvidence(Self.near(f.before))).write(into: &ctx)
        ContextRepairStage.install(phonetic: TurnSurfaceContext.phoneticCodes)
        let out = try await ContextRepairStage().process(spans, context: ctx)
        #expect(out.map(\.text).joined(separator: " ") == f.expected)
    }

    @Test func secureFieldGivesNoEvidence() throws {
        let f = try Self.fixture()
        #expect(TurnSurfaceContext.repairEvidence(Self.near(f.before, secure: true)) == nil)
        #expect(TurnSurfaceContext.repairEvidence(nil) == nil)
    }

    @Test func withoutTheTermOnScreenNothingChanges() throws {
        let f = try Self.fixture()
        let spans = Self.spans(f.raw, uncertain: Set(f.uncertain))
        let out = Self.run(spans, near: Self.near("Can you check why the shortcut drops the full stop? In case of "))
        #expect(out.swaps.isEmpty)
    }

    /// Stand-in for the 41-recording T-replay gate (recordings are not in the repo): ordinary
    /// dictations with every word uncertain, against busy unrelated near-caret text → 0 swaps.
    @Test func unrelatedDictationsMakeNoWrongSwaps() {
        let screens = [
            "Can you check why hold-to-talk drops the full stop? In case of ",
            "Deploy the KubernetesCluster with kubectl apply -f deploy.yaml and ping Kothari about OAuth tokens. ",
            "Meeting notes: Priya Raman, Q3 roadmap, VoicePlus onboarding, Qwen3.5-2B download flow, Settings > Models. ",
            "git commit -m 'fix hover pill' && swift test --filter TurnSurfaceContext ",
            "Dear Mr. Whitfield, thanks for the invoice INV-2041. The wire transfer will clear on Monday. ",
        ]
        let dictations = [
            "I will call you back in a minute.", "Whole wheat bread is on the list.", "Can you hold the door for me?",
            "Let's talk about it tomorrow.", "The pool is closed today.", "Please send the report by Friday.",
            "Cube root of eight is two.", "Ping me when you land.", "That was a full day.", "Stop the music please.",
            "We should hold off on the launch.", "Whole team is out on Monday.", "Ask her about the tokens.",
            "The wire was cut.", "Notes from the call are attached.", "Download it later.", "Apply the changes now.",
            "Commit to the plan.", "Hover over the button.", "The voice was clear.", "Thanks for the update.",
        ]
        var wrong: [String] = []
        for screen in screens {
            for d in dictations {
                let words = Set(d.split(separator: " ").map { ContextRepairStage.Word(String($0)).key })
                let out = Self.run(Self.spans(d, uncertain: words), near: Self.near(screen))
                wrong += out.swaps.map { "\(d) :: \($0.heard) -> \($0.written)" }
            }
        }
        #expect(wrong.isEmpty, "\(wrong)")
    }

    @Test func phoneticCodesAreDoubleMetaphone() {
        let c = DoubleMetaphone.encode("Kothari")
        #expect(TurnSurfaceContext.phoneticCodes("Kothari").first == c.primary)
    }

    @Test func augmentWritesEvidenceOnlyForTheStartApp() throws {
        let f = try Self.fixture()
        var r = TurnSurfaceContext.Resolved(bundleID: "com.anthropic.claudefordesktop", pid: 1,
                                            surface: SurfaceResolver.resolve(FieldContext(appBundleID: "com.anthropic.claudefordesktop", caret: .unknown).surfaceEvidence),
                                            shell: nil, shellDecided: false)
        r.nearCaret = Self.near(f.before)
        let ctx = TurnSurfaceContext.write(r, into: StageContext(), bundleID: "com.anthropic.claudefordesktop")
        #expect(ContextRepairEvidence.read(from: ctx)?.terms.contains { $0.text == "hold-to-talk" } == true)
        let other = TurnSurfaceContext.write(r, into: StageContext(), bundleID: "com.apple.TextEdit")
        #expect(other.extra[ContextRepairEvidence.extraKey] == nil)
    }
}
