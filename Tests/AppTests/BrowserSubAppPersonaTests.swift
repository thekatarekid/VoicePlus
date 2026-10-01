import Foundation
import Injection
import Pipeline
import Shared
import Testing
@testable import VoicePlusApp

/// V5 E5 — the reader carries the sub-app out of the browser and the persona is keyed `bundle|host`.
@Suite("V5 E5 · browser sub-app persona")
struct BrowserSubAppPersonaTests {

    final class TitleDetails: FocusedFieldDetailsReading {
        var title: String?
        private(set) var titleReads = 0
        func focusedFieldLabels(pid: Int32) -> [String] { [] }
        func focusedCellColumnHeader(pid: Int32) -> String? { nil }
        func focusedDocumentTitle(pid: Int32) -> String? { titleReads += 1; return title }
    }

    private func system(bundle: String, url: String?) -> MockSystemAccess {
        let s = MockSystemAccess(frontmost: FocusSnapshot(pid: 7777, bundleID: bundle, appName: "App", elementToken: "el"))
        s.field = .init(role: "AXTextArea", value: "", hints: [])
        s.documentURL = url
        return s
    }

    @Test
    func urlWinsAndTheTitleIsNotRead() throws {
        let details = TitleDetails()
        details.title = "Slack"
        let reader = FieldContextReader(system: system(bundle: "com.google.Chrome", url: "https://mail.google.com/mail/u/0/"),
                                        unknownApps: UnknownApps(log: Log(category: "test")), details: details)
        let field = try #require(reader.fieldContext(bundleID: "com.google.Chrome"))
        #expect(field.subApp?.host == "mail.google.com")
        #expect(details.titleReads == 0)
    }

    @Test
    func titleRoutesWhenTheURLIsHidden() throws {
        let details = TitleDetails()
        details.title = "general (Channel) - Acme - Slack"
        let reader = FieldContextReader(system: system(bundle: "com.brave.Browser", url: nil),
                                        unknownApps: UnknownApps(log: Log(category: "test")), details: details)
        let field = try #require(reader.fieldContext(bundleID: "com.brave.Browser"))
        #expect(field.subApp?.category == .chat)
        #expect(field.personaKey == "com.brave.Browser|app.slack.com")
    }

    @Test
    func personaIsKeyedByBundleAndHost() throws {
        let store = InMemoryPersonaStore()
        let manager = PersonaManager(store: store)
        _ = try manager.setText("terse, lowercase", for: "com.google.Chrome|app.slack.com")
        _ = try manager.setText("chrome default", for: "com.google.Chrome")
        var ctx = manager.decorate(StageContext(appBundleID: "com.google.Chrome"))
        #expect(ctx.extra[PersonaManager.promptKey] == "chrome default")
        let field = FieldContext(appBundleID: "com.google.Chrome", axRole: "AXTextArea",
                                 documentURL: "https://app.slack.com/client/T/C")
        FieldRolePipeline.write(field, into: &ctx)
        FieldPersonaRedecoration.apply(field, to: &ctx, manager: manager)
        #expect(ctx.extra[PersonaManager.promptKey] == "terse, lowercase")
        #expect(ctx.appBundleID == "com.google.Chrome", "the run's bundle ID is unchanged")
    }

    @Test
    func unknownSiteKeepsTheBrowserPersona() {
        let manager = PersonaManager(store: InMemoryPersonaStore())
        _ = try? manager.setText("chrome default", for: "com.google.Chrome")
        var ctx = manager.decorate(StageContext(appBundleID: "com.google.Chrome"))
        let field = FieldContext(appBundleID: "com.google.Chrome", axRole: "AXTextArea", documentURL: "https://example.com/")
        FieldRolePipeline.write(field, into: &ctx)
        FieldPersonaRedecoration.apply(field, to: &ctx, manager: manager)
        #expect(ctx.extra[PersonaManager.promptKey] == "chrome default")
    }

    @Test
    func subAppAutoDraftFollowsItsCategory() throws {
        let manager = PersonaManager(store: InMemoryPersonaStore())
        var ctx = StageContext(appBundleID: "com.google.Chrome")
        let field = FieldContext(appBundleID: "com.google.Chrome", axRole: "AXTextArea",
                                 documentURL: "https://mail.google.com/mail/u/0/")
        FieldRolePipeline.write(field, into: &ctx)
        FieldPersonaRedecoration.apply(field, to: &ctx, manager: manager)
        #expect(ctx.extra[PersonaManager.promptKey]?.contains("email") == true)
    }
}
