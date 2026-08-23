import Testing
import Foundation
import Shared
@testable import Pipeline

/// P1.7 T7 — style profile, learner, category table, stage, persistence, convergence.
@Suite struct StyleStageTests {
    static func spans(_ text: String, confidence: Float = 0.9) -> [TranscriptSpan] {
        text.split(separator: " ").enumerated().map { i, w in
            TranscriptSpan(text: String(w), confidence: confidence,
                           audioRange: Double(i) * 0.3...Double(i) * 0.3 + 0.3, provenance: [.asr])
        }
    }

    static func run(_ text: String, profile: StyleProfile, register: Utterance.Register = .prose,
                    confidence: Float = 0.9) async throws -> [TranscriptSpan] {
        var ctx = StageContext(register: register, appBundleID: profile.appBundleID)
        ctx.extra[StyleStage.profileJSONKey] = try profile.encodedJSON()
        return try await StyleStage().process(spans(text, confidence: confidence), context: ctx)
    }

    static let slack = "com.tinyspeck.slackmacgap", mail = "com.apple.mail"

    // MARK: Category table

    @Test func exactCategoryMatches() {
        #expect(AppCategoryTable.category(for: "com.apple.mail") == .mail)
        #expect(AppCategoryTable.category(for: "com.tinyspeck.slackmacgap") == .chat)
        #expect(AppCategoryTable.category(for: "com.microsoft.VSCode") == .code)
        #expect(AppCategoryTable.category(for: "com.googlecode.iterm2") == .terminal)
        #expect(AppCategoryTable.category(for: "com.apple.Notes") == .prose)
    }

    @Test func substringHeuristicsAndFallback() {
        #expect(AppCategoryTable.category(for: "org.example.FancyMail") == .mail)
        #expect(AppCategoryTable.category(for: "io.foo.terminal-pro") == .terminal)
        #expect(AppCategoryTable.category(for: "com.unknown.thing") == .prose)
        #expect(AppCategoryTable.category(for: nil) == .prose)
        #expect(AppCategoryTable.category(for: .email) == .mail)
    }

    // MARK: Profile + observation

    @Test func coldStartPriorsDifferByCategory() {
        let chat = StyleProfile.coldStart(appBundleID: "x", category: .chat)
        let mail = StyleProfile.coldStart(appBundleID: "x", category: .mail)
        #expect(chat.terminalPeriodRate < 0.3 && mail.terminalPeriodRate > 0.7)
        #expect(chat.capitalizationRate < mail.capitalizationRate)
        #expect(!chat.isConfident)
    }

    @Test func profileRoundTripsThroughJSON() throws {
        let p = StyleProfile.coldStart(appBundleID: Self.mail, category: .mail)
        let back = try StyleProfile.decode(json: try p.encodedJSON())
        #expect(back.appBundleID == p.appBundleID && back.category == .mail)
        #expect(abs(back.greetingRate - p.greetingRate) < 1e-9)
    }

    @Test func observeCapitalizationAndPeriod() {
        let o = StyleLearner.observe("Hi Bob. Let's ship it today.")
        #expect(o.capitalizedSentenceRate == 1 && o.hasTerminalPeriod && o.greeting == "Hi")
        #expect(o.wordCount == 6 && abs(o.avgSentenceLength - 3) < 1e-9)
    }

    @Test func observeLowercaseNoPeriod() {
        let o = StyleLearner.observe("on my way, be there in ten")
        #expect(o.capitalizedSentenceRate == 0 && !o.hasTerminalPeriod && o.greeting == nil)
        #expect(o.punctuationDensity > 0)
    }

    @Test func observeEllipsisIsNotTerminalPeriod() {
        #expect(!StyleLearner.observe("wait for it...").hasTerminalPeriod)
    }

    @Test func observeEmoji() {
        #expect(StyleLearner.observe("sounds good 🎉").hasEmoji)
        #expect(!StyleLearner.observe("sounds good").hasEmoji)
    }

    @Test func observeSignOffMultiline() {
        let o = StyleLearner.observe("Hi Sam,\nCan you review?\nThanks,\nAditya")
        #expect(o.greeting == "Hi" && o.signOff == "Thanks")
    }

    @Test func observeSignOffSingleLine() {
        #expect(StyleLearner.observe("can you review this thanks").signOff == "thanks")
        #expect(StyleLearner.observe("thanks").signOff == nil)
    }

