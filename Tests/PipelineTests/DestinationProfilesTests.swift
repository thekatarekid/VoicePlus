import Foundation
import Testing
import Shared
@testable import Pipeline

// Context Writer (plan §3) — the destination table and its resolvers.

@Suite struct DestinationProfilesTests {

    /// Every id the packet contract documents (`ContextPacket.Destination.profileID`).
    static let planIDs: [String] = [
        "chat.message", "ai.chat", "ai.agentCLI", "shell", "code.body", "code.comment", "commit", "document",
        "markdown", "slides.title", "slides.body", "slides.notes", "spreadsheet.cell", "email.subject",
        "email.body.reply", "email.body.new", "browser.urlBar", "search", "form", "notes", "social",
        "calendar.title", "calendar.notes", "secure", "unknown",
    ]

    @Test func everyPlanIDResolvesToItself() {
        for id in Self.planIDs {
            #expect(DestinationProfiles.lookup(id) != nil, "missing profile \(id)")
            #expect(DestinationProfiles.resolve(profileID: id).id == id)
        }
        #expect(DestinationProfiles.all.count == Self.planIDs.count)
        #expect(Set(DestinationProfiles.ids) == Set(Self.planIDs))
    }

    @Test func idsAreUniqueAndRowsAreTight() {
        #expect(Set(DestinationProfiles.ids).count == DestinationProfiles.all.count)
        for p in DestinationProfiles.all {
            #expect(!p.title.isEmpty && !p.transcribe.isEmpty && !p.detection.isEmpty, Comment(rawValue: p.id))
            // Rendered into every prompt: keep each field short.
            #expect(p.transcribe.count <= 320, "\(p.id) transcribe rules too long (\(p.transcribe.count))")
            #expect((p.instruct ?? "").count <= 200, "\(p.id) instruct rules too long")
            #expect((p.never ?? "").count <= 120, "\(p.id) never rules too long")
            #expect(!p.transcribe.contains("\n"))
        }
        #expect(DestinationProfiles.crossCuttingRules.count < 900)
    }

    @Test func unknownIDFallsBackToUnknownProfile() {
        #expect(DestinationProfiles.resolve(profileID: "no.such.profile").id == "unknown")
        #expect(DestinationProfiles.lookup("no.such.profile") == nil)
    }

    @Test func secureAndFormOfferNoInstruct() {
        #expect(DestinationProfiles.resolve(profileID: "secure").isSecure)
        #expect(!DestinationProfiles.resolve(profileID: "secure").supportsInstruct)
        #expect(!DestinationProfiles.resolve(profileID: "form").supportsInstruct)
        #expect(DestinationProfiles.resolve(profileID: "chat.message").supportsInstruct)
        #expect(DestinationProfiles.all.filter(\.isSecure).map(\.id) == ["secure"])
    }

    @Test func formattingSwitchesMatchThePlan() {
        let shell = DestinationProfiles.resolve(profileID: "shell").formatting
        #expect(shell.casing == .lower && shell.terminalPunctuation == .never && shell.lineBreaks == .none)
        let chat = DestinationProfiles.resolve(profileID: "chat.message").formatting
        #expect(chat.terminalPunctuation == .light && chat.greeting == .never && !chat.markdownAllowed)
        let title = DestinationProfiles.resolve(profileID: "slides.title").formatting
        #expect(title.casing == .title && title.lengthLimit == .words(8))
        #expect(DestinationProfiles.resolve(profileID: "commit").formatting.lengthLimit == .characters(72))
        #expect(DestinationProfiles.resolve(profileID: "social").formatting.lengthLimit == .platform)
        #expect(DestinationProfiles.resolve(profileID: "email.body.new").formatting.greeting == .byDefault)
        #expect(DestinationProfiles.resolve(profileID: "email.body.reply").formatting.greeting == .whenDictated)
        #expect(DestinationProfiles.resolve(profileID: "markdown").formatting.markdownAllowed)
        #expect(DestinationProfiles.resolve(profileID: "document").formatting.numerals == .tenAndAbove)
        #expect(DestinationProfiles.resolve(profileID: "spreadsheet.cell").formatting.numerals == .always)
    }

    // MARK: Fallback resolver

