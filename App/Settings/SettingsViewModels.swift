import Combine
import Foundation
import GRDB
import Shared

// MARK: - Hotkey

/// Hotkey choices offered in Settings. P1.1's `HotkeyBinding` consumes `rawValue` via `SettingsKeys.hotkey`.
public enum HotkeyChoice: String, CaseIterable, Identifiable, Sendable {
    case rightOption, fn, rightCommand, f5
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .rightOption: return "Right ⌥ Option (hold)"
        case .fn: return "fn / 🌐 (hold)"
        case .rightCommand: return "Right ⌘ Command (hold)"
        case .f5: return "F5 (hold)"
        }
    }
    public static let `default`: HotkeyChoice = .rightOption
}

@MainActor
public final class GeneralSettingsViewModel: ObservableObject {
    @Published public var hotkey: HotkeyChoice { didSet { store.set(hotkey.rawValue, for: SettingsKeys.hotkey) } }
    /// P5 — the persistent indicator near the notch. Default ON.
    @Published public var presenceIndicator: Bool {
        didSet { PresenceSettings.setEnabled(presenceIndicator, store: store) }
    }
    /// Quiet states only — `listening`, `processing` and `muted` always draw, full screen or not.
    @Published public var presenceHideInFullScreen: Bool {
        didSet { PresenceSettings.setHidesInFullScreen(presenceHideInFullScreen, store: store) }
    }
    private let store: SettingsStore
    public init(store: SettingsStore) {
        self.store = store
        hotkey = store.string(SettingsKeys.hotkey).flatMap(HotkeyChoice.init(rawValue:)) ?? .default
        presenceIndicator = PresenceSettings.isEnabled(store)
        presenceHideInFullScreen = PresenceSettings.hidesInFullScreen(store)
    }
}

// MARK: - Models / providers per stage

/// What runs a pipeline stage. `auto` = local first, paid only where enabled and the stage benefits (Part 4.6).
public enum ProviderChoice: Hashable, Sendable, Identifiable {
    case auto
    case local(ModelTier)
    case provider(String)   // provider id from P1.10 (e.g. "openrouter", "chatgpt-oauth", "claude-cli")

    public var id: String { rawValue }
    public var rawValue: String {
        switch self {
        case .auto: return "auto"
        case .local(let t): return "local:\(t.rawValue)"
        case .provider(let p): return "provider:\(p)"
        }
    }
    public init?(rawValue: String) {
        if rawValue == "auto" { self = .auto; return }
        if rawValue.hasPrefix("local:"), let t = ModelTier(rawValue: String(rawValue.dropFirst(6))) { self = .local(t); return }
        if rawValue.hasPrefix("provider:") { self = .provider(String(rawValue.dropFirst(9))); return }
        return nil
    }
    public var title: String {
        switch self {
        case .auto: return "Auto"
        case .local(let t): return "Local · \(t.title)"
        case .provider(let p): return p
        }
    }
}

/// Stages the user can route. The gatekeeper is always local (routing rule 1) so it is not listed.
public struct RoutableStage: Identifiable, Hashable, Sendable {
    public let id: StageID
    public let title: String
    public let acceptsProviders: Bool
    public static let all: [RoutableStage] = [
        .init(id: .asr, title: "Transcription", acceptsProviders: false),
        .init(id: .formatterEmail, title: "Email formatting", acceptsProviders: true),
        .init(id: .formatterChat, title: "Chat formatting", acceptsProviders: true),
        .init(id: .formatterCode, title: "Code formatting", acceptsProviders: true),
        .init(id: .formatterProse, title: "Prose formatting", acceptsProviders: true),
        .init(id: .style, title: "Style", acceptsProviders: true),
    ]
}

@MainActor
public final class ModelsSettingsViewModel: ObservableObject {
    @Published public private(set) var routing: [StageID: ProviderChoice] = [:]
    @Published public var connectedProviders: [String]
    private let store: SettingsStore
    public let models: ModelManaging

    public init(store: SettingsStore, models: ModelManaging, connectedProviders: [String] = []) {
        self.store = store
        self.models = models
        self.connectedProviders = connectedProviders
        for stage in RoutableStage.all {
            if let raw = store.string(SettingsKeys.routingPrefix + stage.id.rawValue), let c = ProviderChoice(rawValue: raw) {
                routing[stage.id] = c
            }
        }
    }

    public func choice(for stage: StageID) -> ProviderChoice { routing[stage] ?? .auto }

