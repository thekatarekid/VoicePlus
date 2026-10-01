import Foundation
import Injection
import Pipeline
import Shared
import Testing
@testable import VoicePlusApp

/// V5 E6 — the reader fills `thread.participants`; a per-recipient persona override applies.
@Suite("V5 E6 · thread participants wiring")
struct ThreadParticipantsWiringTests {

    final class MockParticipants: ThreadParticipantsReading {
        var observation = ThreadParticipants.Observation()
        private(set) var reads = 0
        func observe(pid: Int32, category: AppCategory) -> ThreadParticipants.Observation { reads += 1; return observation }
    }

    private func reader(bundle: String, participants: MockParticipants, contextual: Bool = true) -> FieldContextReader {
        let s = MockSystemAccess(frontmost: FocusSnapshot(pid: 7777, bundleID: bundle, appName: "App", elementToken: "el"))
        s.field = .init(role: "AXTextArea", value: "", hints: [])
        let r = FieldContextReader(system: s, unknownApps: UnknownApps(log: Log(category: "test")), participants: participants)
        r.contextualReading = { _ in contextual }
        return r
    }

    @Test
    func mailComposeFillsParticipantsAndTheOverrideApplies() throws {
        let p = MockParticipants()
        p.observation = .init(fields: [.init(label: "To:", value: "Dr. Rao <rao@uni.edu>")])
        let field = try #require(reader(bundle: "com.apple.mail", participants: p).fieldContext(bundleID: "com.apple.mail"))
        #expect(field.participants == ["Dr. Rao <rao@uni.edu>"])

        let manager = PersonaManager(store: InMemoryPersonaStore())
        _ = try manager.setText("warm", for: "com.apple.mail")
        _ = try manager.setRecipientOverride("very formal", recipient: "rao@uni.edu", for: "com.apple.mail")
        var ctx = manager.decorate(StageContext(appBundleID: "com.apple.mail"))
        #expect(ctx.extra[PersonaManager.promptKey] == "warm")
        FieldRolePipeline.write(field, into: &ctx)
        FieldPersonaRedecoration.apply(field, to: &ctx, manager: manager)
        #expect(ctx.extra[PersonaManager.promptKey]?.contains("very formal") == true)
    }

    @Test
    func slackChannelTitle() throws {
        let p = MockParticipants()
        p.observation = .init(title: "launch (Channel) - Acme - Slack")
        let field = try #require(reader(bundle: "com.tinyspeck.slackmacgap", participants: p)
            .fieldContext(bundleID: "com.tinyspeck.slackmacgap"))
        #expect(field.participants == ["launch"])
    }

    @Test
    func proseAppsAndContextualReadingOffReadNothing() {
        let p = MockParticipants()
        _ = reader(bundle: "com.apple.TextEdit", participants: p).fieldContext(bundleID: "com.apple.TextEdit")
        _ = reader(bundle: "com.apple.mail", participants: p, contextual: false).fieldContext(bundleID: "com.apple.mail")
        #expect(p.reads == 0)
    }

    @Test
    func noOverrideLeavesThePersonaAlone() throws {
        let manager = PersonaManager(store: InMemoryPersonaStore())
        _ = try manager.setText("warm", for: "com.apple.mail")
        var ctx = manager.decorate(StageContext(appBundleID: "com.apple.mail"))
        let field = FieldContext(appBundleID: "com.apple.mail", axRole: "AXTextArea", participants: ["Nobody"])
        FieldRolePipeline.write(field, into: &ctx)
        FieldPersonaRedecoration.apply(field, to: &ctx, manager: manager)
        #expect(ctx.extra[PersonaManager.promptKey] == "warm")
    }
}
