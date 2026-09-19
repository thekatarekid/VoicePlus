import Contacts
import Foundation
import Shared

/// Abstracts `CNContactStore` so the mapping is testable without the Contacts permission.
public protocol ContactsStoreProtocol: AnyObject {
    var authorization: OnboardingPermissionStatus { get }
    func requestAccess() async -> Bool
    /// Full names ("Given Family"), local only.
    func fetchNames() throws -> [String]
}

public final class MockContactsStore: ContactsStoreProtocol {
    public var authorization: OnboardingPermissionStatus
    public var names: [String]
    public var grantOnRequest = true
    public init(names: [String], authorization: OnboardingPermissionStatus = .notDetermined) {
        self.names = names
        self.authorization = authorization
    }
    public func requestAccess() async -> Bool {
        authorization = grantOnRequest ? .granted : .denied
        return grantOnRequest
    }
    public func fetchNames() throws -> [String] { names }
}

/// Real store; only touches the Contacts framework after the user opts in.
public final class SystemContactsStore: ContactsStoreProtocol {
    private let store = CNContactStore()
    public init() {}

    public var authorization: OnboardingPermissionStatus {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .granted  // e.g. `.limited` on newer SDKs: partial access still usable
        }
    }

    public func requestAccess() async -> Bool {
        (try? await store.requestAccess(for: .contacts)) ?? false
    }

    public func fetchNames() throws -> [String] {
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey] as [CNKeyDescriptor]
        let request = CNContactFetchRequest(keysToFetch: keys)
        var names: [String] = []
        try store.enumerateContacts(with: request) { contact, _ in
            let full = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            if !full.isEmpty { names.append(full) }
            if !contact.nickname.isEmpty { names.append(contact.nickname) }
        }
        return names
    }
}

/// Maps contact names to dictionary terms (P1.9 T4). Pure; no I/O.
public enum ContactsImportMapper {
    /// Given "Ada Lovelace" yields terms for the full name and each distinct name part ≥ 2 chars.
    /// Deduplicated case-insensitively, existing terms excluded, stable alphabetical order.
    public static func map(names: [String], existingTerms: [String] = []) -> [DictionaryRecord] {
        let existing = Set(existingTerms.map { $0.lowercased() })
        return candidates(names: names)
            .filter { !existing.contains($0.lowercased()) }
            .map { DictionaryRecord(term: $0, spokenForms: "", weight: 1.0) }
    }

    /// S7d — the words a Contacts import would offer, before anything is compared with the
    /// dictionary: every full name and each distinct part, ≥ 2 characters with a letter, each once
    /// (case-insensitively), alphabetical. The preview marks which are already saved.
    public static func candidates(names: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        let all = names.flatMap { name -> [String] in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = trimmed.split(separator: " ").map(String.init)
            return [trimmed] + (parts.count > 1 ? parts : [])
        }
        for term in all.sorted() {
            guard term.count >= 2, term.rangeOfCharacter(from: .letters) != nil else { continue }
            guard seen.insert(term.lowercased()).inserted else { continue }
            out.append(term)
        }
        return out
    }
}

/// S7d — the words of the Contacts import in the Dictionary (design §8.3: optional, with a
/// permission explanation, a preview, and an explicit commit). The explanation comes before the
/// system prompt; nothing is added until the user commits the preview.
public enum ContactsImportCopy {
    public static let title = "Import names from Contacts"
    public static let explanation = "VoicePlus reads the names in Contacts on this Mac and shows them to you first. "
        + "Nothing is added until you choose, and nothing leaves this Mac."
    public static let scope = "Only names are read — never numbers, addresses or notes."
    public static let proceed = "Continue"
    public static let notNow = "Not now"
    public static let waiting = "Waiting for Contacts access…"
    public static let unavailable = "Contacts couldn’t be read"
    /// Contacts' pane in System Settings, for the denied banner's action.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts")!
}

/// Orchestrates the first-run offer: ask → fetch → map → save. Idempotent via `offered` flag.
public final class ContactsImportOffer {
    public enum Outcome: Equatable { case imported(Int), denied, declined, unavailable }

    private let store: ContactsStoreProtocol
    private let database: AppDatabase?
    private let settings: SettingsStore
    private static let offeredKey = "onboarding.contactsOffered"

    public init(store: ContactsStoreProtocol, database: AppDatabase?, settings: SettingsStore) {
        self.store = store
        self.database = database
        self.settings = settings
    }

    public var alreadyOffered: Bool { settings.bool(Self.offeredKey) ?? false }
    public func markOffered() { settings.set(true, for: Self.offeredKey) }

    public func decline() -> Outcome { markOffered(); return .declined }

    public func accept() async -> Outcome {
        guard let database else { markOffered(); return .unavailable }
        switch await requestNames() {
        case .denied: return .denied
        case .unavailable: return .unavailable
        case .names(let names):
            do {
                let store = DatabaseDictionaryTermStore(database: database)
                let existing = try store.loadTerms().map(\.spelling)
                let records = ContactsImportMapper.map(names: names, existingTerms: existing)
                try store.apply(DictionaryChangeSet(upserts: records.map { DictionaryTerm(record: $0, source: .contacts) }))
                return .imported(records.count)
            } catch {
                Log.app.error("contacts import failed: \(error)")
                return .unavailable
            }
        }
    }

    /// What asking Contacts for names came to.
    public enum NamesResult: Equatable, Sendable {
        case names([String])
        case denied
        case unavailable
    }

    /// S7d — asks for access if needed (after the Dictionary's explanation) and reads the names,
    /// saving nothing. Marks the offer as made, so onboarding does not ask again.
    public func requestNames() async -> NamesResult {
        markOffered()
        if store.authorization != .granted, !(await store.requestAccess()) { return .denied }
        do {
            return .names(try store.fetchNames())
        } catch {
            Log.app.error("contacts read failed: \(error)")
            return .unavailable
        }
    }
}
