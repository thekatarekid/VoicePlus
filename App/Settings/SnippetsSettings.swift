import Pipeline
import Shared
import SwiftUI

/// P2.6 — spoken snippets: trigger phrase → expansion. Backed by `SnippetStoring` (DB in the app).
@MainActor
public final class SnippetsViewModel: ObservableObject {
    @Published public private(set) var snippets: [Snippet] = []
    @Published public var lastError: String?
    /// S7d — the last read failed. The group says so with a scoped Try again and keeps what it last
    /// showed; an unreadable store never reads as "no snippets" (design §9: loading/error never
    /// looks like empty).
    @Published public private(set) var loadFailed = false
    public let store: any SnippetStoring
    public init(store: any SnippetStoring) { self.store = store; reload() }

    public static let unreadable = "Snippets can’t be read"
    public static let unreadableDetail = "Your saved snippets haven’t been cleared."

    /// The scoped banner the group shows while the store cannot be read.
    public var loadFailureBanner: SectionBanner? {
        loadFailed ? SectionBanner(headline: Self.unreadable, actionTitle: SectionCopy.tryAgain,
                                   body: Self.unreadableDetail) : nil
    }

    public func reload() {
        do {
            snippets = try store.all()
            loadFailed = false
        } catch {
            Log.app.error("snippets: read failed: \(error)")
            loadFailed = true
        }
    }

    /// Adds or updates (by id) a snippet; validation errors surface in `lastError`.
    @discardableResult
    public func save(id: String? = nil, trigger: String, body: String) -> Bool {
        do {
            try store.upsert(Snippet(id: id ?? UUID().uuidString, trigger: trigger.trimmingCharacters(in: .whitespaces), body: body))
            lastError = nil; reload(); return true
        } catch { lastError = Self.describe(error); return false }
    }

    /// Deletes a snippet. A delete that fails keeps the row and says so; one that finds the snippet
    /// already gone is what the user asked for.
    @discardableResult
    public func delete(id: String) -> Bool {
        let trigger = snippets.first { $0.id == id }?.trigger
        do {
            try store.delete(id: id)
        } catch SnippetError.notFound {
            // Already gone: the reload below drops the row.
        } catch {
            Log.app.error("snippets: delete failed: \(error)")
            lastError = Self.notDeleted(trigger)
            return false
        }
        lastError = nil
        reload()
        return true
    }

    static func notDeleted(_ trigger: String?) -> String {
        "\(trigger.map { "“\($0)”" } ?? "The snippet") wasn’t deleted — \(SectionCopy.tryAgain)"
    }

    /// S7d — the inline sentence for a save that did not happen (Problem — Action; no raw error
    /// tokens in copy, `DESIGN.md` §7.1). The entered trigger and expansion stay in the form.
    static func describe(_ e: Error) -> String {
        switch e as? SnippetError {
        case .emptyTrigger?: return "Add a trigger phrase first."
        case .emptyBody?: return "Add the text to type first."
        case .duplicateTrigger(let trigger)?: return "“\(trigger)” is already a trigger — choose another phrase."
        case .notFound?: return "That snippet is gone — add it again."
        case nil: return "\(SectionCopy.notSaved) — \(SectionCopy.tryAgain)"
        }
    }
}

/// S7d — spoken snippets as rows of Dictionary & Apps › Dictionary (design §8.3: "Snippets and
/// personas as rows here"): the design's group and rows, one Edit / Delete per row, and the add form
/// as the group's last row. The search query filters triggers and expansions.
struct SnippetsSettingsTab: View {
    @ObservedObject var model: SnippetsViewModel
    /// The section's search (toolbar / "Search your words").
    var query: String = ""
    @State private var editingID: String?
    @State private var trigger = ""
    @State private var body_ = ""

    static let help = "Say the trigger exactly and the expansion is typed instead. Example: “my address” → your street address."

