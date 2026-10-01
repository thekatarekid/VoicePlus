import Testing
import Engine
@testable import VoicePlusApp

/// I1 — the first-run "What to expect" card: the four promises, and voice-fix examples that are real.
struct OnboardingExpectationsTests {
    @Test func cardCoversTheFourExpectations() {
        #expect(OnboardingCopy.expectHeading == "What to expect")
        #expect(OnboardingCopy.expectItems.map(\.id) == ["local", "english", "names", "fix"])
        #expect(Set(OnboardingCopy.expectItems.map(\.id)).count == OnboardingCopy.expectItems.count)
        let text = OnboardingCopy.expectItems.map { $0.title + " " + $0.detail }.joined(separator: " ")
        #expect(text.contains("this Mac"))
        #expect(text.contains("English"))
        #expect(text.contains("Dictionary"))
        #expect(text.localizedCaseInsensitiveContains("by voice"))
    }

    @Test func voiceFixExamplesAreRealRepairCommands() {
        #expect(RepairGrammar.parse("scratch that") == .scratch)
        #expect(RepairGrammar.parse("no, Kothari") == .snap("kothari"))
        #expect(RepairGrammar.parse("put it back") == .undo)
        for phrase in OnboardingCopy.expectVoiceFixExamples {
            #expect(RepairGrammar.parse(phrase) != nil, "\(phrase) must be a repair the grammar accepts")
        }
        let fix = OnboardingCopy.expectItems.first { $0.id == "fix" }
        for phrase in OnboardingCopy.expectVoiceFixExamples {
            #expect(fix?.detail.contains("“\(phrase)”") == true, "the card should quote \(phrase)")
        }
    }

    @Test func copyStaysPlainAndShort() {
        for item in OnboardingCopy.expectItems {
            #expect(!item.title.isEmpty && item.title.count <= 40)
            #expect(item.detail.count <= 200)
            #expect(!item.detail.contains("!"))
        }
    }

    @Test func dictionaryActionOpensDictionary() {
        #expect(OnboardingReady.expectDictionarySection == .dictionary)
    }
}
