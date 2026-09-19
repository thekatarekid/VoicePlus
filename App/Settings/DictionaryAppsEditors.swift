import Engine
import SwiftUI
import Shared

// S7d — the Dictionary's two sheets (prototype `showAction('Add a word' | 'Edit spelling')` and the
// import preview). Both show what the user entered until a save succeeds; a duplicate or conflict is
// resolved inline in the form; a failed save says S02 in place and changes nothing.

// MARK: - Add / edit a word

struct DictionaryTermEditorSheet: View {
    @ObservedObject var model: DictionaryAppsSectionViewModel

    var body: some View {
        if let editor = model.editor {
            content(editor)
                .padding(Tokens.Spacing.xl)
                .frame(width: 440)
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<DictionaryTermDraft, Value>) -> Binding<Value> {
        Binding(
            get: { (model.editor?.draft ?? DictionaryTermDraft())[keyPath: keyPath] },
            set: { value in
                guard var draft = model.editor?.draft else { return }
                draft[keyPath: keyPath] = value
                model.updateDraft(draft)
            }
        )
    }

    private func content(_ editor: DictionaryTermEditor) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.l) {
            Text(editor.title)
                .windowFont(Tokens.Typography.section)
                .accessibilityAddTraits(.isHeader)
            Text("Save an explicitly chosen spelling in your dictionary.")
                .windowFont(Tokens.Typography.meta)
                .foregroundStyle(WindowColor.secondaryInk)

            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                Text(DictionaryAppsCopy.spelling).windowFont(Tokens.Typography.body)
                TextField(DictionaryAppsCopy.spelling, text: binding(\.spelling), prompt: Text(DictionaryAppsCopy.spellingPrompt))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .onSubmit { model.saveEditor() }
                    .accessibilityIdentifier("dictionary.editor.spelling")
                if let validation = editor.validation {
                    Label(validation, systemImage: "exclamationmark.triangle")
                        .windowFont(Tokens.Typography.meta)
                        .foregroundStyle(WindowColor.attention)
                        .accessibilityIdentifier("dictionary.editor.validation")
                }
                TrainByVoiceButton(word: editor.draft.spelling) { model.learned.reload() }
            }

            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                Text(DictionaryAppsCopy.spokenForm).windowFont(Tokens.Typography.body)
                TextField(DictionaryAppsCopy.spokenForm, text: binding(\.spokenForms), prompt: Text(DictionaryAppsCopy.spokenFormPrompt))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .accessibilityIdentifier("dictionary.editor.spokenForm")
                Text(DictionaryAppsCopy.spokenFormHelp)
                    .windowFont(Tokens.Typography.meta)
                    .foregroundStyle(WindowColor.secondaryInk)
            }

            Picker(DictionaryAppsCopy.language, selection: binding(\.language)) {
                ForEach(DictionaryTermLanguage.allCases) { Text($0.title).tag($0) }
            }
            .frame(maxWidth: 280)
            .accessibilityIdentifier("dictionary.editor.language")

            if let conflict = editor.conflict { conflictRow(conflict, draft: editor.draft) }
            if let failure = editor.failureBanner {
                ScopedBanner(failure) { model.saveEditor() }
                    .accessibilityIdentifier("dictionary.editor.failure")
            }

            HStack(spacing: Tokens.Spacing.s) {
                if !editor.draft.isNew {
                    Button(DictionaryAppsCopy.deleteWord, role: .destructive) { model.deleteEditedTerm() }
                        .accessibilityIdentifier("dictionary.editor.delete")
                }
                Spacer()
                Button(DictionaryAppsCopy.cancel) { model.cancelEditor() }
                    .keyboardShortcut(.cancelAction)
                Button(DictionaryAppsCopy.saveWord) { model.saveEditor() }
                    .buttonStyle(.borderedProminent)
                    .tint(WindowColor.accent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("dictionary.editor.save")
            }
        }
    }

    /// The inline resolution: what collides, the one action that resolves it, and Keep editing.
    private func conflictRow(_ conflict: DictionaryConflict, draft: DictionaryTermDraft) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Label(conflict.message, systemImage: "exclamationmark.triangle")
                .windowFont(Tokens.Typography.body)
                .foregroundStyle(WindowColor.attention)
            HStack(spacing: Tokens.Spacing.s) {
                if let resolve = conflict.resolveTitle(for: draft) {
                    Button(resolve) { model.resolveConflict() }
                        .buttonStyle(.borderedProminent)
                        .tint(WindowColor.accent)
                        .accessibilityIdentifier("dictionary.editor.resolve")
                }
                Button(DictionaryAppsCopy.keepEditing) { model.keepEditing() }
            }
            .controlSize(.small)
        }
        .padding(Tokens.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Tokens.Radius.group).fill(WindowColor.attention.opacity(ScopedBannerStyle.fillOpacity)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dictionary.editor.conflict")
    }
}

// MARK: - Import (file or Contacts)