    private var shown: [Snippet] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? model.snippets : model.snippets.filter {
            $0.trigger.localizedCaseInsensitiveContains(q) || $0.body.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        GroupBox(DictionaryAppsCopy.snippetsTitle, layout: .rows) {
            Text(Self.help)
                .windowFont(Tokens.Typography.meta)
                .foregroundStyle(WindowColor.secondaryInk)
                .padding(.horizontal, Tokens.Spacing.l)
                .padding(.vertical, Tokens.Spacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let failure = model.loadFailureBanner {
                ScopedBanner(failure) { model.reload() }
                    .padding(.horizontal, Tokens.Spacing.l)
                    .padding(.bottom, Tokens.Spacing.m)
                    .accessibilityIdentifier("dictionary.snippets.unreadable")
            }
            ForEach(shown) { snippet in
                RowView(snippet.trigger, detail: snippet.body) {
                    HStack(spacing: Tokens.Spacing.s) {
                        Button(DictionaryAppsCopy.edit) {
                            editingID = snippet.id
                            trigger = snippet.trigger
                            body_ = snippet.body
                        }
                        Button(role: .destructive) { model.delete(id: snippet.id) } label: {
                            Image(systemName: "trash").accessibilityLabel("Delete “\(snippet.trigger)”")
                        }
                        .buttonStyle(.borderless)
                    }
                    .controlSize(.small)
                }
                .accessibilityIdentifier("dictionary.snippets.row.\(snippet.id)")
            }
            form
        }
        .accessibilityIdentifier("dictionary.snippets")
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            TextField("Trigger phrase (e.g. my address)", text: $trigger)
                .accessibilityIdentifier("dictionary.snippets.trigger")
            TextField("Expansion", text: $body_, axis: .vertical)
                .lineLimit(2...4)
                .accessibilityIdentifier("dictionary.snippets.body")
            HStack(spacing: Tokens.Spacing.s) {
                if let error = model.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .windowFont(Tokens.Typography.meta)
                        .foregroundStyle(WindowColor.attention)
                }
                Spacer()
                if editingID != nil {
                    Button(DictionaryAppsCopy.cancel) { reset() }
                }
                Button(editingID == nil ? DictionaryAppsCopy.add : "Save") {
                    if model.save(id: editingID, trigger: trigger, body: body_) { reset() }
                }
                .disabled(trigger.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("dictionary.snippets.save")
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(.horizontal, Tokens.Spacing.l)
        .padding(.vertical, Tokens.Spacing.m)
        .overlay(alignment: .top) { Rectangle().fill(WindowColor.separator).frame(height: 1) }
    }

    private func reset() {
        editingID = nil
        trigger = ""
        body_ = ""
    }
}

/// P1.5.2 — silent-correction switches: global + per app. Pure over `SettingsStore`.
@MainActor
public final class CorrectionSettingsViewModel: ObservableObject {
    @Published public var enabled: Bool { didSet { store.set(enabled, for: CorrectionSettings.enabledKey) } }
    @Published public private(set) var disabledApps: [String]
    private let store: SettingsStore
    private static let listKey = "corrections.off.list"

    public init(store: SettingsStore) {
        self.store = store
        enabled = store.bool(CorrectionSettings.enabledKey) ?? true
        disabledApps = (store.string(Self.listKey) ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }

    public func disable(app bundleID: String) {
        let b = bundleID.trimmingCharacters(in: .whitespaces)
        guard !b.isEmpty else { return }
        CorrectionSettings.setEnabled(false, for: b, store: store)
        if !disabledApps.contains(b) { disabledApps.append(b) }
        persistList()
    }

    public func enable(app bundleID: String) {
        CorrectionSettings.setEnabled(true, for: bundleID, store: store)
        disabledApps.removeAll { $0 == bundleID }
        persistList()
    }

    private func persistList() { store.set(disabledApps.joined(separator: ","), for: Self.listKey) }
}

struct CorrectionSettingsSection: View {
    @ObservedObject var model: CorrectionSettingsViewModel
    @State private var newApp = ""
    var body: some View {
        Section("Silent corrections") {
            Toggle("Fix preview words silently after landing (dual-path)", isOn: $model.enabled)
            ForEach(model.disabledApps, id: \.self) { app in
                HStack { Text(app).font(.caption.monospaced()); Spacer(); Button("Enable") { model.enable(app: app) } }
            }
            HStack {
                TextField("Turn off in app (bundle ID)", text: $newApp)
                Button("Turn off") { model.disable(app: newApp); newApp = "" }.disabled(newApp.isEmpty)
            }
        }
    }
}

/// P2.5 — auto-draft from style learnings (the user's edits are never overwritten).
extension PersonasViewModel {
    public func autoDraft(appBundleID: String, database: AppDatabase?) -> String? {
        guard let database, !appBundleID.isEmpty else { return nil }
        let manager = PersonaManager(store: DatabasePersonaStore(database: database), styles: DatabaseStyleProfileStore(database: database))
        return try? manager.draftText(for: appBundleID)
    }
}
