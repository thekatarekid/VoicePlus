import AppKit
import Foundation
import Injection
import Pipeline
import Shared

// S7d — the Apps half of Dictionary & Apps (design §8.3): an inherited default plus, per app, its
// writing style, whether VoicePlus may type into it (never-inject, R2.3), whether it may read text
// on screen for context (G2), and whether uncertain-word marks can be drawn in it (S5). A code or
// terminal app always gets the verbatim profile, and dictation never presses Return anywhere.
//
// Every value an app has is either **its own** (an override) or **the default** — the two are
// modelled apart (`Inherited.usesDefault`) so the pane can show "Uses default" distinctly from an
// override, and so a consumer resolves one app's rule with one call (`AppRuleBook.resolved(for:)`).

// MARK: - Values

/// How dictated text is written in an app (prototype Apps pane: "Clear & natural" / "Verbatim").
public enum AppWritingStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Cleaned up, punctuated, and shaped by the app's learned style and writing instructions.
    case natural
    /// Exactly as spoken: no style edits and no writing instructions.
    case verbatim

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .natural: return "Clear & natural"
        case .verbatim: return "Verbatim"
        }
    }
}

/// The profile an app gets from what it is, before any rule: code editors and terminals are verbatim.
/// Uses the same table the formatters route by (`AppCategoryTable`), so the pane says what the
/// pipeline does.
public enum AppProfile: String, Equatable, Sendable {
    case standard, code, terminal

    public init(bundleID: String) {
        switch AppCategoryTable.category(for: bundleID) {
        case .code: self = .code
        case .terminal: self = .terminal
        case .mail, .chat, .prose: self = .standard
        }
    }

    /// Code and terminal profiles keep commands exactly as spoken; no rule can change that.
    public var isVerbatim: Bool { self != .standard }
}

/// One value an app has, and whether it is the app's own or the inherited default.
public struct Inherited<Value: Equatable & Sendable>: Equatable, Sendable {
    public var value: Value
    public var usesDefault: Bool

    public init(_ value: Value, usesDefault: Bool) {
        self.value = value
        self.usesDefault = usesDefault
    }
}

// MARK: - Rules

/// What every app without its own value uses.
public struct AppRuleDefaults: Codable, Equatable, Sendable {
    public var style: AppWritingStyle
    /// On by default: reading text near the words (window text, boxes the user draws) is what the
    /// app already does; a rule turns it off.
    public var contextualReading: Bool

    public init(style: AppWritingStyle = .natural, contextualReading: Bool = true) {
        self.style = style
        self.contextualReading = contextualReading
    }

    public static let standard = AppRuleDefaults()
}

/// One app's own values. `nil` means "uses the default".
public struct AppRule: Codable, Equatable, Sendable, Identifiable {
    public var id: String { bundleID }
    public var bundleID: String
    /// The name shown when the app was added (the app may not be installed when the list is read).
    public var name: String?
    public var style: AppWritingStyle?
    public var contextualReading: Bool?
    /// Stored in `InjectionSettingsKeys.neverInject`, which `Injection` reads on every utterance.
    public var neverInject: Bool

    public init(bundleID: String, name: String? = nil, style: AppWritingStyle? = nil,
                contextualReading: Bool? = nil, neverInject: Bool = false) {
        self.bundleID = bundleID
        self.name = name
        self.style = style
        self.contextualReading = contextualReading
        self.neverInject = neverInject
    }

    /// Nothing of its own: the app uses the defaults.
    public var usesDefaults: Bool { style == nil && contextualReading == nil && !neverInject }

    private enum CodingKeys: String, CodingKey { case bundleID, name, style, contextualReading }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = try c.decode(String.self, forKey: .bundleID)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        style = try c.decodeIfPresent(AppWritingStyle.self, forKey: .style)
        contextualReading = try c.decodeIfPresent(Bool.self, forKey: .contextualReading)
        neverInject = false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(bundleID, forKey: .bundleID)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(style, forKey: .style)
        try c.encodeIfPresent(contextualReading, forKey: .contextualReading)
    }
}

/// An app's rule with every value resolved — what a consumer asks for.
public struct ResolvedAppRule: Equatable, Sendable {
    public var bundleID: String
    public var profile: AppProfile
    public var style: Inherited<AppWritingStyle>
    public var contextualReading: Inherited<Bool>
    /// False when the app is on the never-inject list: dictation is held there, never typed.
    public var mayInsert: Bool

    /// A code or terminal app's style cannot be changed.
    public var styleIsLocked: Bool { profile.isVerbatim }

