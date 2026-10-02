import Foundation
import Shared
import Testing
@testable import Engine

/// N14 — the rubric's spell list and screen terms reach the cleanup prompt's stage-context keys.
@Suite("Cleanup context lists (N14)")
struct CleanupContextListsN14Tests {
    static func ranked(_ kind: SurfaceKind) -> RankedContext {
        var candidates = ContextCandidates.dictionary([DictionaryEntry(term: "VoicePlus", origin: .personal),
                                                       DictionaryEntry(term: "Akash", origin: .contacts)])
        candidates.append(ContextCandidate(text: "Grafana", source: .screenNear, caretDistance: 10, onScreenNow: true))
        return ContextRubric.rank(candidates: candidates,
                                  surface: SurfaceResolution(kind: kind, confidence: 0.9, isWebArea: false, signals: []))
    }

    @Test func rubricListsAreWrittenWithoutContactsOffConversationalSurfaces() {
        var ctx = StageContext()
        ContextPromptKeys.writeRubricLists(Self.ranked(.terminal), into: &ctx)
        let spell = ctx.extra[ContextPromptKeys.spell] ?? ""
        let terms = ctx.extra[ContextPromptKeys.terms] ?? ""
        #expect(spell.contains("VoicePlus"))
        #expect(!(spell + terms).contains("Akash"))
        #expect((spell + terms).contains("Grafana"))
        #expect(ContextPromptKeys.spell == "context.spell" && ContextPromptKeys.terms == "context.terms")
    }

    @Test func noRubricRemovesStaleKeys() {
        var ctx = StageContext()
        ctx.extra[ContextPromptKeys.spell] = "stale"
        ctx.extra[ContextPromptKeys.terms] = "stale"
        ContextPromptKeys.writeRubricLists(nil, into: &ctx)
        #expect(ctx.extra[ContextPromptKeys.spell] == nil && ctx.extra[ContextPromptKeys.terms] == nil)
        ContextPromptKeys.writeRubricLists(.empty, into: &ctx)   // a tier-ranked list has no rubric output
        #expect(ctx.extra[ContextPromptKeys.spell] == nil)
    }

    @Test func sessionWritesRubricListsWhenWired() {
        let session = ContextPromptSession(harvester: ContextHarvester())
        session.rubric = { _ in Self.ranked(.chatComposer) }
        var ctx = StageContext()
        session.write(into: &ctx)
        #expect((ctx.extra[ContextPromptKeys.spell] ?? "").contains("VoicePlus"))
        session.rubric = nil
        session.write(into: &ctx)
        #expect(ctx.extra[ContextPromptKeys.spell] == nil)
    }
}
