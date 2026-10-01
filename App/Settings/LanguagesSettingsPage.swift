import AppKit
import Foundation
import Pipeline
import Shared
import SwiftUI

// MARK: - V5 LANG1 · Settings › Languages
//
// Where the onboarding Languages step is changed later ("You can change this in Settings ›
// Languages"): the languages spoken, Hindi's script, the English spelling, what they mean for speech
// models, cleanup and word lists, and the per-app language memory (pin or forget an app's
// language). Every edit saves through `LanguagePreferences.save`, whose notification re-applies the
// LANG consumers (`LanguageRuntime`) and fetches only the route models now needed (G1/G2).

public enum LanguagesCopy {
    public static let title = "Languages"
    public static let subtitle = "The languages you speak, how each is written, and what VoicePlus downloads for them."
    public static let spokenTitle = "Languages you speak"
    public static let addLanguage = "Add language"
    public static let remove = "Remove"
    public static let lastLanguage = "Keep at least one language."
    public static let scriptTitle = "Write Hindi in"
    public static let spellingTitle = "English spelling"
    public static let modelsTitle = "What this needs"
    public static let speechTitle = "Speech models"
    public static let cleanupTitle = "AI cleanup"
    public static let wordListsTitle = "Word lists"
    public static let downloadList = "Download"
    public static let appsTitle = "Per-app languages"
    public static let appsEmpty = "VoicePlus remembers the language you use in each app once it has heard it a few times."
    public static let appsSingle = "With one language there is nothing to remember per app."
    public static let automatic = "Automatic"
    public static let forget = "Forget"
    public static let notAnswered = "Not set yet — VoicePlus works as before until you change something here."
    public static let footnote = "Nothing here is sent anywhere. Speech models download in the background only for the languages above; word lists only when you click."

    public static func learned(_ name: String) -> String { "Heard as \(name)" }

    public static func route(_ route: LanguagePreferences.ASRRoute) -> String {
        switch route {
        case .parakeetV3: return "Parakeet v3 — English and 24 European languages (included)"
        case .hinglish: return "Hinglish model — downloaded when available"
        case .multilingual: return "Nemotron multilingual — 664 MB, downloads in the background"
        }
    }

    public static func cleanup(_ choice: CleanupModelChoice, ready: Bool) -> String {
        switch choice {
        case .english: return "English cleanup model."
        case .multilingual:
            return ready ? "Multilingual model (shared with Computer use) for non-English turns."
                : "Non-English turns use the multilingual model — download it in Settings › Computer use. Until then they use the English model."
        }
    }
}

/// One app in the per-app list.
public struct AppLanguageRow: Equatable, Identifiable, Sendable {
    public var bundleID: String
    public var name: String
    /// Pinned code, nil = automatic.
    public var pinned: String?
    /// Learned code, when the history agrees.
    public var learned: String?
    public var id: String { bundleID }
}

@MainActor
public final class LanguagesSettingsModel: ObservableObject {
    public let store: SettingsStore
    @Published public private(set) var prefs: LanguagePreferences
    @Published public private(set) var answered: Bool
    @Published public private(set) var apps: [AppLanguageRow] = []
    @Published public private(set) var downloadingList = false
    @Published public private(set) var listFailure: String?
    @Published public private(set) var notice: String?
    private let appName: (String) -> String
    private let multilingualReady: () -> Bool

    public init(store: SettingsStore, environment: LanguageEnvironment = LiveLanguageEnvironment(),
                appName: @escaping (String) -> String = LanguagesSettingsModel.liveAppName,
                multilingualReady: @escaping () -> Bool = { SharedLocalLLM.shared.isModelOnDisk }) {
        self.store = store
        self.appName = appName
        self.multilingualReady = multilingualReady
        let saved = LanguagePreferences.load(store)
        answered = saved != nil
        prefs = saved ?? LanguagePreferences.prefill(preferredLanguages: environment.preferredLanguages,
                                                     inputSourceLanguages: environment.inputSourceLanguages)
        reloadApps()
    }

    // MARK: Languages

    public var chosen: [LanguageOption] { prefs.languages.map(LanguagePreferences.option(for:)) }
    public var others: [LanguageOption] { LanguagePreferences.catalogue.filter { !prefs.languages.contains($0.code) } }

    public func add(_ code: String) {
        var p = prefs
        guard !p.languages.contains(code) else { return }
        p.languages.append(LanguagePreferences.base(code))
        save(p)
    }

    /// Refuses to remove the last language.
    public func remove(_ code: String) {
        guard prefs.languages.count > 1 else { notice = LanguagesCopy.lastLanguage; return }
        var p = prefs
        p.languages.removeAll { $0 == code }
        p.scriptByLanguage[code] = nil
        save(p)
    }

    public var hindiScript: OutputScript {
        get { prefs.script(for: "hi") }
        set { var p = prefs; p.scriptByLanguage["hi"] = newValue; save(p) }
    }

    public var spelling: SpellingVariant {
        get { prefs.spelling }
        set { var p = prefs; p.spelling = newValue; save(p) }
    }

    private func save(_ p: LanguagePreferences) {
        notice = nil
        prefs = p
        answered = true
        p.save(to: store)
        reloadApps()
    }

    // MARK: What it needs

    public var speechLines: [String] { prefs.asrRoutes.map(LanguagesCopy.route) }
    public var cleanupLine: String { LanguagesCopy.cleanup(prefs.cleanupModel(), ready: multilingualReady()) }
    public var dictionaryPlan: LanguageDictionaryPlan { LanguageDictionaryPlan(prefs) }

