import Testing
import Foundation
import Shared
@testable import Pipeline

/// V5 F1 — persona auto-draft loop: landings teach the style profile, auto-drafts follow it,
/// edited personas are never overwritten.
@Suite struct PersonaLearningLoopTests {
    static let slack = "com.tinyspeck.slackmacgap", mail = "com.apple.mail"

    static func loop(store: any PersonaStoring = InMemoryPersonaStore(),
                     styles: any StyleProfileStore = InMemoryStyleProfileStore()) -> PersonaLearningLoop {
        PersonaLearningLoop(personas: PersonaManager(store: store, styles: styles))
    }

    /// Pipeline output is formal; the user keeps editing it down to lowercase, no full stop.
    static let syntheticChat: [(String, String)] = [
        ("Sounds good, see you at five.", "sounds good see you at 5"),
        ("I will push the fix tonight.", "ill push the fix tonight"),
        ("Can you review my pull request?", "can u review my pr"),
        ("Lunch tomorrow works for me.", "lunch tmrw works"),
        ("Thanks for the heads up.", "thx for the heads up"),
        ("On my way now.", "omw now"),
    ]

    @Test func profileConvergesOnASyntheticSequence() throws {
        let styles = InMemoryStyleProfileStore()
        let loop = Self.loop(styles: styles)
        let cold = StyleProfile.coldStart(appBundleID: Self.slack, category: .chat)
        var lastCap = cold.capitalizationRate, lastPeriod = cold.terminalPeriodRate
        for round in 0..<4 {
            for (original, edited) in Self.syntheticChat {
                let u = try #require(loop.observe(original: original, fieldValue: edited, bundleID: Self.slack))
                #expect(u.edited)
            }
            let p = try #require(try styles.profile(for: Self.slack))
            #expect(p.capitalizationRate <= lastCap && p.terminalPeriodRate <= lastPeriod, "round \(round) moves toward the user")
            lastCap = p.capitalizationRate; lastPeriod = p.terminalPeriodRate
        }
        let p = try #require(try styles.profile(for: Self.slack))
        // H22: the "?" message (no period either side) teaches nothing about periods; neutral prior.
        #expect(p.capitalizationRate < 0.05 && p.terminalPeriodRate < 0.1, "converged: \(p.capitalizationRate) / \(p.terminalPeriodRate)")
        #expect(p.dictationCount == Self.syntheticChat.count * 4)
        #expect(loop.learnedCount(for: Self.slack) == 24)
        // The auto-draft followed the learnings.
        let persona = try loop.personas.persona(for: Self.slack)
        #expect(persona.isAutoDrafted)
        #expect(persona.text.contains("mostly lowercase") && persona.text.contains("no trailing periods"))
        #expect(persona.text == PersonaDrafter.draft(from: p))
    }

    @Test func acceptedLandingsCountAtLowerWeight() throws {
        let styles = InMemoryStyleProfileStore()
        let loop = Self.loop(styles: styles)
        let u = try #require(loop.observe(original: "hey are we still on for lunch", fieldValue: nil, bundleID: Self.slack))
        #expect(!u.edited && u.learnedText == "hey are we still on for lunch")
        let p = try #require(try styles.profile(for: Self.slack))
        let cold = StyleProfile.coldStart(appBundleID: Self.slack, category: .chat)
        #expect(abs(p.sampleCount - (cold.sampleCount + StyleLearner(store: styles).acceptedWeight)) < 1e-9)
        #expect(p.dictationCount == 1)
    }

    @Test func editedPersonaIsNeverOverwritten() throws {
        let store = InMemoryPersonaStore()
        let loop = Self.loop(store: store)
        _ = try loop.personas.persona(for: Self.slack)        // auto-draft exists
        try loop.personas.setText("Always formal. Full sentences.", for: Self.slack)
        for (original, edited) in Self.syntheticChat {
            let u = try #require(loop.observe(original: original, fieldValue: edited, bundleID: Self.slack))
            #expect(u.persona.text == "Always formal. Full sentences." && !u.persona.isAutoDrafted)
        }
        #expect(try store.persona(for: Self.slack)?.text == "Always formal. Full sentences.")
        #expect(loop.learnedCount(for: Self.slack) == Self.syntheticChat.count, "learning continues underneath")
        // Clearing the box hands it back to the loop, which now reflects what was learned.
        let reverted = try loop.personas.setText("", for: Self.slack)
        #expect(reverted.isAutoDrafted && reverted.text.contains("mostly lowercase"))
    }

