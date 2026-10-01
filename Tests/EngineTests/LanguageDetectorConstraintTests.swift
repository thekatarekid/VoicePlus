import Testing
@testable import Engine

/// V5 LANG1 — the detector guesses only the languages the user chose.
@Suite struct LanguageDetectorConstraintTests {
    @Test func codesMapToTheDetectorsLanguages() {
        #expect(LanguageDetector.allowedLanguages(fromCodes: []) == nil)
        #expect(LanguageDetector.allowedLanguages(fromCodes: ["en"]) == [.english])
        #expect(LanguageDetector.allowedLanguages(fromCodes: ["en-IN", "hi_IN"]) == [.english, .hindi])
        #expect(LanguageDetector.allowedLanguages(fromCodes: ["hi"]) == [.hindi])
        #expect(LanguageDetector.allowedLanguages(fromCodes: ["fr", "de"]) == [.english])   // Latin, never Hindi
    }

    @Test func unconstrainedGuessesRomanHindi() {
        #expect(LanguageDetector.detect("kya hai bhai").language == .hindi)
        #expect(LanguageDetector.detect("kal meeting hai please confirm").language == .mixed)
    }

    @Test func withoutHindiNoLatinWordIsGuessedHindi() {
        let d = LanguageDetector.detect("kya haal hai bhai", allowed: [.english])
        #expect(d.language == .english)
        #expect(!LanguageDetector.isHindiWord("hai", allowed: [.english]))
    }

    @Test func hindiOnlyNeverGuessesEnglish() {
        #expect(LanguageDetector.detect("meeting kal hai", allowed: [.hindi]).language == .hindi)
    }

    @Test func devanagariIsHindiWhateverTheConstraint() {
        let d = LanguageDetector.detect("नमस्ते", allowed: [.english])
        #expect(d.language == .hindi)
    }

    @Test func streamingDetectorKeepsItsConstraint() {
        var detector = LanguageDetector(allowed: [.english])
        detector.feed("kya")
        #expect(detector.feed("hai").language == .english)
        #expect(LanguageDetector.isHindiWord("hai", allowed: [.english, .hindi]))
        #expect(!LanguageDetector.isHindiWord("meeting", allowed: [.english, .hindi]))
    }
}
