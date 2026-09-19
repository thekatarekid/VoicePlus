import Engine
import Foundation
import Shared

// S7e — Voice › Recognition › Language (design §8.4): "Language choice includes a model-capability
// explanation and mixed-script preview; do not promise unsupported languages."
//
// The picker offers Automatic plus exactly the languages the recognizer that would run right now can
// recognize (`ModelManaging.stackReadiness`); nothing else is ever listed. The note under it says
// what that recognizer does with language — Parakeet TDT 0.6B v3 identifies the language of each
// dictation itself, so a choice is a saved preference, never a switch that forces recognition. The
// mixed-script preview shows a sentence that mixes scripts and marks, per script, whether the
// installed model can write it — Devanagari included, because Hindi + English is the case the app's
// code-switch path exists for and the default model cannot write it.

// MARK: - The setting

/// The saved dictation language: a BCP-47 language code, or `automatic`.
public enum VoiceLanguageSettings {
    public static let key = "voice.language"
    public static let automatic = "auto"

    public static func code(_ store: SettingsStore?) -> String {
        store?.string(key) ?? automatic
    }

    public static func setCode(_ code: String, store: SettingsStore?) {
        store?.set(code, for: key)
    }
}

// MARK: - Scripts

/// The writing systems the Voice preview distinguishes. `Engine.Script` knows Latin and Devanagari
/// only; the preview also has to name Cyrillic and Greek, which Parakeet v3 writes.
public enum WritingScript: String, CaseIterable, Sendable {
    case latin, cyrillic, greek, devanagari, other

    public var name: String {
        switch self {
        case .latin: return "Latin"
        case .cyrillic: return "Cyrillic"
        case .greek: return "Greek"
        case .devanagari: return "Devanagari"
        case .other: return "Other scripts"
        }
    }

    /// nil for anything that takes its word's script: spaces, digits, punctuation, marks.
    public static func of(_ scalar: Unicode.Scalar) -> WritingScript? {
        switch scalar.value {
        case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x024F: return .latin
        case 0x0370...0x03FF, 0x1F00...0x1FFF: return .greek
        case 0x0400...0x052F: return .cyrillic
        case 0x0900...0x097F, 0xA8E0...0xA8FF:
            if scalar.value == 0x0964 || scalar.value == 0x0965 { return nil }
            let category = scalar.properties.generalCategory
            if category == .nonspacingMark || category == .spacingMark { return nil }
            return .devanagari
        default:
            return scalar.properties.isAlphabetic ? .other : nil
        }
    }
}

// MARK: - Languages

public struct VoiceLanguage: Equatable, Identifiable, Sendable {
    public var code: String
    public var name: String
    public var script: WritingScript
    public var id: String { code }

    public init(_ code: String, _ name: String, _ script: WritingScript) {
        self.code = code
        self.name = name
        self.script = script
    }

    /// Parakeet TDT 0.6B v3's 25 European languages (NVIDIA model card), with automatic language
    /// identification.
    public static let parakeetV3: [VoiceLanguage] = [
        .init("bg", "Bulgarian", .cyrillic), .init("hr", "Croatian", .latin), .init("cs", "Czech", .latin),
        .init("da", "Danish", .latin), .init("nl", "Dutch", .latin), .init("en", "English", .latin),
        .init("et", "Estonian", .latin), .init("fi", "Finnish", .latin), .init("fr", "French", .latin),
        .init("de", "German", .latin), .init("el", "Greek", .greek), .init("hu", "Hungarian", .latin),
        .init("it", "Italian", .latin), .init("lv", "Latvian", .latin), .init("lt", "Lithuanian", .latin),
        .init("mt", "Maltese", .latin), .init("pl", "Polish", .latin), .init("pt", "Portuguese", .latin),
        .init("ro", "Romanian", .latin), .init("ru", "Russian", .cyrillic), .init("sk", "Slovak", .latin),
        .init("sl", "Slovenian", .latin), .init("es", "Spanish", .latin), .init("sv", "Swedish", .latin),
        .init("uk", "Ukrainian", .cyrillic),
    ]

    public static let english = VoiceLanguage("en", "English", .latin)
    public static let hindi = VoiceLanguage("hi", "Hindi", .devanagari)
}