    // MARK: Learner

    @Test func ingestIgnoresTinySamples() throws {
        let learner = StyleLearner(store: InMemoryStyleProfileStore())
        let before = try learner.profile(for: Self.slack)
        let after = try learner.ingest(original: "ok", edited: "ok", bundleID: Self.slack)
        #expect(after.sampleCount == before.sampleCount)
    }

    @Test func editedSamplesWeighMoreThanAccepted() throws {
        let store = InMemoryStyleProfileStore()
        let learner = StyleLearner(store: store)
        let a = try learner.ingest(original: "Ship it today.", edited: "Ship it today.", bundleID: "a")
        let b = try learner.ingest(original: "Ship it today.", edited: "ship it today", bundleID: "b")
        #expect(b.sampleCount > a.sampleCount)
        #expect(store.count == 2)
    }

    @Test func learnerPersistsToStore() throws {
        let store = InMemoryStyleProfileStore()
        try StyleLearner(store: store).ingest(original: "Hello there.", edited: "hello there", bundleID: Self.mail)
        let p = try #require(try store.profile(for: Self.mail))
        #expect(p.category == .mail && p.sampleCount > 3)
    }

    @Test func convergenceMailUserWritesCasually() throws {
        // Mail cold-start says "capitalize + period"; user consistently edits to lowercase/no period.
        let learner = StyleLearner(store: InMemoryStyleProfileStore())
        var p = try learner.profile(for: Self.mail)
        #expect(p.capitalizationRate > 0.7 && p.terminalPeriodRate > 0.7)
        for i in 0..<12 {
            p = try learner.ingest(original: "Draft number \(i) is ready.", edited: "draft number \(i) is ready", bundleID: Self.mail)
        }
        #expect(p.isConfident)
        #expect(p.capitalizationRate < 0.3, "rate was \(p.capitalizationRate)")
        #expect(p.terminalPeriodRate < 0.3, "rate was \(p.terminalPeriodRate)")
    }

    @Test func convergenceChatUserWritesFormally() throws {
        let learner = StyleLearner(store: InMemoryStyleProfileStore())
        var p = try learner.profile(for: Self.slack)
        #expect(p.terminalPeriodRate < 0.3)
        for i in 0..<12 {
            p = try learner.ingest(original: "draft \(i) is ready", edited: "Draft \(i) is ready.", bundleID: Self.slack)
        }
        #expect(p.capitalizationRate > 0.7 && p.terminalPeriodRate > 0.7)
    }

    @Test func convergenceIsMonotoneAndBounded() throws {
        let learner = StyleLearner(store: InMemoryStyleProfileStore())
        var last = try learner.profile(for: Self.mail).terminalPeriodRate
        for i in 0..<30 {
            let p = try learner.ingest(original: "Line \(i) here.", edited: "line \(i) here", bundleID: Self.mail)
            #expect(p.terminalPeriodRate <= last + 1e-9 && p.terminalPeriodRate >= 0)
            last = p.terminalPeriodRate
        }
        #expect(last < 0.1)
    }

    @Test func windowedMeanKeepsAdapting() throws {
        // After 100 lowercase samples, 40 capitalized ones must still move the rate well past 0.5.
        let learner = StyleLearner(store: InMemoryStyleProfileStore())
        for i in 0..<100 { try learner.ingest(original: "x", edited: "sample \(i) lower", bundleID: "z") }
        var p = try learner.profile(for: "z")
        #expect(p.capitalizationRate < 0.05)
        for i in 0..<40 { p = try learner.ingest(original: "x", edited: "Sample \(i) upper.", bundleID: "z") }
        #expect(p.capitalizationRate > 0.5, "rate was \(p.capitalizationRate)")
    }

    @Test func learnsPreferredGreetingAndSignOff() throws {
        let learner = StyleLearner(store: InMemoryStyleProfileStore())
        let p = try learner.ingest(original: "x", edited: "Hey Sam,\ncan you look?\nCheers,\nA", bundleID: Self.mail)
        #expect(p.preferredGreeting == "Hey" && p.preferredSignOff == "Cheers")
        #expect(p.greetingRate > 0.6)
    }

    // MARK: Stage — apply

    @Test func chatColdStartDropsPeriodAndLowercases() async throws {
        let p = StyleProfile.coldStart(appBundleID: Self.slack, category: .chat)
        let out = try await Self.run("Sounds good.", profile: p, register: .chat)
        #expect(out.joinedText == "sounds good")
        #expect(out.allSatisfy { $0.provenance.last == .style })
    }