    @Test func settingsEditOfAnAutoDraftedRowIsAnEditInTheDatabase() throws {
        let db = try AppDatabase.inMemory()
        let store = DatabasePersonaStore(database: db)
        let loop = Self.loop(store: store, styles: DatabaseStyleProfileStore(database: db))
        let draft = try loop.personas.persona(for: Self.mail)
        #expect(draft.isAutoDrafted)
        // Settings writes the box row directly (PersonasViewModel.save), leaving the meta row "auto".
        let row = try #require(try db.persona(forApp: Self.mail))
        try db.save(PersonaRecord(id: row.id, appBundleID: Self.mail, instructions: "Short and blunt.",
                                  updatedAt: draft.updatedAt.addingTimeInterval(5)))
        let u = try #require(loop.observe(original: "Hi Sam, the deck is attached. Thanks", fieldValue: nil, bundleID: Self.mail))
        #expect(u.persona.text == "Short and blunt." && !u.persona.isAutoDrafted)
        #expect(try store.persona(for: Self.mail)?.text == "Short and blunt.")
        #expect(DatabasePersonaStore.isBookkeepingKey("persona-meta:\(Self.mail)"))
        #expect(DatabasePersonaStore.isBookkeepingKey("style:\(Self.mail)"))
        #expect(!DatabasePersonaStore.isBookkeepingKey(Self.mail))
    }

    @Test func autoDraftPersistsAcrossDatabaseRoundTrip() throws {
        let db = try AppDatabase.inMemory()
        let loop = Self.loop(store: DatabasePersonaStore(database: db), styles: DatabaseStyleProfileStore(database: db))
        for (o, e) in Self.syntheticChat { loop.observe(original: o, fieldValue: e, bundleID: Self.slack) }
        let stored = try #require(try DatabasePersonaStore(database: db).persona(for: Self.slack))
        #expect(stored.isAutoDrafted && stored.text.contains("mostly lowercase"))
        #expect(try DatabaseStyleProfileStore(database: db).profile(for: Self.slack)?.dictationCount == 6)
    }

    @Test func noAppOrEmptyTextLearnsNothing() {
        let loop = Self.loop()
        #expect(loop.observe(original: "hello there", fieldValue: nil, bundleID: "") == nil)
        #expect(loop.observe(original: "   ", fieldValue: "x", bundleID: Self.slack) == nil)
    }

    // MARK: Alignment

    @Test func editedSegmentFindsTheDictationInsideALongerField() {
        let field = "Hi Sam,\n\nquick update on the launch. ill push the fix tonight\n\nThanks,\nAditya"
        let seg = PersonaLearningLoop.editedSegment(original: "I will push the fix tonight.", fieldValue: field)
        #expect(seg == "ill push the fix tonight")
    }

    @Test func editedSegmentKeepsLineBreaksAndShortFields() {
        #expect(PersonaLearningLoop.editedSegment(original: "thanks see you", fieldValue: "Thanks,\nsee you") == "Thanks,\nsee you")
    }

    @Test func editedSegmentFallsBackWhenNothingResembles() {
        let field = String(repeating: "lorem ipsum dolor sit amet ", count: 20)
        #expect(PersonaLearningLoop.editedSegment(original: "push the fix tonight", fieldValue: field) == "push the fix tonight")
    }

    @Test func legacyProfileJSONWithoutCountDecodes() throws {
        var p = StyleProfile.coldStart(appBundleID: Self.slack, category: .chat)
        p.dictationCount = 3
        let json = try p.encodedJSON()
        #expect(try StyleProfile.decode(json: json).dictationCount == 3)
        let legacy = json.replacingOccurrences(of: "\"dictationCount\":3,", with: "")
        #expect(!legacy.contains("dictationCount"))
        #expect(try StyleProfile.decode(json: legacy).dictationCount == 0)
    }
}
