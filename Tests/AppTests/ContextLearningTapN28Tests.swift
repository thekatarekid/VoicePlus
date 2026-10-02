import Engine
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// N28 verify — the live learning loop: the rubric closure remembers the turn's ranking and the
/// landed text records it once into the learner; secure / stale / empty turns are never recorded.
@Suite("N28 context learning tap (live wiring)")
struct ContextLearningTapN28Tests {
    private func surface(_ kind: SurfaceKind) -> SurfaceResolution {
        SurfaceResolution(kind: kind, confidence: 0.9, isWebArea: false, signals: [])
    }

    private func ranked(_ kind: SurfaceKind, now: Date) -> RankedContext {
        ContextRubric().ranked(candidates: [ContextCandidate(text: "Postgres", source: .correction, observedAt: now),
                                            ContextCandidate(text: "Kubernetes", source: .correction, observedAt: now)],
                               surface: surface(kind), now: now)
    }

    @Test func landedTurnIsRecordedOnceThroughTheRubricClosure() throws {
        let learner = SourceWeightLearner(fileURL: nil)
        let tap = ContextLearningTap(learner: learner, queue: nil)
        let now = Date()
        let rubric = BoostingWiring.rubricRanking(
            database: nil, learned: nil, surface: { [self] in surface(.codeEditor) },
            turnCandidates: { [ContextCandidate(text: "Postgres", source: .correction, observedAt: now)] },
            weights: nil, learning: tap)
        #expect(rubric(now)?.stableLayer.isEmpty == false)
        #expect(tap.land(finalText: "restart postgres now", app: "com.microsoft.VSCode", now: now))
        let stats = try #require(learner.snapshot.stats[SurfaceKind.codeEditor.id]?["correction"])
        #expect(stats.offered == 1 && stats.matched == 1)
        // Consumed: a second landing without a new ranking records nothing.
        #expect(!tap.land(finalText: "again postgres", now: now))
    }

    @Test func secureStaleAndEmptyTurnsAreNeverRecorded() {
        let learner = SourceWeightLearner(fileURL: nil)
        let tap = ContextLearningTap(learner: learner, maxAge: 60, queue: nil)
        let now = Date()
        tap.remember(ranked(.prose, now: now), surface: .secure, at: now)
        #expect(!tap.land(finalText: "postgres", now: now))
        tap.remember(ranked(.prose, now: now), surface: .prose, at: now)
        #expect(!tap.land(finalText: "postgres", now: now.addingTimeInterval(61)))
        tap.remember(ranked(.prose, now: now), surface: .prose, at: now)
        #expect(!tap.land(finalText: "   ", now: now))
        #expect(learner.snapshot.stats.isEmpty)
    }
}