    /// Dictation never presses Return — in any app. A code or terminal profile inserts the command
    /// and stops; there is no rule that sends it.
    public var pressesReturn: Bool { false }

    /// The rule applied to one pipeline run. Verbatim switches the style pass off for the run
    /// (`StyleStage.enabledKey`), skips cleanup (`CleanupStage.skipKey`, N26) and drops the writing instructions (`PersonaManager.promptKey`);
    /// contextual reading off drops what was read from the screen (`DeixisService` window text and
    /// box lines). Everything else in `context` is untouched.
    public func apply(to context: StageContext) -> StageContext {
        var ctx = context
        if style.value == .verbatim {
            ctx.extra[StyleStage.enabledKey] = "false"
            ctx.extra[CleanupStage.skipKey] = "true" // N26 — Verbatim also skips cleanup, explicitly
            ctx.extra.removeValue(forKey: PersonaManager.promptKey)
        }
        if !contextualReading.value {
            ctx.extra.removeValue(forKey: DeixisService.windowTextKey)
            ctx.extra.removeValue(forKey: DeixisService.contextLineKey)
        }
        return ctx
    }
}

/// Every app rule plus the defaults they inherit.
public struct AppRuleBook: Equatable, Sendable {
    public var defaults: AppRuleDefaults
    public var rules: [String: AppRule]

    public init(defaults: AppRuleDefaults = .standard, rules: [String: AppRule] = [:]) {
        self.defaults = defaults
        self.rules = rules
    }

    /// Bundle IDs VoicePlus must never type into.
    public var neverInject: Set<String> { Set(rules.values.filter(\.neverInject).map(\.bundleID)) }

    /// The app's own rule, or an empty one that uses the defaults.
    public func rule(for bundleID: String) -> AppRule { rules[bundleID] ?? AppRule(bundleID: bundleID) }

    public func resolved(for bundleID: String) -> ResolvedAppRule {
        let rule = rule(for: bundleID)
        let profile = AppProfile(bundleID: bundleID)
        let style: Inherited<AppWritingStyle> = profile.isVerbatim
            ? Inherited(.verbatim, usesDefault: false)
            : Inherited(rule.style ?? defaults.style, usesDefault: rule.style == nil)
        return ResolvedAppRule(bundleID: bundleID, profile: profile, style: style,
                               contextualReading: Inherited(rule.contextualReading ?? defaults.contextualReading,
                                                            usesDefault: rule.contextualReading == nil),
                               mayInsert: !rule.neverInject)
    }
}

// MARK: - Store

public enum AppRuleStoreError: Error, Equatable {
    /// The stored rules are not readable; nothing was changed.
    case unreadable
    /// The write did not stick.
    case notPersisted
}

/// Where app rules are read and written. A throw from `save` means nothing changed.
public protocol AppRuleStoring: AnyObject {
    func load() throws -> AppRuleBook
    func save(_ book: AppRuleBook) throws
}

/// `UserDefaults`: the rules as one JSON string (`apps.rules`), and the never-inject list in the key
/// `Injection` already reads (`InjectionSettingsKeys.neverInject`), so the typing rule takes effect
/// on the next utterance with no wiring.
public final class UserDefaultsAppRuleStore: AppRuleStoring {
    public static let rulesKey = "apps.rules"

    private struct Stored: Codable, Equatable {
        var version = 1
        var defaults: AppRuleDefaults
        var rules: [AppRule]
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load() throws -> AppRuleBook {
        var book = AppRuleBook()
        if let json = defaults.string(forKey: Self.rulesKey) {
            guard let data = json.data(using: .utf8), let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
                throw AppRuleStoreError.unreadable
            }
            book.defaults = stored.defaults
            for rule in stored.rules where !rule.bundleID.isEmpty { book.rules[rule.bundleID] = rule }
        }
        for bundleID in UserDefaultsInjectionPolicy(defaults: defaults).neverInjectBundleIDs {
            book.rules[bundleID, default: AppRule(bundleID: bundleID)].neverInject = true
        }
        return book
    }

    public func save(_ book: AppRuleBook) throws {
        let stored = Stored(defaults: book.defaults, rules: book.rules.values.sorted { $0.bundleID < $1.bundleID })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let json = String(data: try encoder.encode(stored), encoding: .utf8) else { throw AppRuleStoreError.notPersisted }
        let never = InjectionSettingsKeys.format(book.neverInject)
        defaults.set(json, forKey: Self.rulesKey)
        defaults.set(never, forKey: InjectionSettingsKeys.neverInject)
        guard defaults.string(forKey: Self.rulesKey) == json,
              UserDefaultsInjectionPolicy(defaults: defaults).neverInjectBundleIDs == book.neverInject else {
            throw AppRuleStoreError.notPersisted
        }
    }
}