    @Test func mailColdStartCapitalizesAndAddsPeriod() async throws {
        let p = StyleProfile.coldStart(appBundleID: Self.mail, category: .mail)
        let out = try await Self.run("see attached for the numbers", profile: p, register: .email)
        #expect(out.joinedText == "See attached for the numbers.")
    }

    @Test func learnedProfileOverridesColdStart() async throws {
        let learner = StyleLearner(store: InMemoryStyleProfileStore())
        var p = try learner.profile(for: Self.mail)
        for i in 0..<12 { p = try learner.ingest(original: "x", edited: "note \(i) for you", bundleID: Self.mail) }
        let out = try await Self.run("Sending the deck over.", profile: p, register: .email)
        #expect(out.joinedText == "sending the deck over")
    }

    @Test func questionAndExclamationAreUntouched() async throws {
        let p = StyleProfile.coldStart(appBundleID: Self.mail, category: .mail)
        #expect(try await Self.run("Are you coming?", profile: p).joinedText == "Are you coming?")
        #expect(try await Self.run("Let's go!", profile: p).joinedText == "Let's go!")
    }

    @Test func ellipsisAndAbbreviationsKeepTheirDots() async throws {
        let p = StyleProfile.coldStart(appBundleID: Self.slack, category: .chat)
        #expect(try await Self.run("wait...", profile: p, register: .chat).joinedText == "wait...")
        #expect(try await Self.run("bring snacks etc.", profile: p, register: .chat).joinedText == "bring snacks etc.")
    }

    @Test func neverLowercasesPronounIOrAcronymsOrCamelCase() async throws {
        let p = StyleProfile.coldStart(appBundleID: Self.slack, category: .chat)
        #expect(try await Self.run("I'll be there", profile: p, register: .chat).joinedText == "I'll be there")
        #expect(try await Self.run("NASA launched", profile: p, register: .chat).joinedText == "NASA launched")
        #expect(try await Self.run("iPhone is ready", profile: p, register: .chat).joinedText == "iPhone is ready")
        #expect(try await Self.run("McDonald's later", profile: p, register: .chat).joinedText == "McDonald's later")
    }

    @Test func codeAndTerminalAreVerbatim() async throws {
        let code = StyleProfile.coldStart(appBundleID: "com.microsoft.VSCode", category: .code)
        #expect(try await Self.run("Return nil.", profile: code, register: .code).joinedText == "Return nil.")
        // Even a chat-like profile must not touch a terminal register.
        let chat = StyleProfile.coldStart(appBundleID: Self.slack, category: .chat)
        #expect(try await Self.run("Ls -la.", profile: chat, register: .terminal).joinedText == "Ls -la.")
    }

    @Test func undecidedProfileLeavesTextAlone() async throws {
        var p = StyleProfile.coldStart(appBundleID: "x", category: .prose)
        p.capitalizationRate = 0.5; p.terminalPeriodRate = 0.5
        #expect(try await Self.run("hello there", profile: p).joinedText == "hello there")
        #expect(try await Self.run("Hello there.", profile: p).joinedText == "Hello there.")
    }

    @Test func disabledViaContext() async throws {
        var ctx = StageContext(register: .chat, appBundleID: Self.slack)
        ctx.extra[StyleStage.enabledKey] = "false"
        let out = try await StyleStage().process(Self.spans("Sounds good."), context: ctx)
        #expect(out.joinedText == "Sounds good." && out.first?.provenance.last == .style)
    }

    @Test func emptyInputIsFine() async throws {
        let out = try await StyleStage().process([], context: StageContext(register: .chat))
        #expect(out.isEmpty)
    }

    @Test func resolvesProfileFromStoreThenColdStart() async throws {
        let store = InMemoryStyleProfileStore()
        let stage = StyleStage(store: store)
        // No stored profile: Slack → chat cold start → period dropped.
        var out = try await stage.process(Self.spans("Sounds good."), context: StageContext(register: .chat, appBundleID: Self.slack))
        #expect(out.joinedText == "sounds good")
        // Stored formal profile for the same app wins.
        var formal = StyleProfile.coldStart(appBundleID: Self.slack, category: .mail)
        formal.sampleCount = 20
        try store.save(formal)
        out = try await stage.process(Self.spans("sounds good"), context: StageContext(register: .chat, appBundleID: Self.slack))
        #expect(out.joinedText == "Sounds good.")
    }

