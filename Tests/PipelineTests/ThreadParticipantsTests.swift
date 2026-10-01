import Foundation
import Shared
import Testing
@testable import Pipeline

/// V5 E6 — thread participants out of what the accessibility tree shows.
@Suite("V5 E6 · thread participants")
struct ThreadParticipantsTests {

    @Test
    func mailReadsToAndCcNotBcc() {
        let obs = ThreadParticipants.Observation(fields: [
            .init(label: "To:", value: "Priya Kothari <priya@x.io>, rao@uni.edu"),
            .init(label: "Cc", value: "Sam; priya kothari <priya@x.io>"),
            .init(label: "Bcc:", value: "secret@x.io"),
            .init(label: "Subject:", value: "Q3 plan"),
        ])
        let names = ThreadParticipants.extract(category: .mail, observation: obs)
        #expect(names == ["Priya Kothari <priya@x.io>", "rao@uni.edu", "Sam"])
    }

    @Test
    func gmailRecipientLabel() {
        let obs = ThreadParticipants.Observation(fields: [.init(label: "To recipients", value: "Dr. Rao")])
        #expect(ThreadParticipants.extract(category: .mail, observation: obs) == ["Dr. Rao"])
    }

    @Test(arguments: [
        ("general (Channel) - Acme - Slack", "general"),
        ("Slack | Priya Kothari (DM) | Acme", "Priya Kothari"),
        ("* (3) design-team - Acme - Slack - Google Chrome", "design-team"),
        ("#launch | Acme", "launch"),
        ("Mom", "Mom"),
    ])
    func chatTitle(title: String, expected: String) {
        #expect(ThreadParticipants.chatTitle(from: title) == expected)
    }

    @Test
    func appNameOnlyTitleFallsBackToTheHeading() {
        let obs = ThreadParticipants.Observation(title: "(2) WhatsApp", heading: "Family")
        #expect(ThreadParticipants.extract(category: .chat, observation: obs) == ["Family"])
        #expect(ThreadParticipants.extract(category: .chat, observation: .init(title: "WhatsApp")) == [])
    }

    @Test
    func noThreadOutsideMailAndChat() {
        let obs = ThreadParticipants.Observation(fields: [.init(label: "To", value: "x")], title: "general - Slack")
        #expect(ThreadParticipants.extract(category: .prose, observation: obs).isEmpty)
        #expect(ThreadParticipants.extract(category: .code, observation: obs).isEmpty)
    }

    @Test
    func participantsTravelInTheStageContextAndPersonasReadThem() {
        let field = FieldContext(appBundleID: "com.apple.mail", axRole: "AXTextArea",
                                 participants: ["Priya Kothari <priya@x.io>", "Smith, John"])
        var ctx = StageContext()
        field.write(into: &ctx)
        #expect(ctx.extra["thread.participants"] == "Priya Kothari <priya@x.io>, Smith  John")
        #expect(StageContextParticipants().participants(context: ctx).count == 2)
        #expect(FieldContext(stageContext: ctx).participants.count == 2)
    }

    @Test
    func overLongAndEmptyPiecesAreDropped() {
        let long = String(repeating: "a", count: 200)
        #expect(ThreadParticipants.recipients(in: " , \(long); Sam ,") == ["Sam"])
    }
}
