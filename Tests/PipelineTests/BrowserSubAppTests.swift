import Foundation
import Shared
import Testing
@testable import Pipeline

/// V5 E5 — browser sub-app routing: the focused web area's URL/title → category, persona key.
@Suite("V5 E5 · browser sub-app routing")
struct BrowserSubAppTests {

    @Test(arguments: [
        ("https://mail.google.com/mail/u/0/#inbox?compose=new", AppCategory.mail, "mail.google.com"),
        ("https://outlook.office.com/mail/deeplink/compose", .mail, "outlook.office.com"),
        ("https://app.slack.com/client/T1/C2", .chat, "app.slack.com"),
        ("https://web.whatsapp.com/", .chat, "web.whatsapp.com"),
        ("https://discord.com/channels/1/2", .chat, "discord.com"),
        ("https://github.com/apple/swift/blob/main/README.md", .code, "github.com"),
        ("https://github.com/apple/swift/pull/123/files", .prose, "github.com"),
        ("https://github.com/apple/swift/issues/9", .prose, "github.com"),
        ("https://www.notion.so/team/page-1", .prose, "notion.so"),
        ("https://vscode.dev/github/x/y", .code, "vscode.dev"),
        ("https://mail.google.com/chat/u/0/#chat/space/X", .chat, "mail.google.com"),
    ])
    func urlRoutesByHost(url: String, category: AppCategory, host: String) throws {
        let sub = try #require(BrowserSubApp.resolve(url: url))
        #expect(sub.category == category)
        #expect(sub.host == host)
    }

    @Test
    func sheetsIsASpreadsheetDocsIsNot() throws {
        #expect(try #require(BrowserSubApp.resolve(url: "https://docs.google.com/spreadsheets/d/x/edit")).isSpreadsheet)
        #expect(try #require(BrowserSubApp.resolve(url: "https://docs.google.com/document/d/x/edit")).isSpreadsheet == false)
    }

    @Test
    func unknownSiteIsNil() {
        #expect(BrowserSubApp.resolve(url: "https://example.com/blog") == nil)
        #expect(BrowserSubApp.resolve(url: nil, title: nil) == nil)
        #expect(BrowserSubApp.resolve(url: "not a url", title: nil) == nil)
    }

    @Test
    func titleFallbackWhenTheURLIsHidden() throws {
        #expect(try #require(BrowserSubApp.resolve(url: nil, title: "Inbox (3) - me@x.io - Gmail")).category == .mail)
        #expect(try #require(BrowserSubApp.resolve(url: nil, title: "(2) WhatsApp")).host == "web.whatsapp.com")
        #expect(try #require(BrowserSubApp.resolve(url: nil, title: "Budget 2026 - Google Sheets")).isSpreadsheet)
        #expect(BrowserSubApp.resolve(url: nil, title: "How to slack off - My Blog") == nil, "whole segments only")
    }

    @Test
    func personaKeyRoundTrips() {
        let key = BrowserSubApp.personaKey(bundleID: "com.google.Chrome", host: "mail.google.com")
        #expect(key == "com.google.Chrome|mail.google.com")
        #expect(BrowserSubApp.split(key: key) == ("com.google.Chrome", "mail.google.com"))
        #expect(BrowserSubApp.personaKey(bundleID: "com.apple.mail", host: nil) == "com.apple.mail")
        #expect(AppCategoryTable.category(for: key) == .mail)
        #expect(AppCategoryTable.category(for: "com.google.Chrome|github.com") == .code)
        #expect(AppCategoryTable.category(for: "com.google.Chrome|example.com") == .prose)
    }

    @Test
    func fieldRulesUseTheSubAppCategory() {
        let gmail = FieldContext(appBundleID: "com.google.Chrome", axRole: "AXTextArea", isMultiline: true,
                                 documentURL: "https://mail.google.com/mail/u/0/")
        #expect(FieldRules.rules(for: gmail).category == .mail)
        let editor = FieldContext(appBundleID: "com.google.Chrome", axRole: "AXTextArea", isMultiline: true,
                                  documentURL: "https://github.com/a/b/edit/main/x.swift")
        #expect(FieldRules.rules(for: editor).category == .code)
        let plain = FieldContext(appBundleID: "com.google.Chrome", axRole: "AXTextArea", isMultiline: true)
        #expect(FieldRules.rules(for: plain).category == .prose)
    }

    @Test
    func contextCarriesThePersonaKeyAndRoundTrips() {
        let field = FieldContext(appBundleID: "com.google.Chrome", axRole: "AXTextArea",
                                 documentURL: "https://app.slack.com/client/T/C", documentTitle: "general - Acme - Slack")
        var ctx = StageContext()
        field.write(into: &ctx)
        #expect(ctx.extra[FieldContext.Keys.personaKey] == "com.google.Chrome|app.slack.com")
        #expect(ctx.extra[FieldContext.Keys.subAppCategory] == "chat")
        let back = FieldContext(stageContext: ctx)
        #expect(back.documentTitle == "general - Acme - Slack")
        #expect(back.personaKey == "com.google.Chrome|app.slack.com")
        // A native app writes no key.
        var native = StageContext()
        FieldContext(appBundleID: "com.apple.mail", axRole: "AXTextArea").write(into: &native)
        #expect(native.extra[FieldContext.Keys.personaKey] == nil)
    }

    @Test
    func sheetsByTitleClassifiesAsACell() {
        let field = FieldContext(appBundleID: "com.google.Chrome", axRole: "AXTextArea", documentTitle: "Budget - Google Sheets")
        #expect(FieldRole.classify(field) == .spreadsheetCell)
    }
}
