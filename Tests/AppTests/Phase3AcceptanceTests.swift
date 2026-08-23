import Actions
import CoreGraphics
import Foundation
import Injection
import Pipeline
import Shared
import Testing
@testable import VoicePlusApp

/// Phase 3 acceptance — "move this over there" resolves both referents against a synthetic
/// timeline + mock hit-tester, including the two-display case; ambiguity goes through reverse
/// elicitation down to clarifying text; the resolver output lands in `StageContext.extra`
/// through the wired `UtteranceLander`.
@Suite("Phase 3 acceptance — deixis + referents")
struct Phase3AcceptanceTests {
    // Two displays side by side: main 1440×900 at origin, second 1440×900 to the right.
    static let displayA: UInt32 = 1
    static let displayB: UInt32 = 2

    /// "Report.pdf" icon on display 1, "Drafts folder" on display 2.
    static func elements() -> [ElementReference] {
        [
            ElementReference(id: "report", role: "AXImage", label: "Report.pdf",
                             frame: CGRect(x: 300, y: 400, width: 120, height: 90), displayID: displayA),
            ElementReference(id: "drafts", role: "AXGroup", label: "Drafts folder",
                             frame: CGRect(x: 1900, y: 300, width: 160, height: 120), displayID: displayB),
        ]
    }

    /// "move this over there" — word-level spans on the utterance clock (seconds from start).
    static func spans() -> [TranscriptSpan] {
        [
            TranscriptSpan(text: "move", confidence: 0.95, audioRange: 0.0...0.2),
            TranscriptSpan(text: "this", confidence: 0.94, audioRange: 0.25...0.45),
            TranscriptSpan(text: "over", confidence: 0.95, audioRange: 0.5...0.7),
            TranscriptSpan(text: "there", confidence: 0.93, audioRange: 0.75...0.95),
        ]
    }

    /// Service with capture aligned at instant 0, so timeline instants == audio seconds.
    static func service(elements: [ElementReference]) -> DeixisService {
        let service = DeixisService(hitTester: MockAXHitTester(elements: elements))
        service.beginCapture(at: 0)
        return service
    }

    @Test func moveThisOverThereResolvesBothReferentsAcrossTwoDisplays() {
        let service = Self.service(elements: Self.elements())
        // Pointer hovered the report while saying "this" (mid 0.35), then flew to display 2
        // for "there" (mid 0.85). Gesture lead is 80 ms; tolerance 0.35 s.
        service.timeline.append(TimelineEvent(timestamp: 0.30,
            kind: .pointerMove(GlobalPoint(x: 350, y: 440, displayID: Self.displayA))))
        service.timeline.append(TimelineEvent(timestamp: 0.72,
            kind: .pointerMove(GlobalPoint(x: 1950, y: 350, displayID: Self.displayB))))

        let (bindings, _) = service.resolve(spans: Self.spans())
        #expect(bindings.count == 2)

        let this = bindings.first(where: { $0.word == "this" })
        let there = bindings.first(where: { $0.word == "there" })
        #expect(this?.reference?.label == "Report.pdf")
        #expect(this?.reference?.displayID == Self.displayA)
        #expect(this?.isAmbiguous == false)
        #expect(there?.reference?.label == "Drafts folder")
        #expect(there?.reference?.displayID == Self.displayB)
        #expect(there?.isAmbiguous == false)

        // The pipeline-facing context line names both.
        let ctx = service.augment(Self.spans(), StageContext())
        let line = ctx.extra[DeixisService.contextLineKey] ?? ""
        #expect(line.contains("Report.pdf"))
        #expect(line.contains("Drafts folder"))
        #expect(line.contains("@display 2"))
        #expect(service.actContextLines.count == 2)
    }

    @Test func inkStrokeWinsOverPointerAndBundlesCoveredElements() {
        let service = Self.service(elements: Self.elements())
        // A circle drawn around the report while saying "this": stroke points inside ±0.6 s.
        let strokeID = UUID()
        for (i, p) in [(300.0, 400.0), (420.0, 400.0), (420.0, 490.0), (300.0, 490.0)].enumerated() {
            service.timeline.append(TimelineEvent(timestamp: 0.2 + Double(i) * 0.05,
                kind: .strokePoint(strokeID: strokeID, GlobalPoint(x: p.0, y: p.1, displayID: Self.displayA), pressure: 1)))
        }
        let (bindings, _) = service.resolve(spans: Self.spans())
        let this = bindings.first(where: { $0.word == "this" })
        guard case .region(let region)? = this?.reference else {
            Issue.record("expected a region reference from the ink stroke, got \(String(describing: this?.reference))")
            return
        }
        #expect(region.elements.map(\.id).contains("report"))
        #expect(this?.confidence == 0.9)
    }