    @Test func fallbackFromSurfaceKind() {
        #expect(DestinationProfiles.profileID(surfaceKind: "terminal") == "shell")
        #expect(DestinationProfiles.profileID(surfaceKind: "spreadsheetCell") == "spreadsheet.cell")
        #expect(DestinationProfiles.profileID(surfaceKind: "chatComposer", appBundleID: "com.tinyspeck.slackmacgap") == "chat.message")
        #expect(DestinationProfiles.profileID(surfaceKind: "urlBar", appBundleID: "com.google.Chrome") == "browser.urlBar")
        #expect(DestinationProfiles.profileID(surfaceKind: "searchField") == "search")
        #expect(DestinationProfiles.profileID(surfaceKind: "emailBody", appBundleID: "com.apple.mail") == "email.body.reply")
        #expect(DestinationProfiles.profileID(surfaceKind: "formField:subject") == "email.subject")
        #expect(DestinationProfiles.profileID(surfaceKind: "formField:phone") == "form")
        #expect(DestinationProfiles.profileID(surfaceKind: "markdownEditor") == "markdown")
        #expect(DestinationProfiles.profileID(surfaceKind: "codeEditor", appBundleID: "com.microsoft.VSCode") == "code.body")
        #expect(DestinationProfiles.profileID(surfaceKind: "canvas") == "unknown")
        #expect(DestinationProfiles.profileID(surfaceKind: nil) == "unknown")
        #expect(DestinationProfiles.profileID(surfaceKind: "garbage") == "unknown")
    }

    @Test func secureAlwaysWins() {
        #expect(DestinationProfiles.profileID(surfaceKind: "secure") == "secure")
        #expect(DestinationProfiles.profileID(surfaceKind: "chatComposer", appBundleID: "com.tinyspeck.slackmacgap", fieldRole: .secure) == "secure")
        #expect(DestinationProfiles.resolve(surfaceKind: "prose", fieldRole: .secure).isSecure)
    }

    @Test func aiChatIsToldFromChatByAppOrHost() {
        #expect(DestinationProfiles.profileID(surfaceKind: "chatComposer", appBundleID: "com.anthropic.claudefordesktop") == "ai.chat")
        #expect(DestinationProfiles.profileID(surfaceKind: "chatComposer", appBundleID: "com.openai.chat") == "ai.chat")
        #expect(DestinationProfiles.profileID(surfaceKind: "chatComposer", appBundleID: "com.google.Chrome", urlHost: "claude.ai") == "ai.chat")
        #expect(DestinationProfiles.profileID(surfaceKind: "chatComposer", urlHost: "www.chatgpt.com") == "ai.chat")
        #expect(DestinationProfiles.profileID(surfaceKind: "chatComposer", urlHost: "app.slack.com") == "chat.message")
        #expect(DestinationProfiles.profileID(surfaceKind: "chatComposer", appBundleID: "com.hnc.Discord") == "chat.message")
    }

    @Test func proseFallsBackThroughAppAndHostTables() {
        #expect(DestinationProfiles.profileID(surfaceKind: "prose", appBundleID: "com.apple.Notes") == "notes")
        #expect(DestinationProfiles.profileID(surfaceKind: "prose", appBundleID: "com.apple.iWork.Pages") == "document")
        #expect(DestinationProfiles.profileID(surfaceKind: "prose", appBundleID: "com.apple.iWork.Keynote") == "slides.body")
        #expect(DestinationProfiles.profileID(surfaceKind: "prose", appBundleID: "com.apple.iCal") == "calendar.notes")
        #expect(DestinationProfiles.profileID(surfaceKind: "prose", urlHost: "docs.google.com") == "document")
        #expect(DestinationProfiles.profileID(surfaceKind: "prose", urlHost: "x.com") == "social")
        #expect(DestinationProfiles.profileID(surfaceKind: "prose", urlHost: "www.linkedin.com") == "social")
        #expect(DestinationProfiles.profileID(surfaceKind: "prose", urlHost: "mail.google.com") == "email.body.reply")
        // Seed-hint families when the exact table has nothing.
        #expect(DestinationProfiles.profileID(surfaceKind: "prose", appBundleID: "com.microsoft.Outlook") == "email.body.reply")
        #expect(DestinationProfiles.profileID(surfaceKind: "prose", appBundleID: "net.whatsapp.WhatsApp") == "chat.message")
        // A field role is the last resort.
        #expect(DestinationProfiles.profileID(surfaceKind: nil, fieldRole: .terminal) == "shell")
        #expect(DestinationProfiles.profileID(surfaceKind: nil, fieldRole: .codeEditor) == "code.body")
        #expect(DestinationProfiles.profileID(surfaceKind: "prose", appBundleID: "com.unknown.app") == "unknown")
    }

    @Test func hostMatchingIsSuffixSafe() {
        // "notslack.com" must not match "slack.com".
        #expect(DestinationProfiles.profileID(surfaceKind: "prose", urlHost: "notslack.com") == "unknown")
        #expect(DestinationProfiles.profileID(surfaceKind: "prose", urlHost: "app.slack.com") == "chat.message")
        #expect(DestinationProfiles.profileID(surfaceKind: "chatComposer", urlHost: "evilclaude.ai") == "chat.message")
    }
}
