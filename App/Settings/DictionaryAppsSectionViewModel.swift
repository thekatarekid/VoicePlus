import Foundation
import Injection
import Shared

// R7.2 — Dictionary / Apps (`DESIGN.md` §9.3). Three old tabs land here: Dictionary, Snippets and
// Personas. The section also surfaces the one setting that existed but had no UI at all — the
// never-inject list (R2.3, `InjectionSettingsKeys.neverInject`), which until now could only be set
// with `defaults write`.
//
// Both lists are local, so `DESIGN.md` says the loading state "should be a single frame". It is
// still a real state, because the first read can fail (a locked database), and a failure has to be
// a banner over the data rather than a blank pane.

/// The per-app row: bundle ID, its persona, its snippets and whether text may be typed into it.
public struct AppPolicyRow: Identifiable, Equatable, Sendable {
    public var id: String { bundleID }
    public var bundleID: String
    public var persona: String?
    public var snippetCount: Int
    public var neverInject: Bool

    public init(bundleID: String, persona: String? = nil, snippetCount: Int = 0, neverInject: Bool = false) {
        self.bundleID = bundleID
        self.persona = persona
        self.snippetCount = snippetCount
        self.neverInject = neverInject
    }
}

/// Dictionary / Apps. Owns the states; the existing per-tab view models keep doing the storage work.
@MainActor
public final class DictionaryAppsSectionViewModel: ObservableObject {
    @Published public private(set) var dictionaryState: SectionState = .loading()
    @Published public private(set) var appsState: SectionState = .loading()
    /// Contacts denial and write failures sit beside the list, never instead of it.
    @Published public private(set) var banner: SectionBanner?
    @Published public private(set) var apps: [AppPolicyRow] = []

    public let dictionary: DictionaryViewModel
    public let learned: LearnedDictionaryViewModel
    public let personas: PersonasViewModel
    public let snippets: SnippetsViewModel
    private let policy: InjectionPolicyProviding
    private let defaults: UserDefaults

    public init(dictionary: DictionaryViewModel,
                learned: LearnedDictionaryViewModel,
                personas: PersonasViewModel,
                snippets: SnippetsViewModel,
                defaults: UserDefaults = .standard) {
        self.dictionary = dictionary
        self.learned = learned
        self.personas = personas
        self.snippets = snippets
        self.defaults = defaults
        self.policy = UserDefaultsInjectionPolicy(defaults: defaults)
        reload()
    }

    public func reload() {
        dictionary.reload()
        personas.reload()
        snippets.reload()
        rebuildApps()
        dictionaryState = dictionary.terms.isEmpty && learned.entries.isEmpty
            ? .empty(SectionCopy.noTerms, detail: SectionCopy.noTermsDetail, action: SectionCopy.importFromContacts)
            : .content
        appsState = apps.isEmpty
            ? .empty(SectionCopy.noAppSettings, detail: SectionCopy.noAppSettingsDetail)
            : .content
    }

    private func rebuildApps() {
        let never = policy.neverInjectBundleIDs
        var byBundle: [String: AppPolicyRow] = [:]
        for persona in personas.personas {
            byBundle[persona.appBundleID, default: AppPolicyRow(bundleID: persona.appBundleID)].persona = persona.instructions
        }
        for bundle in never {
            byBundle[bundle, default: AppPolicyRow(bundleID: bundle)].neverInject = true
        }
        // Snippets are not per-app today; the count is shown once per row so the section can say so
        // honestly rather than implying a per-app list that does not exist.
        let total = snippets.snippets.count
        apps = byBundle.values.map { row in
            var row = row
            row.snippetCount = total
            return row
        }.sorted { $0.bundleID < $1.bundleID }
    }

    // MARK: Never-inject (R2.3)

    /// One line of consequence, stated next to the switch (`DESIGN.md` §9.3).
    public static let neverInjectConsequence = "Dictation is held here, never typed"

    public func isNeverInject(_ bundleID: String) -> Bool { policy.neverInjectBundleIDs.contains(bundleID) }

    public func setNeverInject(_ on: Bool, bundleID: String) {
        guard !bundleID.isEmpty else { return }
        var set = policy.neverInjectBundleIDs
        if on { set.insert(bundleID) } else { set.remove(bundleID) }
        defaults.set(InjectionSettingsKeys.format(set), forKey: InjectionSettingsKeys.neverInject)
        rebuildApps()
        appsState = apps.isEmpty ? .empty(SectionCopy.noAppSettings, detail: SectionCopy.noAppSettingsDetail) : .content
    }

    // MARK: Failures

    public func reportContactsDenied() {
        banner = SectionBanner(headline: SectionCopy.contactsDenied, actionTitle: SectionCopy.openSystemSettings)
    }

    public func reportWriteFailure(_ detail: String) {
        banner = SectionBanner(headline: SectionCopy.notSaved, actionTitle: SectionCopy.tryAgain, diagnostics: detail)
    }

    public func clearBanner() { banner = nil }
}
