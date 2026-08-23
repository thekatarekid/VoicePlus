import Testing
import Foundation
import Shared
@testable import Pipeline

/// P2.5 — persona drafting from style learnings, edits, recipient overrides, persistence, prompt assembly.
@Suite struct PersonasTests {
    static let slack = "com.tinyspeck.slackmacgap", mail = "com.apple.mail"

    static func learnedChat() -> StyleProfile {
        var p = StyleProfile.coldStart(appBundleID: slack, category: .chat)
        p.sampleCount = 20; p.capitalizationRate = 0.1; p.terminalPeriodRate = 0.05; p.emojiRate = 0.4; p.avgSentenceLength = 6
        return p
    }
    static func learnedMail() -> StyleProfile {
        var p = StyleProfile.coldStart(appBundleID: mail, category: .mail)
        p.sampleCount = 20; p.greetingRate = 0.9; p.preferredGreeting = "Hi"; p.signOffRate = 0.85; p.preferredSignOff = "Cheers"; p.avgSentenceLength = 22
        return p
    }
    static func manager(_ profiles: [StyleProfile] = [], store: any PersonaStoring = InMemoryPersonaStore(),
                        participants: any ContextParticipants = StageContextParticipants()) throws -> PersonaManager {
        let styles = InMemoryStyleProfileStore()
        for p in profiles { try styles.save(p) }
        return PersonaManager(store: store, styles: styles, participants: participants)
    }

    // MARK: Drafting

    @Test func draftsPlainEnglishFromChatLearnings() {
        let d = PersonaDrafter.draft(from: Self.learnedChat())
        #expect(d.hasPrefix("Relaxed chat voice"))
        #expect(d.contains("mostly lowercase") && d.contains("no trailing periods") && d.contains("emoji") && d.contains("short sentences"))
        #expect(d.hasSuffix("."))
        #expect(!d.contains("{") && !d.contains(":"), "reads like a sentence, not a form")
    }

    @Test func draftsMailVoiceWithGreetingAndSignOff() {
        let d = PersonaDrafter.draft(from: Self.learnedMail())
        #expect(d.contains("open with \"Hi\"") && d.contains("sign off with \"Cheers\"") && d.contains("longer, flowing sentences"))
    }

    @Test func coldStartDraftsAreCategorySpecific() {
        #expect(PersonaDrafter.draft(from: .coldStart(appBundleID: "x", category: .code)).hasPrefix("Terse, technical"))
        #expect(PersonaDrafter.draft(from: .coldStart(appBundleID: "x", category: .terminal)) == "Verbatim; no prose.")
        #expect(PersonaDrafter.draft(from: .coldStart(appBundleID: "x", category: .prose)) == "Clear, natural prose.")
        #expect(PersonaDrafter.draft(from: .coldStart(appBundleID: "x", category: .chat)).contains("mostly lowercase"))
    }

    @Test func managerAutoDraftsAndPersists() throws {
        let store = InMemoryPersonaStore()
        let m = try Self.manager([Self.learnedChat()], store: store)
        let p = try m.persona(for: Self.slack)
        #expect(p.isAutoDrafted && p.text == PersonaDrafter.draft(from: Self.learnedChat()))
        #expect(try store.persona(for: Self.slack) == p)
    }

    @Test func unknownAppDraftsFromBundleOrRegister() throws {
        let m = try Self.manager()
        #expect(try m.persona(for: "org.example.FancyMail").text.hasPrefix("Professional but warm email"))
        #expect(try m.persona(for: "com.unknown.thing", register: .chat).text.hasPrefix("Relaxed chat"))
    }

    @Test func autoDraftRefreshesAsLearningsChange() throws {
        let styles = InMemoryStyleProfileStore()
        let m = PersonaManager(store: InMemoryPersonaStore(), styles: styles)
        let before = try m.persona(for: Self.slack).text
        try styles.save(Self.learnedChat())
        let after = try m.persona(for: Self.slack)
        #expect(after.text != before && after.isAutoDrafted)
    }

    // MARK: Editing

    @Test func editedPersonaIsNeverOverwrittenByNewLearnings() throws {
        let styles = InMemoryStyleProfileStore()
        let m = PersonaManager(store: InMemoryPersonaStore(), styles: styles)
        let edited = try m.setText("  always formal, sign as A.K.  ", for: Self.slack)
        #expect(!edited.isAutoDrafted && edited.text == "always formal, sign as A.K.")
        try styles.save(Self.learnedChat())
        #expect(try m.persona(for: Self.slack).text == "always formal, sign as A.K.")
    }

    @Test func clearingTheBoxRevertsToAutoDraft() throws {
        let m = try Self.manager([Self.learnedChat()])
        _ = try m.setText("custom", for: Self.slack)
        let reverted = try m.setText("", for: Self.slack)
        #expect(reverted.isAutoDrafted && reverted.text == PersonaDrafter.draft(from: Self.learnedChat()))
    }

    // MARK: Recipients

    @Test func recipientKeysNormalize() {
        #expect(PersonaRecipient.key("Priya Kothari") == "priya kothari")
        #expect(PersonaRecipient.key("  priya   KOTHARI. ") == "priya kothari")
        #expect(PersonaRecipient.key("Priya Kothari <Priya@Example.io>") == "priya@example.io")
        #expect(PersonaRecipient.key("priya@example.io") == PersonaRecipient.key("PRIYA@example.io"))
    }