    /// The variant word list is missing and can be fetched (explicit click only).
    public var canDownloadList: Bool {
        let plan = dictionaryPlan
        return plan.englishLists && plan.scowl != .us && !plan.scowl.isInstalled && !downloadingList
    }

    public func downloadList() {
        guard canDownloadList else { return }
        let variant = dictionaryPlan.scowl
        downloadingList = true
        listFailure = nil
        Task {
            do {
                try await variant.download()
                LanguageRuntime.current?.reapplyDictionaries()
            } catch {
                listFailure = "Couldn't download the word list. Check your connection and try again."
            }
            downloadingList = false
        }
    }

    // MARK: Per-app memory

    public var memory: AppLanguageMemory { AppLanguageMemory(store: store) }

    public func reloadApps() {
        let m = memory
        apps = m.apps.map { id in
            AppLanguageRow(bundleID: id, name: appName(id), pinned: m.pinnedLanguage(for: id), learned: m.learnedLanguage(for: id))
        }
    }

    /// "" = automatic.
    public var appOptions: [String] { [""] + prefs.languages }

    public func optionTitle(_ code: String) -> String {
        code.isEmpty ? LanguagesCopy.automatic : LanguagePreferences.option(for: code).name
    }

    public func setLanguage(_ code: String, for bundleID: String) {
        memory.pin(code.isEmpty ? nil : code, for: bundleID)
        reloadApps()
    }

    public func forget(_ bundleID: String) {
        memory.forget(bundleID)
        reloadApps()
    }

    public func detail(for row: AppLanguageRow) -> String? {
        row.learned.map { LanguagesCopy.learned(LanguagePreferences.option(for: $0).name) }
    }

    nonisolated public static func liveAppName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

struct LanguagesSettingsPage: View {
    @ObservedObject var model: LanguagesSettingsModel
    var hotkey: String

    var body: some View {
        SectionPage(.settings(.languages), state: .content, hotkey: hotkey) {
            VStack(alignment: .leading, spacing: MainWindowLayout.sectionGap) {
                GroupBox(LanguagesCopy.spokenTitle, layout: .rows) {
                    ForEach(model.chosen) { option in
                        RowView(option.name, detail: nil) {
                            Button(LanguagesCopy.remove) { model.remove(option.code) }
                                .disabled(model.chosen.count < 2)
                                .accessibilityIdentifier("languages.remove.\(option.code)")
                        }
                    }
                    RowView(LanguagesCopy.addLanguage, detail: model.notice ?? (model.answered ? nil : LanguagesCopy.notAnswered)) {
                        Menu(LanguagesCopy.addLanguage) {
                            ForEach(model.others) { option in Button(option.name) { model.add(option.code) } }
                        }
                        .fixedSize()
                        .accessibilityIdentifier("languages.add")
                    }
                    if model.prefs.includesHindi {
                        SettingsPickerRow(title: LanguagesCopy.scriptTitle, detail: nil,
                                          selection: Binding(get: { model.hindiScript }, set: { model.hindiScript = $0 }),
                                          options: LanguagePreferences.hindiScripts, label: { $0.title },
                                          identifier: "languages.script.hi")
                    }
                    if model.prefs.languages.contains("en") {
                        SettingsPickerRow(title: LanguagesCopy.spellingTitle, detail: nil,
                                          selection: Binding(get: { model.spelling }, set: { model.spelling = $0 }),
                                          options: SpellingVariant.allCases, label: { $0.title },
                                          identifier: "languages.spelling")
                    }
                }
                GroupBox(LanguagesCopy.modelsTitle, layout: .rows) {
                    RowView(LanguagesCopy.speechTitle, detail: model.speechLines.joined(separator: "\n")) { EmptyView() }
                        .accessibilityIdentifier("languages.speechModels")
                    RowView(LanguagesCopy.cleanupTitle, detail: model.cleanupLine) { EmptyView() }
                        .accessibilityIdentifier("languages.cleanupModel")
                    ForEach(Array(model.dictionaryPlan.lines.enumerated()), id: \.offset) { _, line in
                        RowView(line.title, detail: line.detail) { EmptyView() }
                    }
                    if model.canDownloadList || model.downloadingList || model.listFailure != nil {
                        RowView(LanguagesCopy.wordListsTitle, detail: model.listFailure ?? model.dictionaryPlan.scowl.title) {
                            if model.downloadingList { ProgressView().controlSize(.small) }
                            else { Button(LanguagesCopy.downloadList) { model.downloadList() }.accessibilityIdentifier("languages.wordList.download") }
                        }
                    }
                }
                GroupBox(LanguagesCopy.appsTitle, layout: .rows) {
                    if model.prefs.languages.count < 2 {
                        RowView(LanguagesCopy.appsSingle, detail: nil) { EmptyView() }
                    } else if model.apps.isEmpty {
                        RowView(LanguagesCopy.appsEmpty, detail: nil) { EmptyView() }
                    } else {
                        ForEach(model.apps) { row in
                            RowView(row.name, detail: model.detail(for: row)) {
                                HStack(spacing: Tokens.Spacing.s) {
                                    Picker(row.name, selection: Binding(get: { row.pinned ?? "" },
                                                                        set: { model.setLanguage($0, for: row.bundleID) })) {
                                        ForEach(model.appOptions, id: \.self) { Text(model.optionTitle($0)).tag($0) }
                                    }
                                    .pickerStyle(.menu).labelsHidden().fixedSize()
                                    .accessibilityIdentifier("languages.app.\(row.bundleID)")
                                    Button(LanguagesCopy.forget) { model.forget(row.bundleID) }
                                }
                            }
                        }
                    }
                }
                SettingsFootnote(LanguagesCopy.footnote)
            }
        }
        .onAppear { model.reloadApps() }
    }
}
