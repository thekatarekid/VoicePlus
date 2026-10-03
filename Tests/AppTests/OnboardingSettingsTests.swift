import Foundation
import Shared
import Testing
@testable import VoicePlusApp

@Suite("Contacts import (P1.9 T4)")
struct ContactsImportTests {
    @Test func mappingSplitsDedupesAndSkipsExisting() {
        let records = ContactsImportMapper.map(
            names: ["Ada Lovelace", " Grace Hopper ", "ada lovelace", "Cher", "A", "Jo Ann Smith", "123"],
            existingTerms: ["Hopper"]
        )
        let terms = records.map(\.term)
        #expect(terms == ["Ada", "Ada Lovelace", "Ann", "Cher", "Grace", "Grace Hopper", "Jo", "Jo Ann Smith", "Lovelace", "Smith"])
        #expect(records.allSatisfy { $0.weight == 1.0 && $0.spokenForms.isEmpty })
        #expect(Set(records.map(\.id)).count == records.count)
    }

    @Test func offerImportsIntoDatabaseWhenGranted() async throws {
        let db = try AppDatabase.inMemory()
        try db.save(DictionaryRecord(term: "Ada"))
        let store = MockContactsStore(names: ["Ada Lovelace", "Linus Torvalds"])
        let settings = InMemorySettingsStore()
        let offer = ContactsImportOffer(store: store, database: db, settings: settings)
        #expect(!offer.alreadyOffered)
        let outcome = await offer.accept()
        #expect(outcome == .imported(5))  // Ada Lovelace, Linus, Linus Torvalds, Lovelace, Torvalds (Ada existed)
        #expect(offer.alreadyOffered)
        #expect(store.authorization == .granted)
        #expect(try db.dictionaryTerms().count == 6)
    }

    @Test func offerDeniedAndDeclinedBranches() async throws {
        let db = try AppDatabase.inMemory()
        let store = MockContactsStore(names: ["X Y"])
        store.grantOnRequest = false
        let offer = ContactsImportOffer(store: store, database: db, settings: InMemorySettingsStore())
        #expect(await offer.accept() == .denied)
        #expect(try db.dictionaryTerms().isEmpty)
        let other = ContactsImportOffer(store: store, database: nil, settings: InMemorySettingsStore())
        #expect(other.decline() == .declined)
        #expect(other.alreadyOffered)
        store.grantOnRequest = true
        #expect(await other.accept() == .unavailable)
    }
}

@Suite("Settings view-models (P1.9 T3)")
@MainActor
struct SettingsViewModelTests {
    @Test func hotkeyPersists() {
        let store = InMemorySettingsStore()
        let vm = GeneralSettingsViewModel(store: store)
        // X1 (owner round 4): Option is the default dictation key, the one `HotkeyService` listens on.
        #expect(vm.hotkey == .option)
        vm.hotkey = .rightOption
        #expect(store.string(SettingsKeys.hotkey) == "rightOption")
        #expect(GeneralSettingsViewModel(store: store).hotkey == .rightOption)
    }

    @Test func routingDefaultsToAutoAndPersistsOverrides() {
        let store = InMemorySettingsStore()
        let vm = ModelsSettingsViewModel(store: store, models: OnboardingMockModelManager(), connectedProviders: ["openrouter"])
        for s in RoutableStage.all { #expect(vm.choice(for: s.id) == .auto) }
        // R6.1: one local option, not three tiers. ASR takes no providers.
        #expect(vm.options(for: RoutableStage.all[0]) == [.auto, .local])
        #expect(vm.options(for: RoutableStage.all[1]).contains(.provider("openrouter")))
        #expect(!RoutableStage.all.contains { $0.id == .gatekeeper })  // gatekeeper is always local
        vm.set(.provider("openrouter"), for: .formatterEmail)
        vm.set(.local, for: .asr)
        #expect(store.string("routing.formatter.email") == "provider:openrouter")
        let reloaded = ModelsSettingsViewModel(store: store, models: OnboardingMockModelManager())
        #expect(reloaded.choice(for: .formatterEmail) == .provider("openrouter"))
        #expect(reloaded.choice(for: .asr) == .local)
        // A value a pre-R6.1 build wrote still reads back, as plain "local".
        #expect(ProviderChoice(rawValue: "local:best") == .local)
        reloaded.resetToAuto()
        #expect(store.string("routing.asr") == nil)
        #expect(ProviderChoice(rawValue: "garbage") == nil)
    }

    @Test func personasUpsertAndDelete() throws {
        let db = try AppDatabase.inMemory()
        let vm = PersonasViewModel(database: db)
        vm.save(appBundleID: "com.slack", instructions: "Casual, short.")
        vm.save(appBundleID: "com.slack", instructions: "Casual, no sign-off.")
        vm.save(appBundleID: "com.apple.mail", instructions: "Formal.")
        #expect(vm.personas.map(\.appBundleID) == ["com.apple.mail", "com.slack"])
        #expect(try db.persona(forApp: "com.slack")?.instructions == "Casual, no sign-off.")
        vm.save(appBundleID: "com.slack", instructions: "   ")
        #expect(vm.personas.count == 1)
        vm.save(appBundleID: "", instructions: "ignored")
        #expect(vm.personas.count == 1)
    }

    @Test func dictionaryAddFilterRemove() throws {
        let db = try AppDatabase.inMemory()
        let vm = DictionaryViewModel(database: db)
        #expect(vm.add(term: "Kubernetes", spokenForms: "koober netties"))
        #expect(!vm.add(term: "kubernetes"))
        #expect(!vm.add(term: "  "))
        #expect(vm.add(term: "GRDB"))
        vm.filter = "kube"
        #expect(vm.filtered.map(\.term) == ["Kubernetes"])
        vm.filter = ""
        vm.remove(id: try #require(vm.terms.first { $0.term == "GRDB" }?.id))
        #expect(vm.terms.map(\.term) == ["Kubernetes"])
    }

    @Test func dictionaryContactsImportThroughViewModel() async throws {
        let db = try AppDatabase.inMemory()
        let vm = DictionaryViewModel(database: db)
        let outcome = await vm.importContacts(store: MockContactsStore(names: ["Ada Lovelace"]), settings: InMemorySettingsStore())
        #expect(outcome == .imported(3))
        #expect(vm.terms.count == 3)
    }

    @Test func flagsOverrideAndReset() {
        let service = FeatureFlagService.inMemory()
        let vm = FlagsViewModel(service: service)
        #expect(vm.rows.count == FeatureFlag.all.count)
        #expect(vm.rows.allSatisfy { !$0.overridden })
        vm.set(false, for: .voiceRepair)
        #expect(service.isEnabled(.voiceRepair) == false)
        #expect(vm.rows.first { $0.id == "voiceRepair" }?.overridden == true)
        vm.set(true, for: .voiceRepair)  // back to default clears the override
        #expect(vm.rows.first { $0.id == "voiceRepair" }?.overridden == false)
        vm.set(true, for: .dualPath)
        vm.resetAll()
        #expect(service.isEnabled(.dualPath) == false)
    }

    @Test func dataPanelListsNetworkLog() throws {
        let db = try AppDatabase.inMemory()
        _ = try db.insert(NetworkLogRecord(stage: "style", provider: "openrouter", host: "openrouter.ai", bytesOut: 120, bytesIn: 400, purpose: "rewrite"))
        let vm = DataPanelViewModel(database: db)
        #expect(vm.entries.count == 1)
        #expect(vm.entries.first?.host == "openrouter.ai")
        #expect(vm.bytesOutToday == 120)
        #expect(DataPanelViewModel(database: nil).entries.isEmpty)
    }
}
