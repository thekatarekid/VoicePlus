import Pipeline
import SwiftUI

// V5 LANG1 — the Languages step card: plain names (no flags), a script picker only where a language
// has one (Hindi: Roman default, Devanagari, Mixed), the English spelling variant, and where to
// change it later. The selection lives in the state machine (`languageChoice`); every edit is an
// `.setLanguages` event, so the view holds no state of its own.

public extension OnboardingCopy {
    static let languagesHeading = "Which languages do you speak?"
    static let languagesBody = "VoicePlus listens for these, writes each one in the script you pick, and downloads only the speech models they need."
    static let languagesLater = "You can change this in Settings › Languages."
    static let languagesSpelling = "English spelling"
    static let languagesScript = "Write it in"
    static let languagesMore = "More languages"
}

struct OnboardingLanguagesStep: View {
    @ObservedObject var model: OnboardingViewModel
    @State private var showAll = false

    private var choice: LanguagePreferences { model.machine.languageChoice ?? LanguagePreferences() }

    /// Chosen languages first (in order), then the rest of the catalogue when expanded.
    private var rows: [LanguageOption] {
        let chosen = choice.languages.map(LanguagePreferences.option(for:))
        guard showAll else { return chosen }
        return chosen + LanguagePreferences.catalogue.filter { !choice.languages.contains($0.code) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(OnboardingCopy.languagesHeading).font(.title.bold())
            Text(OnboardingCopy.languagesBody).fixedSize(horizontal: false, vertical: true)
            ForEach(rows) { option in
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(option.name, isOn: Binding(
                        get: { choice.languages.contains(option.code) },
                        set: { toggle(option.code, on: $0) }))
                        .accessibilityIdentifier("onboarding.language.\(option.code)")
                    if option.hasScriptChoice, choice.languages.contains(option.code) {
                        Picker(OnboardingCopy.languagesScript, selection: Binding(
                            get: { choice.script(for: option.code) },
                            set: { setScript($0, for: option.code) })) {
                            ForEach(option.scripts, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .padding(.leading, 20)
                        .accessibilityIdentifier("onboarding.script.\(option.code)")
                    }
                }
            }
            Button(showAll ? "Fewer languages" : OnboardingCopy.languagesMore) { showAll.toggle() }
                .buttonStyle(.link)
            if choice.languages.contains("en") {
                Picker(OnboardingCopy.languagesSpelling, selection: Binding(
                    get: { choice.spelling },
                    set: { var c = choice; c.spelling = $0; model.send(.setLanguages(c)) })) {
                    ForEach(SpellingVariant.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("onboarding.spelling")
            }
            Text(OnboardingCopy.languagesLater).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func toggle(_ code: String, on: Bool) {
        var c = choice
        if on { if !c.languages.contains(code) { c.languages.append(code) } }
        else { c.languages.removeAll { $0 == code } }
        model.send(.setLanguages(c))   // the machine refuses an empty selection
    }

    private func setScript(_ script: OutputScript, for code: String) {
        var c = choice
        c.scriptByLanguage[code] = script
        model.send(.setLanguages(c))
    }
}