    @Test func unknownAppFallsBackToRegisterCategory() async throws {
        let out = try await StyleStage().process(Self.spans("Sounds good."), context: StageContext(register: .chat))
        #expect(out.joinedText == "sounds good")
    }

    // MARK: Bet 9 contract

    @Test func lowConfidenceFirstSpanIsFlaggedNotRewritten() async throws {
        let p = StyleProfile.coldStart(appBundleID: Self.slack, category: .chat)
        var input = Self.spans("Kothari is here.")
        input[0].confidence = 0.2
        var ctx = StageContext(register: .chat, appBundleID: Self.slack)
        ctx.extra[StyleStage.profileJSONKey] = try p.encodedJSON()
        let out = try await StyleStage().process(input, context: ctx)
        #expect(out[0].text == "Kothari" && out[0].needsRepair)
        #expect(out.last?.text == "here")
        #expect(ConfidenceContract.verify(input: input, output: out).isEmpty)
    }

    @Test func lowConfidenceLastSpanKeepsItsPeriod() async throws {
        let p = StyleProfile.coldStart(appBundleID: Self.slack, category: .chat)
        var input = Self.spans("Call Teamviewer.")
        input[1].confidence = 0.1
        var ctx = StageContext(register: .chat, appBundleID: Self.slack)
        ctx.extra[StyleStage.profileJSONKey] = try p.encodedJSON()
        let out = try await StyleStage().process(input, context: ctx)
        #expect(out.joinedText == "call Teamviewer." && out[1].needsRepair)
        #expect(ConfidenceContract.verify(input: input, output: out).isEmpty)
    }

    @Test func contractHoldsForAllColdStartCategories() async throws {
        for cat in AppCategory.allCases {
            let p = StyleProfile.coldStart(appBundleID: "x", category: cat)
            let input = Self.spans("Hello there friend.", confidence: 0.4)
            let out = try await Self.run("Hello there friend.", profile: p, confidence: 0.4)
            #expect(ConfidenceContract.verify(input: input, output: out).isEmpty, "\(cat)")
            #expect(out.joinedText == "Hello there friend.")
        }
    }

    // MARK: Database persistence

    @Test func databaseStoreRoundTrip() throws {
        let db = try AppDatabase.inMemory()
        let store = DatabaseStyleProfileStore(database: db)
        #expect(try store.profile(for: Self.mail) == nil)
        var p = StyleProfile.coldStart(appBundleID: Self.mail, category: .mail)
        p.capitalizationRate = 0.25; p.sampleCount = 11
        try store.save(p)
        p.terminalPeriodRate = 0.2
        try store.save(p) // upsert, same row
        let back = try #require(try store.profile(for: Self.mail))
        #expect(abs(back.capitalizationRate - 0.25) < 1e-9 && abs(back.terminalPeriodRate - 0.2) < 1e-9)
        #expect(try db.persona(forApp: Self.mail) == nil, "style rows are namespaced away from personas")
        #expect(try db.persona(forApp: DatabaseStyleProfileStore.key(for: Self.mail))?.id == "style:" + Self.mail)
    }

    @Test func databaseStoreDiscardsCorruptRow() throws {
        let db = try AppDatabase.inMemory()
        let key = DatabaseStyleProfileStore.key(for: "bad")
        try db.save(PersonaRecord(id: key, appBundleID: key, instructions: "not json"))
        #expect(try DatabaseStyleProfileStore(database: db).profile(for: "bad") == nil)
    }

    @Test func learnerAndStageEndToEndThroughDatabase() async throws {
        let db = try AppDatabase.inMemory()
        let store = DatabaseStyleProfileStore(database: db)
        let learner = StyleLearner(store: store)
        for i in 0..<10 { try learner.ingest(original: "Note \(i) here.", edited: "note \(i) here", bundleID: Self.mail) }
        let out = try await StyleStage(store: store).process(Self.spans("Deck is attached."),
                                                             context: StageContext(register: .email, appBundleID: Self.mail))
        #expect(out.joinedText == "deck is attached")
    }

    @Test func registeredInStageRegistry() {
        #expect(StageRegistry.stage(for: .style) != nil)
        #expect(StageRegistry.allStages().last?.id == .style)
    }
}