/// One row of the language picker.
public struct VoiceLanguageOption: Equatable, Identifiable, Sendable {
    public var code: String
    public var title: String
    public var id: String { code }
}

/// What the recognizer that would run right now can do with language.
public struct VoiceLanguageCapability: Equatable, Sendable {
    public enum Recognizer: Equatable, Sendable {
        /// Parakeet TDT 0.6B v3: 25 languages, identified per dictation.
        case multilingual(name: String)
        /// A model that recognizes one language (the 110M fallback: English).
        case single(name: String, language: VoiceLanguage)
        /// macOS' on-device recognizer, in the Mac's own language.
        case system(name: String, language: VoiceLanguage)
        /// A recognizer whose languages VoicePlus cannot state.
        case unknown(name: String)
        /// Nothing can transcribe yet.
        case none
    }

    public var recognizer: Recognizer

    public init(_ recognizer: Recognizer) { self.recognizer = recognizer }

    /// From `ModelManaging.stackReadiness`: the stack's display names are the catalogue's, so the
    /// match is exact. `locale` names the language macOS' recognizer would use.
    public static func resolve(_ readiness: RecognizerReadiness?, locale: Locale = .current) -> VoiceLanguageCapability {
        guard let name = readiness?.recognizerName else { return VoiceLanguageCapability(.none) }
        if name == ModelCatalog.descriptor(.parakeetTDTv3).displayName { return VoiceLanguageCapability(.multilingual(name: name)) }
        if name == ModelCatalog.descriptor(.parakeetTDTCTC110m).displayName {
            return VoiceLanguageCapability(.single(name: name, language: .english))
        }
        if name.localizedCaseInsensitiveContains("Apple Speech") {
            return VoiceLanguageCapability(.system(name: name, language: systemLanguage(locale)))
        }
        return VoiceLanguageCapability(.unknown(name: name))
    }

    static func systemLanguage(_ locale: Locale) -> VoiceLanguage {
        let code = locale.language.languageCode?.identifier ?? "en"
        let name = Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
        let script: WritingScript = VoiceLanguage.parakeetV3.first { $0.code == code }?.script
            ?? (code == "hi" ? .devanagari : .latin)
        return VoiceLanguage(code, name, script)
    }

    /// The languages this recognizer can recognize — the only ones the picker may list.
    public var languages: [VoiceLanguage] {
        switch recognizer {
        case .multilingual: return VoiceLanguage.parakeetV3
        case .single(_, let language), .system(_, let language): return [language]
        case .unknown, .none: return []
        }
    }

    public var recognizerName: String? {
        switch recognizer {
        case .multilingual(let name), .single(let name, _), .system(let name, _), .unknown(let name): return name
        case .none: return nil
        }
    }

    /// The scripts it writes.
    public var scripts: Set<WritingScript> { Set(languages.map(\.script)) }

    public func supports(_ code: String) -> Bool { code == VoiceLanguageSettings.automatic || languages.contains { $0.code == code } }

    /// The picker's rows: Automatic, then the supported languages by name.
    public var options: [VoiceLanguageOption] {
        [VoiceLanguageOption(code: VoiceLanguageSettings.automatic, title: VoiceLanguageCopy.automatic)]
            + languages.sorted { $0.name < $1.name }.map { VoiceLanguageOption(code: $0.code, title: $0.name) }
    }

    /// The model-capability explanation under the picker.
    public var note: String {
        switch recognizer {
        case .multilingual(let name):
            return "\(name) recognizes \(languages.count) European languages and works out which one you are speaking in every dictation. Languages it cannot recognize, such as Hindi, Arabic or Japanese, are not offered."
        case .single(let name, let language):
            return "\(name) recognizes \(language.name) only. Other languages come out as \(language.name)-sounding words, so they are not offered."
        case .system(let name, let language):
            return "\(name) uses your Mac's language, \(language.name). It is the only language offered until a speech model is installed."
        case .unknown(let name):
            return "VoicePlus can't tell which languages \(name) recognizes, so only Automatic is offered."
        case .none:
            return VoiceLanguageCopy.noModel
        }
    }

    /// What a saved choice means with this recognizer. Never claims a switch the model does not have.
    public func choiceNote(for code: String) -> String? {
        guard code != VoiceLanguageSettings.automatic, let language = languages.first(where: { $0.code == code }) else { return nil }
        switch recognizer {
        case .multilingual:
            return "\(language.name) is saved as your dictation language. The model still identifies the spoken language itself."
        default:
            return nil
        }
    }
}