    public func options(for stage: RoutableStage) -> [ProviderChoice] {
        var out: [ProviderChoice] = [.auto] + ModelTier.allCases.map(ProviderChoice.local)
        if stage.acceptsProviders { out += connectedProviders.map(ProviderChoice.provider) }
        return out
    }

    public func set(_ choice: ProviderChoice, for stage: StageID) {
        if choice == .auto { routing[stage] = nil } else { routing[stage] = choice }
        store.set(choice == .auto ? nil : choice.rawValue, for: SettingsKeys.routingPrefix + stage.rawValue)
    }

    public func resetToAuto() { for s in RoutableStage.all { set(.auto, for: s.id) } }
}

// MARK: - Personas

@MainActor
public final class PersonasViewModel: ObservableObject {
    @Published public private(set) var personas: [PersonaRecord] = []
    private let database: AppDatabase?
    public init(database: AppDatabase?) { self.database = database; reload() }

    public func reload() {
        personas = (try? database?.reader.read { try PersonaRecord.order(Column("appBundleID")).fetchAll($0) }) ?? []
    }

    /// Upserts by bundle ID; empty instructions delete the persona.
    public func save(appBundleID: String, instructions: String) {
        let bundle = appBundleID.trimmingCharacters(in: .whitespaces)
        guard !bundle.isEmpty, let database else { return }
        let text = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { delete(appBundleID: bundle); return }
        let existing = try? database.persona(forApp: bundle)
        let record = PersonaRecord(id: existing?.id ?? UUID().uuidString, appBundleID: bundle, instructions: text)
        try? database.save(record)
        reload()
    }

    public func delete(appBundleID: String) {
        _ = try? database?.writer.write { try PersonaRecord.filter(Column("appBundleID") == appBundleID).deleteAll($0) }
        reload()
    }
}

// MARK: - Dictionary

@MainActor
public final class DictionaryViewModel: ObservableObject {
    @Published public private(set) var terms: [DictionaryRecord] = []
    @Published public var filter = ""
    private let database: AppDatabase?
    public init(database: AppDatabase?) { self.database = database; reload() }

    public var filtered: [DictionaryRecord] {
        filter.isEmpty ? terms : terms.filter { $0.term.localizedCaseInsensitiveContains(filter) }
    }

    public func reload() { terms = (try? database?.dictionaryTerms()) ?? [] }

    @discardableResult
    public func add(term: String, spokenForms: String = "") -> Bool {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !terms.contains(where: { $0.term.caseInsensitiveCompare(t) == .orderedSame }) else { return false }
        try? database?.save(DictionaryRecord(term: t, spokenForms: spokenForms))
        reload()
        return true
    }

    public func remove(id: String) { try? database?.deleteDictionaryTerm(id: id); reload() }

    public func importContacts(store: ContactsStoreProtocol, settings: SettingsStore) async -> ContactsImportOffer.Outcome {
        let outcome = await ContactsImportOffer(store: store, database: database, settings: settings).accept()
        reload()
        return outcome
    }
}

// MARK: - Flags

@MainActor
public final class FlagsViewModel: ObservableObject {
    public struct Row: Identifiable, Equatable { public let flag: FeatureFlag; public var enabled: Bool; public var overridden: Bool; public var id: String { flag.id } }
    @Published public private(set) var rows: [Row] = []
    private let service: FeatureFlagService
    public init(service: FeatureFlagService) { self.service = service; reload() }

    public func reload() {
        rows = service.knownFlags.map { Row(flag: $0, enabled: service.isEnabled($0), overridden: service.override(for: $0) != nil) }
    }
    public func set(_ enabled: Bool, for flag: FeatureFlag) {
        try? service.setOverride(enabled == flag.defaultOn ? nil : enabled, for: flag); reload()
    }
    public func resetAll() { try? service.resetAll(); reload() }
}

// MARK: - Data panel (placeholder listing; P1.11 owns the full panel)

@MainActor
public final class DataPanelViewModel: ObservableObject {
    @Published public private(set) var entries: [NetworkLogRecord] = []
    @Published public private(set) var bytesOutToday = 0
    private let database: AppDatabase?
    public init(database: AppDatabase?) { self.database = database; reload() }

    public func reload() {
        entries = (try? database?.networkLog(limit: 200)) ?? []
        let dayStart = Calendar.current.startOfDay(for: Date())
        bytesOutToday = (try? database?.bytesEgressed(since: dayStart)) ?? 0
    }
}
