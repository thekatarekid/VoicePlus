import Foundation
import Pipeline
import Shared
import SwiftUI
import Testing
@testable import VoicePlusApp

/// H10 — Settings › Edit commands is generated from `EditCommandCatalog`: it lists exactly the
/// catalogue's entries, grouped in its order, and marks the L entries "needs on-device model".
@Suite("H10 — Edit commands page")
@MainActor
struct TransformEditCommandsPageH10Tests {
    @Test("the page lists exactly the catalogue entries, in catalogue order")
    func exactlyTheCatalogue() {
        let content = EditCommandsPageContent.fromCatalog()
        #expect(content.rowIDs == EditCommandCatalog.entries.map(\.id))
        #expect(content.sections.map(\.title) == EditCommandCatalog.grouped.map(\.group.title))
        #expect(Set(content.rowIDs).count == content.rowIDs.count, "no entry listed twice")
    }

    @Test("L entries say they need the on-device model; D entries say instant")
    func modelMarks() throws {
        let rows = EditCommandsPageContent.fromCatalog().sections.flatMap(\.rows)
        for entry in EditCommandCatalog.entries {
            let row = try #require(rows.first { $0.id == entry.id })
            #expect(row.title == entry.title)
            #expect(row.needsModel == (entry.kind == .llm))
            #expect(row.detail.contains(entry.kind == .llm ? EditCommandsCopy.needsModel : EditCommandsCopy.instant))
            for example in entry.examples { #expect(row.detail.contains(example)) }
        }
        #expect(rows.contains { $0.needsModel } && rows.contains { !$0.needsModel })
    }

    @Test("a subset of the catalogue renders as just that subset (generated, not hand-written)")
    func generated() {
        let tone = EditCommandCatalog.grouped.filter { $0.group == .tone }
        let content = EditCommandsPageContent.fromCatalog(tone)
        #expect(content.sections.count == 1)
        #expect(content.rowIDs == EditCommandCatalog.entries.filter { $0.group == .tone }.map(\.id))
    }

    @Test("Settings has an Edit commands subpage reachable by route, and the page renders")
    func subpage() {
        #expect(SettingsSubpage.allCases.contains(.editCommands))
        #expect(SettingsSubpage.editCommands.title == "Edit commands")
        #expect(SettingsSubpage.editCommands.pageSubtitle == EditCommandsCopy.subtitle)
        #expect(WindowRoute.settings(.editCommands).isValid)
        #expect(SettingsReachability.allItems.contains { $0.subpage == .editCommands && $0.marker == "EditCommandsPage(" })
        let renderer = ImageRenderer(content: EditCommandsPage(hotkey: "Option").frame(width: 760, height: 900))
        renderer.scale = 1
        #expect(renderer.cgImage != nil)
    }

    @Test("no fn in the page copy (Option replaces fn)")
    func noFn() {
        let copy = [EditCommandsCopy.title, EditCommandsCopy.subtitle, EditCommandsCopy.footnote]
        #expect(!copy.contains { $0.range(of: #"\bfn\b"#, options: .regularExpression) != nil })
    }
}