    @Test func conversationalReferentsResolvePronounAndArtifact() {
        let service = Self.service(elements: [])
        service.participants = StaticReferentContext(
            people: ContextParticipants([
                Participant(name: "Jane Park", gender: .feminine, salience: 0.9),
                Participant(name: "Marcus Cole", gender: .masculine, salience: 0.8),
            ]),
            artifacts: [])
        service.artifacts = StaticReferentContext(
            people: ContextParticipants(),
            artifacts: [VisibleArtifact(title: "Q3 Strategy.key", kind: .deck, salience: 0.9)])

        let spans = [
            TranscriptSpan(text: "send", confidence: 0.9, audioRange: 0.0...0.2),
            TranscriptSpan(text: "her", confidence: 0.9, audioRange: 0.2...0.4),
            TranscriptSpan(text: "the", confidence: 0.9, audioRange: 0.4...0.5),
            TranscriptSpan(text: "deck", confidence: 0.9, audioRange: 0.5...0.7),
        ]
        let (_, referents) = service.resolve(spans: spans)
        #expect(referents.count == 2)
        #expect(referents.contains { $0.resolved?.label == "Jane Park" })
        #expect(referents.contains { $0.resolved?.label == "Q3 Strategy.key" })

        let ctx = service.augment(spans, StageContext())
        #expect(ctx.extra[DeixisService.contextLineKey]?.contains("Jane Park") == true)
    }

    @Test func ambiguousBindingRunsReverseElicitationToClarifyingText() {
        // Two near-identical buttons: pointer lands between them → ambiguous.
        let twins = [
            ElementReference(id: "left", role: "AXButton", label: "Send",
                             frame: CGRect(x: 100, y: 100, width: 60, height: 24), displayID: Self.displayA),
            ElementReference(id: "right", role: "AXButton", label: "Send later",
                             frame: CGRect(x: 168, y: 100, width: 60, height: 24), displayID: Self.displayA),
        ]
        let service = Self.service(elements: twins)
        var states: [ElicitationState] = []
        service.onElicitationChange = { states.append($0) }

        service.timeline.append(TimelineEvent(timestamp: 0.30,
            kind: .pointerMove(GlobalPoint(x: 164, y: 90, displayID: Self.displayA))))
        let spans = [
            TranscriptSpan(text: "click", confidence: 0.9, audioRange: 0.0...0.2),
            TranscriptSpan(text: "this", confidence: 0.9, audioRange: 0.25...0.45),
        ]
        _ = service.augment(spans, StageContext())

        guard case .prompting(let prompt)? = states.last else {
            Issue.record("expected .prompting, got \(String(describing: states.last))")
            return
        }
        #expect(prompt.question == "which one?")
        #expect(prompt.candidates.count == 2)

        // Nobody answers: the deadline tick falls back to clarifying text for the pill.
        let state = service.elicit(.tick(now: prompt.deadline + 0.1))
        guard case .timedOut(let clarifying, _) = state else {
            Issue.record("expected .timedOut, got \(state)")
            return
        }
        #expect(clarifying.contains("Send"))
        #expect(clarifying.lowercased().contains("which one"))
    }

    @Test func pointAnswerResolvesElicitation() {
        let twins = [
            ElementReference(id: "left", role: "AXButton", label: "Send",
                             frame: CGRect(x: 100, y: 100, width: 60, height: 24), displayID: Self.displayA),
            ElementReference(id: "right", role: "AXButton", label: "Send later",
                             frame: CGRect(x: 168, y: 100, width: 60, height: 24), displayID: Self.displayA),
        ]
        let service = Self.service(elements: twins)
        service.timeline.append(TimelineEvent(timestamp: 0.30,
            kind: .pointerMove(GlobalPoint(x: 164, y: 90, displayID: Self.displayA))))
        let spans = [TranscriptSpan(text: "this", confidence: 0.9, audioRange: 0.25...0.45)]
        let (bindings, _) = service.resolve(spans: spans)
        guard let ambiguous = bindings.first, ReverseElicitation.needsElicitation(ambiguous) else {
            Issue.record("expected an ambiguous binding")
            return
        }
        service.ask(about: ambiguous, at: 1.0)
        let state = service.elicit(.point(GlobalPoint(x: 110, y: 110, displayID: Self.displayA), now: 1.5))
        guard case .resolved(let chosen, _) = state else {
            Issue.record("expected .resolved, got \(state)")
            return
        }
        #expect(chosen.label == "Send")
    }

    @Test func landerInjectsContextLineThroughAugmenter() async throws {
        let system = MockSystemAccess()
        let lander = UtteranceLander(pipeline: PipelineRunner.standard(), injector: TextInjector(system: system),
                                     system: system, repair: nil, flags: .inMemory(), database: nil)
        let service = Self.service(elements: Self.elements())
        service.timeline.append(TimelineEvent(timestamp: 0.30,
            kind: .pointerMove(GlobalPoint(x: 350, y: 440, displayID: Self.displayA))))
        var seenContext: StageContext?
        lander.contextAugmenter = { spans, ctx in
            let augmented = service.augment(spans, ctx)
            seenContext = augmented
            return augmented
        }
        let result = await lander.land(Self.spans(), startedAt: Date(), focus: system.frontmostApp())
        #expect(result.landed)
        #expect(seenContext?.extra[DeixisService.contextLineKey]?.contains("Report.pdf") == true)
    }
}
