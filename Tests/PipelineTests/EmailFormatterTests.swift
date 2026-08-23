import Foundation
import Shared
import Testing
@testable import Pipeline

/// P1.7 T2 golden tests for `EmailFormatter`.
@Suite struct EmailFormatterTests {
    let formatter = EmailFormatter()

    private func span(_ text: String, confidence: Float = 0.95, range: ClosedRange<TimeInterval>) -> TranscriptSpan {
        TranscriptSpan(text: text, confidence: confidence, audioRange: range, provenance: [.asr])
    }

    private func format(_ text: String) -> String {
        FormattedText.join(formatter.format([span(text, range: 0...1)]))
    }

    /// Golden input → output cases (single high-confidence span).
    static let golden: [(String, String)] = [
        // Sentence punctuation / capitalisation
        ("i will send the report tomorrow", "I will send the report tomorrow."),
        ("the meeting went well. we should do it again", "The meeting went well. We should do it again."),
        ("can you review the draft", "Can you review the draft."),
        ("sure thing. i'll get on it. thanks for asking", "Sure thing. I'll get on it. Thanks for asking."),
        ("i think i'm free on monday", "I think I'm free on Monday."),
        ("it is ready,", "It is ready."),
        // Fillers
        ("um i wanted to follow up on the invoice", "I wanted to follow up on the invoice."),
        ("so, um, we should uh move the deadline", "So, we should move the deadline."),
        ("the numbers look good hmm let me double check", "The numbers look good let me double check."),
        ("uh huh er the plan is fine", "The plan is fine."),
        // Self-correction
        ("let's meet on friday — no, thursday", "Let's meet on Thursday."),
        ("let's meet on friday no thursday at noon", "Let's meet on Thursday at noon."),
        ("send it to john smith, i mean jane doe", "Send it to jane doe."),
        ("the budget is four thousand, sorry, five thousand dollars", "The budget is five thousand dollars."),
        ("we need it by tuesday no wait wednesday", "We need it by Wednesday."),
        ("they said no thanks to the offer", "They said no thanks to the offer."),
        ("there is no problem with the delivery", "There is no problem with the delivery."),
        // Spoken punctuation & commands
        ("thanks for the update period i will review it", "Thanks for the update. I will review it."),
        ("did you get the file question mark", "Did you get the file?"),
        ("great news exclamation point we closed the deal", "Great news! We closed the deal."),
        ("first draft attached comma final version next week", "First draft attached, final version next week."),
        ("it was a long period of waiting", "It was a long period of waiting."),
        ("see the first paragraph new paragraph the second one covers pricing", "See the first paragraph.\n\nThe second one covers pricing."),
        ("sent from my phone new line please excuse typos", "Sent from my phone\nPlease excuse typos."),
        // Greetings
        ("hi john i wanted to check in on the proposal", "Hi John,\n\nI wanted to check in on the proposal."),
        ("hello team, the release is scheduled for friday", "Hello Team,\n\nThe release is scheduled for Friday."),
        ("good morning sarah, thanks for the quick turnaround", "Good morning Sarah,\n\nThanks for the quick turnaround."),
        ("hi all quick reminder about the standup", "Hi all,\n\nQuick reminder about the standup."),
        ("dear mr patel, please find the contract attached", "Dear Mr Patel,\n\nPlease find the contract attached."),
        ("hey there just checking in", "Hey there,\n\nJust checking in."),
        ("hi john and mary, the demo is at three", "Hi John and Mary,\n\nThe demo is at three."),
        // Sign-offs
        ("let me know if that works thanks john", "Let me know if that works.\n\nThanks,\nJohn"),
        ("i'll send the slides tonight. best regards, priya", "I'll send the slides tonight.\n\nBest regards,\nPriya"),
        ("looking forward to it cheers", "Looking forward to it.\n\nCheers,"),
        ("talk to you then. kind regards alex chen", "Talk to you then.\n\nKind regards,\nAlex Chen"),
        ("this is the best", "This is the best."),
        ("thanks for your help with this", "Thanks for your help with this."),
        ("thanks so much maria", "Thanks so much,\nMaria"),
        // Full email
        ("hi maria um i reviewed the doc — no, the deck new paragraph it looks great thank you sam",
         "Hi Maria,\n\nI reviewed the deck.\n\nIt looks great.\n\nThank you,\nSam"),
        // Lists
        ("we need three things first, milk second, eggs and finally, bread", "We need three things:\n1. Milk\n2. Eggs\n3. Bread"),
        ("please do the following firstly update the spec secondly notify the client", "Please do the following:\n1. Update the spec\n2. Notify the client"),
        ("action items bullet fix the login bug bullet point ship the patch", "Action items:\n- Fix the login bug\n- Ship the patch"),
        ("steps number one open settings number two enable sync", "Steps:\n1. Open settings\n2. Enable sync"),
        ("first of all thanks for the intro", "First of all thanks for the intro."),
        ("i finished first in the race", "I finished first in the race."),
        // Already formatted input is left alone
        ("Hi Tom,\n\nThe invoice is attached.\n\nThanks,\nAnna", "Hi Tom,\n\nThe invoice is attached.\n\nThanks,\nAnna"),
    ]

