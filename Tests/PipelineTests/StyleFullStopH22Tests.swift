import Testing
import Foundation
import Shared
@testable import Pipeline

/// H22 — the final full stop is kept in chat composers (hold-to-talk and hands-free alike):
/// ChatFormatter no longer lightens it, the style stage never drops it from a learned rate, the
/// learner does not learn "no periods" from text the pipeline stripped, and v1 profiles reset.
@Suite struct StyleFullStopH22Tests {
    static let slack = "com.tinyspeck.slackmacgap"

    static func spans(_ text: String, confidence: Float = 0.9) -> [TranscriptSpan] {
        text.split(separator: " ").enumerated().map { i, w in
            TranscriptSpan(text: String(w), confidence: confidence,
                           audioRange: Double(i) * 0.3...Double(i) * 0.3 + 0.3, provenance: [.asr])
        }
    }

    static func chatContext(selection: String? = nil, profile: StyleProfile? = nil) throws -> StageContext {
        var c = StageContext(register: .chat, appBundleID: slack)
        c.extra[FieldContext.Keys.surfaceKind] = SurfaceKind.chatComposer.id
        if let selection { c.extra[SurfacePresets.selectionKey] = SurfacePresets.encode(["chatComposer": selection]) }
        if let profile { c.extra[StyleStage.profileJSONKey] = try profile.encodedJSON() }
        return c
    }

    /// ChatFormatter then StyleStage, as the chat pipeline runs them.
    static func chat(_ text: String, context: StageContext, store: any StyleProfileStore = InMemoryStyleProfileStore()) async throws -> String {
        let formatted = try await ChatFormatter().process(spans(text), context: context)
        return try await StyleStage(store: store).process(formatted, context: context).renderedText
    }

    // MARK: ChatFormatter

    @Test func chatSingleSentenceKeepsFullStop() async throws {
        // B9016D68 "Pull it up." used to land as "Pull it up".
        let out = try await ChatFormatter().process(Self.spans("Pull it up."), context: try Self.chatContext())
        #expect(ChatFormatter.render(out) == "Pull it up.")
    }

    @Test func questionAndExclamationUnchanged() async throws {
        let ctx = try Self.chatContext()
        #expect(ChatFormatter.render(try await ChatFormatter().process(Self.spans("Can you check?"), context: ctx)) == "Can you check?")
        #expect(ChatFormatter.render(try await ChatFormatter().process(Self.spans("Ship it!"), context: ctx)) == "Ship it!")
    }

    @Test func lighteningIsOptInOnly() async throws {
        var ctx = try Self.chatContext()
        ctx.extra[ChatFormatter.lightenTerminalKey] = "true"
        #expect(ChatFormatter.render(try await ChatFormatter().process(Self.spans("Pull it up."), context: ctx)) == "Pull it up")
    }

    // MARK: StyleStage

    @Test func chatPipelineKeepsFullStopWithColdStartAndLearnedNoPeriod() async throws {
        #expect(try await Self.chat("Pull it up.", context: try Self.chatContext()).hasSuffix("up."))
        var learned = StyleProfile.coldStart(appBundleID: Self.slack, category: .chat)
        learned.sampleCount = 40; learned.terminalPeriodRate = 0
        #expect(try await Self.chat("Pull it up.", context: try Self.chatContext(profile: learned)).hasSuffix("up."))
        #expect(try await Self.chat("Can you check?", context: try Self.chatContext(profile: learned)).hasSuffix("check?"))
    }

    @Test func explicitCasualPresetStillDropsIt() async throws {
        // The user picked "Casual: lowercase, no closing period" — that choice is honoured.
        #expect(try await Self.chat("Pull it up.", context: try Self.chatContext(selection: "casual")) == "pull it up")
    }

    // MARK: Learner feedback loop

    @Test func acceptedStrippedTextDoesNotTeachNoPeriods() throws {
        let learner = StyleLearner(store: InMemoryStyleProfileStore())
        let cold = try learner.profile(for: Self.slack)
        var p = cold
        for i in 0..<30 { p = try learner.ingest(original: "pull it up \(i)", edited: "pull it up \(i)", bundleID: Self.slack) }
        #expect(p.terminalPeriodRate == cold.terminalPeriodRate)
        #expect(p.dictationCount == 30)
    }

    @Test func userRemovingOurPeriodStillTeaches() throws {
        let learner = StyleLearner(store: InMemoryStyleProfileStore())
        var p = try learner.profile(for: Self.slack)
        for i in 0..<12 { p = try learner.ingest(original: "Pull it up \(i).", edited: "pull it up \(i)", bundleID: Self.slack) }
        #expect(p.terminalPeriodRate < StyleStage.decisionThreshold)
    }

    @Test func endToEndLoopKeepsFullStop() async throws {
        // Many accepted landings, then the next one still keeps its period.
        let store = InMemoryStyleProfileStore()
        let learner = StyleLearner(store: store)
        let ctx = try Self.chatContext()
        for i in 0..<20 {
            let landed = try await Self.chat("Sounds good \(i).", context: ctx, store: store)
            try learner.ingest(original: landed, edited: landed, bundleID: Self.slack)
        }
        #expect(try await Self.chat("Pull it up.", context: ctx, store: store).hasSuffix("up."))
        #expect(try #require(try store.profile(for: Self.slack)).terminalPeriodRate >= StyleProfile.neutralPeriodRate)
    }

    // MARK: Reset of learned rates (schema v1 → v2)

    @Test func v1ProfileWithLearnedNoPeriodResetsToNeutral() throws {
        var old = StyleProfile.coldStart(appBundleID: Self.slack, category: .chat)
        old.version = 1; old.terminalPeriodRate = 0.04; old.sampleCount = 40; old.capitalizationRate = 0.1
        let back = try StyleProfile.decode(json: try old.encodedJSON())
        #expect(back.version == StyleProfile.schemaVersion)
        #expect(back.terminalPeriodRate == StyleProfile.neutralPeriodRate)
        #expect(back.capitalizationRate == 0.1) // only the period rate is reset
    }

    @Test func v1HighRateAndV2RowsAreUntouched() throws {
        var high = StyleProfile.coldStart(appBundleID: "m", category: .mail)
        high.version = 1; high.terminalPeriodRate = 0.9
        #expect(try StyleProfile.decode(json: try high.encodedJSON()).terminalPeriodRate == 0.9)
        var current = StyleProfile.coldStart(appBundleID: Self.slack, category: .chat)
        current.terminalPeriodRate = 0.1
        #expect(try StyleProfile.decode(json: try current.encodedJSON()).terminalPeriodRate == 0.1)
    }

    @Test func databaseRowResetsOnRead() throws {
        let db = try AppDatabase.inMemory()
        var old = StyleProfile.coldStart(appBundleID: Self.slack, category: .chat)
        old.version = 1; old.terminalPeriodRate = 0
        let key = DatabaseStyleProfileStore.key(for: Self.slack)
        try db.save(PersonaRecord(id: key, appBundleID: key, instructions: try old.encodedJSON()))
        let p = try #require(try DatabaseStyleProfileStore(database: db).profile(for: Self.slack))
        #expect(p.terminalPeriodRate == StyleProfile.neutralPeriodRate)
    }
}
