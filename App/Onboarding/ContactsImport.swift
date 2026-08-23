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
        var seen = Set(existingTerms.map { $0.lowercased() })
        var out: [DictionaryRecord] = []
        let candidates = names.flatMap { name -> [String] in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = trimmed.split(separator: " ").map(String.init)
            return [trimmed] + (parts.count > 1 ? parts : [])
        }
        for term in candidates.sorted() {
            guard term.count >= 2, term.rangeOfCharacter(from: .letters) != nil else { continue }
            guard seen.insert(term.lowercased()).inserted else { continue }
            out.append(DictionaryRecord(term: term, spokenForms: "", weight: 1.0))
        }
        return out
    }
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
        markOffered()
        guard let database else { return .unavailable }
        if store.authorization != .granted, !(await store.requestAccess()) { return .denied }
        do {
            let existing = try database.dictionaryTerms().map(\.term)
            let records = ContactsImportMapper.map(names: try store.fetchNames(), existingTerms: existing)
            for record in records { try database.save(record) }
            return .imported(records.count)
        } catch {
            Log.app.error("contacts import failed: \(error)")
            return .unavailable
        }
    }
}