/// The consumer's entry point: the rules as they are now. An unreadable store resolves every app to
/// the defaults (the never-inject list is read by `Injection` from its own key either way).
public enum AppRules {
    public static func current(defaults: UserDefaults = .standard) -> AppRuleBook {
        (try? UserDefaultsAppRuleStore(defaults: defaults).load()) ?? AppRuleBook()
    }

    /// The lander's context augmenter with the destination app's rule applied last, so nothing
    /// `base` adds (window text, box lines) survives a rule that turns contextual reading off.
    /// Rules are read on every run: a change in the pane applies to the next utterance.
    public static func applying(after base: @escaping ([TranscriptSpan], StageContext) -> StageContext,
                                rules: @escaping () -> AppRuleBook = { AppRules.current() })
        -> ([TranscriptSpan], StageContext) -> StageContext {
        { spans, context in
            let augmented = base(spans, context)
            guard let bundleID = augmented.appBundleID, !bundleID.isEmpty else { return augmented }
            return rules().resolved(for: bundleID).apply(to: augmented)
        }
    }
}

// MARK: - Word marks (S5 overlay capability)

/// Whether uncertain-word marks can be drawn over an app's text (design §7 "Destination support
/// ladder"). Only an app S5 has validated gets marks; everything else keeps them in Review.
public enum WordMarkSupport: Equatable, Sendable {
    case supported
    case unavailable

    public var tag: String {
        switch self {
        case .supported: return "Word marks"
        case .unavailable: return "No overlay"
        }
    }

    public var detail: String {
        switch self {
        case .supported: return "Uncertain words are marked where they land."
        case .unavailable: return "Text can be inserted; word marks stay in Review."
        }
    }
}

public protocol WordMarkCapabilityProviding: AnyObject {
    func wordMarks(for bundleID: String) -> WordMarkSupport
}

/// The per-bundle record S5 keeps of validated overlay adapters (`apps.wordMarks.validated`). Until
/// an app is recorded as validated, the pane says "No overlay" — the promise of marks is never made
/// for a field nobody verified.
public final class RecordedWordMarkCapability: WordMarkCapabilityProviding {
    public static let validatedKey = "apps.wordMarks.validated"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func wordMarks(for bundleID: String) -> WordMarkSupport {
        InjectionSettingsKeys.parseBundleIDs(defaults.string(forKey: Self.validatedKey)).contains(bundleID) ? .supported : .unavailable
    }

    /// What S5 calls when an adapter passes (or stops passing) validation for an app.
    public static func record(_ bundleID: String, supported: Bool, defaults: UserDefaults = .standard) {
        var set = InjectionSettingsKeys.parseBundleIDs(defaults.string(forKey: validatedKey))
        if supported { set.insert(bundleID) } else { set.remove(bundleID) }
        defaults.set(InjectionSettingsKeys.format(set), forKey: validatedKey)
    }
}

// MARK: - App names

/// An app as the pane lists it.
public struct AppIdentity: Equatable, Hashable, Identifiable, Sendable {
    public var id: String { bundleID }
    public var bundleID: String
    public var name: String

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

/// Bundle IDs → names, and the apps to offer when adding a rule.
public protocol AppIdentityResolving: AnyObject {
    func name(for bundleID: String) -> String?
    /// Apps running now with a window of their own, VoicePlus excluded.
    func runningApps() -> [AppIdentity]
    /// The app bundle at `url` (chosen from Applications).
    func identity(ofApplicationAt url: URL) -> AppIdentity?
}

/// `NSWorkspace`: the installed app's display name.
public final class WorkspaceAppIdentities: AppIdentityResolving {
    public init() {}

    public func name(for bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return Self.displayName(url)
    }

    public func runningApps() -> [AppIdentity] {
        let own = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> AppIdentity? in
                guard let bundleID = app.bundleIdentifier, bundleID != own, seen.insert(bundleID).inserted else { return nil }
                return AppIdentity(bundleID: bundleID, name: app.localizedName ?? bundleID)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func identity(ofApplicationAt url: URL) -> AppIdentity? {
        guard let bundleID = Bundle(url: url)?.bundleIdentifier else { return nil }
        return AppIdentity(bundleID: bundleID, name: Self.displayName(url))
    }

    static func displayName(_ url: URL) -> String {
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}