struct DictionaryImportSheet: View {
    @ObservedObject var model: DictionaryAppsSectionViewModel
    /// Contacts access and the "offered" flag, for the Contacts flow.
    let contacts: ContactsImportOffer

    var body: some View {
        if let session = model.importSession {
            VStack(alignment: .leading, spacing: Tokens.Spacing.l) {
                Text(session.title)
                    .windowFont(Tokens.Typography.section)
                    .accessibilityAddTraits(.isHeader)
                switch session.step {
                case .explainContacts: explanation
                case .requestingAccess: waiting
                case .preview: preview(session)
                }
            }
            .padding(Tokens.Spacing.xl)
            .frame(width: 520)
        }
    }

    /// Why, and what is read — before the system prompt.
    private var explanation: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            Text(ContactsImportCopy.explanation)
                .windowFont(Tokens.Typography.body)
                .fixedSize(horizontal: false, vertical: true)
            Text(ContactsImportCopy.scope)
                .windowFont(Tokens.Typography.meta)
                .foregroundStyle(WindowColor.secondaryInk)
            HStack {
                Spacer()
                Button(ContactsImportCopy.notNow) { model.cancelImport() }
                    .keyboardShortcut(.cancelAction)
                Button(ContactsImportCopy.proceed) { Task { await model.continueContactsImport(offer: contacts) } }
                    .buttonStyle(.borderedProminent)
                    .tint(WindowColor.accent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("dictionary.contacts.continue")
            }
        }
        .accessibilityIdentifier("dictionary.contacts.explain")
    }

    /// The system prompt is up; no action here can race it.
    private var waiting: some View {
        Text(ContactsImportCopy.waiting)
            .windowFont(Tokens.Typography.body)
            .foregroundStyle(WindowColor.secondaryInk)
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
            .accessibilityIdentifier("dictionary.contacts.waiting")
    }

    private func preview(_ session: DictionaryImportSession) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            if case .file(let name) = session.origin {
                Text(name)
                    .windowFont(Tokens.Typography.meta)
                    .foregroundStyle(WindowColor.secondaryInk)
            }
            Text(session.preview.summary)
                .windowFont(Tokens.Typography.body)
                .accessibilityIdentifier("dictionary.import.summary")
            if let failure = session.failureBanner {
                ScopedBanner(failure, onAction: session.failure == .S02 ? { model.commitImport() } : nil)
                    .accessibilityIdentifier("dictionary.import.failure")
            }
            if !session.preview.candidates.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(session.preview.candidates) { candidate in
                            ImportCandidateRow(candidate: candidate) { model.toggleImportCandidate(candidate.id) }
                        }
                    }
                }
                .frame(maxHeight: 300)
                .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.group).strokeBorder(WindowColor.separator, lineWidth: 1))
                .accessibilityIdentifier("dictionary.import.rows")
            }
            HStack(spacing: Tokens.Spacing.s) {
                if session.preview.newCount + session.preview.conflictCount > 1 {
                    Button(DictionaryAppsCopy.selectAll) { model.setAllImportCandidates(true) }
                    Button(DictionaryAppsCopy.selectNone) { model.setAllImportCandidates(false) }
                }
                Spacer()
                Button(DictionaryAppsCopy.cancel) { model.cancelImport() }
                    .keyboardShortcut(.cancelAction)
                Button(session.preview.commitTitle) { model.commitImport() }
                    .buttonStyle(.borderedProminent)
                    .tint(WindowColor.accent)
                    .disabled(!session.canCommit)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("dictionary.import.commit")
            }
            .controlSize(.small)
        }
    }
}

/// One import row: a checkbox for what can be added, the reason for what cannot.
struct ImportCandidateRow: View {
    let candidate: DictionaryImportCandidate
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.s) {
            if candidate.isSelectable {
                Toggle(candidate.spelling, isOn: Binding(get: { candidate.isSelected }, set: { _ in toggle() }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .accessibilityLabel(candidate.spelling)
            } else {
                Image(systemName: statusSymbol)
                    .foregroundStyle(WindowColor.secondaryInk)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                Text(candidate.spelling.isEmpty ? "—" : candidate.spelling)
                    .windowFont(Tokens.Typography.body)
                    .foregroundStyle(candidate.isSelectable ? WindowColor.ink : WindowColor.secondaryInk)
                Text(candidate.detail)
                    .windowFont(Tokens.Typography.meta)
                    .foregroundStyle(isConflict ? WindowColor.attention : WindowColor.secondaryInk)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Tokens.Spacing.s)
        .padding(.horizontal, Tokens.Spacing.m)
        .overlay(alignment: .top) { Rectangle().fill(WindowColor.separator).frame(height: 1) }
        .accessibilityElement(children: .combine)
    }

    private var isConflict: Bool {
        if case .conflict = candidate.status { return true }
        return false
    }

    private var statusSymbol: String {
        if case .rejected = candidate.status { return "xmark.circle" }
        return "checkmark.circle"
    }
}