// MARK: - Mixed-script preview

/// A sentence that mixes scripts, split into runs, each marked with whether the installed recognizer
/// writes that script.
public struct VoiceScriptPreview: Equatable, Sendable {
    public struct Run: Equatable, Sendable {
        public var text: String
        /// nil for spaces and punctuation between words.
        public var script: WritingScript?
        public var supported: Bool
    }

    /// One script in the sample, and whether the installed recognizer writes it.
    public struct ScriptSupport: Equatable, Sendable {
        public var script: WritingScript
        public var supported: Bool
    }

    public var sample: String
    public var runs: [Run]
    /// The scripts in the sample, in order of first appearance.
    public var scripts: [ScriptSupport]

    /// One line per script: "Latin — written", "Devanagari — not recognized by Parakeet TDT 0.6B v3".
    public func lines(recognizer: String?) -> [String] {
        scripts.map { entry in
            entry.supported
                ? "\(entry.script.name) — written as spoken"
                : "\(entry.script.name) — not recognized by \(recognizer ?? "the installed model")"
        }
    }

    /// Mixed English + language samples. Each mixes a second script where the language has one.
    static let samples: [String: String] = [
        "ru": "Send the slides to Марии before обед.",
        "uk": "Call Олена after the standup, дякую.",
        "bg": "Book the room for Иван, благодаря.",
        "el": "Share the notes with Νίκος, ευχαριστώ.",
        "de": "Move the review to Freitag, danke.",
        "fr": "Move the review to vendredi, merci.",
        "es": "Move the review to viernes, gracias.",
        "hi": "Kal ki meeting 3 बजे है, please confirm.",
    ]

    /// The preview for a saved choice: the chosen language mixed with English; for Automatic or
    /// English, a supported second script when the model writes one, otherwise Hindi + English.
    public static func make(capability: VoiceLanguageCapability, selection: String) -> VoiceScriptPreview {
        let chosen = samples[selection]
        let secondScript = capability.languages.first { $0.script != .latin && samples[$0.code] != nil }
        let sample = chosen ?? secondScript.flatMap { samples[$0.code] } ?? samples["hi"]!
        return build(sample, writes: capability.scripts)
    }

    /// Hindi + English, always: the code-switch case the default model cannot write.
    public static func devanagari(capability: VoiceLanguageCapability) -> VoiceScriptPreview {
        build(samples["hi"]!, writes: capability.scripts)
    }

    static func build(_ sample: String, writes: Set<WritingScript>) -> VoiceScriptPreview {
        var runs: [Run] = []
        var order: [WritingScript] = []
        var word = ""
        var wordScript: WritingScript?
        var gap = ""
        func flushWord() {
            guard !word.isEmpty else { return }
            let script = wordScript ?? .latin
            if !order.contains(script) { order.append(script) }
            runs.append(Run(text: word, script: script, supported: writes.contains(script)))
            word = ""
            wordScript = nil
        }
        func flushGap() {
            guard !gap.isEmpty else { return }
            runs.append(Run(text: gap, script: nil, supported: true))
            gap = ""
        }
        for character in sample {
            let isWordCharacter = character.isLetter || character.isNumber
                || character.unicodeScalars.contains { $0.properties.generalCategory == .nonspacingMark || $0.properties.generalCategory == .spacingMark }
            if isWordCharacter {
                flushGap()
                word.append(character)
                if wordScript == nil { wordScript = character.unicodeScalars.lazy.compactMap(WritingScript.of).first }
            } else {
                flushWord()
                gap.append(character)
            }
        }
        flushWord()
        flushGap()
        // Digits alone carry no script: they take Latin (written by every model here).
        return VoiceScriptPreview(sample: sample, runs: runs,
                                  scripts: order.map { ScriptSupport(script: $0, supported: writes.contains($0)) })
    }
}

public enum VoiceLanguageCopy {
    public static let rowTitle = "Language"
    public static let rowDetail = "Only languages supported by your installed model."
    public static let automatic = "Automatic"
    public static let previewTitle = "Mixed-script preview"
    public static let noModel = "Install a speech model to see which languages it recognizes."
}