    @Test func recipientOverrideAppliesOnlyToThatThread() throws {
        let m = try Self.manager([Self.learnedMail()])
        _ = try m.setRecipientOverride("very formal, no jokes", recipient: "Dr. Rao <rao@uni.edu>", for: Self.mail)
        var ctx = StageContext(register: .email, appBundleID: Self.mail)
        ctx.extra[StageContextParticipants.key] = "me@x.io, RAO@uni.edu"
        let r = try #require(try m.resolve(context: ctx))
        #expect(r.override == "very formal, no jokes" && r.recipient == "RAO@uni.edu")
        #expect(r.promptText.hasPrefix(r.base.text) && r.promptText.contains("For this recipient (for RAO@uni.edu): very formal, no jokes"))
        ctx.extra[StageContextParticipants.key] = "someone@else.com"
        let plain = try #require(try m.resolve(context: ctx))
        #expect(plain.override == nil && plain.promptText == plain.base.text)
    }

    @Test func removingOverrideAndParticipantsProtocolInjection() throws {
        let m = try Self.manager([], participants: StaticParticipants(["Priya Kothari"]))
        _ = try m.setRecipientOverride("casual", recipient: "priya kothari", for: Self.slack)
        let ctx = StageContext(register: .chat, appBundleID: Self.slack)
        #expect(try m.resolve(context: ctx)?.override == "casual")
        _ = try m.setRecipientOverride(nil, recipient: "Priya Kothari", for: Self.slack)
        #expect(try m.resolve(context: ctx)?.override == nil)
        #expect(try m.persona(for: Self.slack).recipientOverrides.isEmpty)
    }

    @Test func stageContextParticipantsParsing() {
        var ctx = StageContext(); ctx.extra[StageContextParticipants.key] = "a@x.io; Bob Lee ,\n , c@y.io"
        #expect(StageContextParticipants().participants(context: ctx) == ["a@x.io", "Bob Lee", "c@y.io"])
        #expect(StageContextParticipants().participants(context: StageContext()).isEmpty)
    }

    // MARK: Prompt assembly for Providers

    @Test func decorateFillsPersonaKeyProvidersRead() throws {
        let m = try Self.manager([Self.learnedChat()])
        let c = m.decorate(StageContext(register: .chat, appBundleID: Self.slack))
        #expect(c.extra[PersonaManager.promptKey] == PersonaDrafter.draft(from: Self.learnedChat()))
        #expect(PersonaManager.promptKey == "persona")
    }

    @Test func decorateKeepsExplicitPersonaAndSkipsWithoutApp() throws {
        let m = try Self.manager()
        var explicit = StageContext(appBundleID: Self.slack); explicit.extra["persona"] = "pirate"
        #expect(m.decorate(explicit).extra["persona"] == "pirate")
        #expect(m.decorate(StageContext()).extra["persona"] == nil)
        #expect(try m.resolve(context: StageContext()) == nil)
    }

    // MARK: Persistence (PersonaRecord)

    @Test func databaseStoreRoundTripsTextStateAndOverrides() throws {
        let db = try AppDatabase.inMemory()
        let store = DatabasePersonaStore(database: db)
        var p = Persona(appBundleID: Self.mail, text: "warm", isAutoDrafted: true, recipientOverrides: ["rao@uni.edu": "formal", "priya kothari": "casual"])
        try store.save(p)
        let loaded = try #require(try store.persona(for: Self.mail))
        #expect(loaded.text == "warm" && loaded.isAutoDrafted && loaded.recipientOverrides == p.recipientOverrides)
        p.isAutoDrafted = false; p.text = "edited"; p.recipientOverrides = ["rao@uni.edu": "stiff"]
        try store.save(p)
        let again = try #require(try store.persona(for: Self.mail))
        #expect(again.text == "edited" && !again.isAutoDrafted && again.recipientOverrides == ["rao@uni.edu": "stiff"])
        #expect(try store.allBundleIDs() == [Self.mail])
        try store.delete(bundleID: Self.mail)
        #expect(try store.persona(for: Self.mail) == nil)
        #expect(try db.reader.read { try PersonaRecord.fetchCount($0) } == 0)
    }

    @Test func databaseStoreSharesRowWithSettingsAndStyleStore() throws {
        let db = try AppDatabase.inMemory()
        try db.save(PersonaRecord(appBundleID: Self.slack, instructions: "typed in settings"))   // P1.9 Settings row
        try DatabaseStyleProfileStore(database: db).save(Self.learnedChat())                   // style: row
        let store = DatabasePersonaStore(database: db)
        let p = try #require(try store.persona(for: Self.slack))
        #expect(p.text == "typed in settings" && !p.isAutoDrafted)
        #expect(try store.allBundleIDs() == [Self.slack])
        try store.save(Persona(appBundleID: Self.slack, text: "updated", isAutoDrafted: false))
        #expect(try db.persona(forApp: Self.slack)?.instructions == "updated")
        #expect(try DatabaseStyleProfileStore(database: db).profile(for: Self.slack) == Self.learnedChat())
    }

    @Test func managerOverDatabaseStoreSurvivesReload() throws {
        let db = try AppDatabase.inMemory()
        let styles = DatabaseStyleProfileStore(database: db); try styles.save(Self.learnedMail())
        let m1 = PersonaManager(store: DatabasePersonaStore(database: db), styles: styles)
        _ = try m1.setRecipientOverride("brief", recipient: "rao@uni.edu", for: Self.mail)
        let m2 = PersonaManager(store: DatabasePersonaStore(database: db), styles: styles)
        let p = try m2.persona(for: Self.mail)
        #expect(p.isAutoDrafted && p.text == PersonaDrafter.draft(from: Self.learnedMail()) && p.recipientOverrides["rao@uni.edu"] == "brief")
    }
}