    @Test(arguments: golden)
    func goldenCase(input: String, expected: String) {
        #expect(format(input) == expected, "input: \(input)")
    }

    @Test func emptyInputReturnsEmpty() async throws {
        let out = try await formatter.process([], context: StageContext(register: .email))
        #expect(out.isEmpty)
    }

    @Test func isDeterministic() {
        let input = "hi um john no jane let's meet friday thanks bob"
        #expect(format(input) == format(input))
    }

    // MARK: - Multi-span + confidence contract

    @Test func multiSpanRebuildPreservesRangesAndProvenance() {
        let input = [
            span("hi john", range: 0...0.5),
            span("um", range: 0.5...0.7),
            span("i wanted to check in", range: 0.7...1.5),
            span("thanks sam", range: 1.5...2.0),
        ]
        let out = formatter.format(input)
        #expect(ConfidenceContract.verify(input: input, output: out) == [])
        #expect(FormattedText.join(out) == "Hi John,\n\nI wanted to check in.\n\nThanks,\nSam")
        #expect(out.allSatisfy { $0.provenance.last == .formatterEmail })
        // The filler-only span was merged into its predecessor; audio coverage is intact.
        #expect(out.count == 3)
        #expect(out[0].audioRange == 0...0.7)
        #expect(out.map(\.confidence) == [0.95, 0.95, 0.95])
    }

    @Test func lowConfidenceSpanIsFlaggedNotRewritten() {
        let input = [
            span("the call with", range: 0...0.8),
            span("team fuel h e", confidence: 0.3, range: 0.8...1.6),
            span("um went fine", range: 1.6...2.2),
        ]
        let out = formatter.format(input)
        #expect(ConfidenceContract.verify(input: input, output: out) == [])
        #expect(out.count == 3)
        #expect(out[1].text == "team fuel h e")
        #expect(out[1].needsRepair)
        #expect(out[1].confidence == 0.3)
        #expect(!out[0].needsRepair)
        #expect(out[0].text == "The call with")
        #expect(out[2].text == "went fine.")
    }

    @Test func lowConfidenceFillerIsNeverRemoved() {
        let input = [span("hello", range: 0...0.3), span("um", confidence: 0.2, range: 0.3...0.5), span("there", range: 0.5...0.8)]
        let out = formatter.format(input)
        #expect(ConfidenceContract.verify(input: input, output: out) == [])
        #expect(out[1].text == "um")
        #expect(out[1].needsRepair)
    }

    @Test func lowConfidenceSelfCorrectionIsNotResolved() {
        let input = [span("meet on", range: 0...0.5), span("friday", confidence: 0.4, range: 0.5...0.8), span("no thursday", range: 0.8...1.3)]
        let out = formatter.format(input)
        #expect(ConfidenceContract.verify(input: input, output: out) == [])
        #expect(out[1].text == "friday")
        #expect(out[1].needsRepair)
        #expect(FormattedText.join(out).lowercased().contains("friday no thursday"))
    }

    @Test func poisonedSpanSurvivesWholeStage() async throws {
        let poisoned = span("kothari", confidence: 0.1, range: 0.5...1.0)
        let input = [span("hi", range: 0...0.5), poisoned, span("thanks", range: 1.0...1.5)]
        let out = try await formatter.process(input, context: StageContext(register: .email))
        #expect(ConfidenceContract.verify(input: input, output: out) == [])
        let survivor = try #require(out.first { $0.audioRange == poisoned.audioRange })
        #expect(survivor.text == "kothari")
        #expect(survivor.needsRepair)
        #expect(survivor.alternates == poisoned.alternates)
    }

    @Test func allFillerUtteranceKeepsAudioRange() {
        let input = [span("um", range: 0...0.3), span("uh", range: 0.3...0.6)]
        let out = formatter.format(input)
        #expect(ConfidenceContract.verify(input: input, output: out) == [])
        #expect(FormattedText.join(out) == "")
    }

    @Test func registeredInStageRegistry() {
        #expect(StageRegistry.formatter(for: .email)?.id == .formatterEmail)
    }
}
