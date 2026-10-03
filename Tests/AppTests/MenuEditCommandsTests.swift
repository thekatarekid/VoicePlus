import AppKit
import Foundation
import Pipeline
import Testing
@testable import VoicePlusApp

/// H10 — the "Edit commands" submenu lists exactly the catalogue entries (one data file), grouped,
/// with L entries marked "needs on-device model"; choosing a row opens the Edit commands page.
@Suite("H10 — Edit commands submenu")
struct MenuEditCommandsTests {
    @Test func submenuListsExactlyTheCatalogue() {
        #expect(EditCommandsMenu.listedCommandIDs() == EditCommandCatalog.grouped.flatMap { $0.entries.map(\.id) })
        #expect(Set(EditCommandsMenu.listedCommandIDs()) == Set(EditCommandCatalog.entries.map(\.id)))
        #expect(EditCommandsMenu.listedCommandIDs().count == EditCommandCatalog.entries.count)
        let headers = EditCommandsMenu.entries().filter(\.isHeader).map(\.title)
        #expect(headers == EditCommandCatalog.grouped.map { $0.group.title })
    }

    @Test func modelCommandsSayTheyNeedTheModel() {
        let rows = EditCommandsMenu.entries()
        for entry in EditCommandCatalog.entries {
            let row = try! #require(StatusMenuSpec.entry(EditCommandsMenu.rowID(entry), in: rows))
            #expect(row.title == entry.title)
            #expect(row.action == .openEditCommands)
            let marked = row.detail?.contains(EditCommandsMenu.needsModel) == true
            #expect(marked == (entry.kind == .llm), "\(entry.id)")
            if let first = entry.examples.first { #expect(row.detail?.contains(first) == true) }
        }
    }

    @Test func parentRowSitsAfterSettingsOnlyWhenOptedIn() {
        let off = StatusMenuSpec.entries(StatusMenuState())
        #expect(StatusMenuSpec.entry(StatusMenuSpec.ID.editCommands, in: off) == nil)
        var state = StatusMenuState()
        state.extras = MenuExtras(editCommands: true)
        let on = StatusMenuSpec.entries(state)
        let ids = on.map(\.id)
        let i = try! #require(ids.firstIndex(of: StatusMenuSpec.ID.editCommands))
        #expect(ids[i - 1] == StatusMenuSpec.ID.settings)
        #expect(on[i].submenu?.count == EditCommandsMenu.entries().count)
        #expect(on[i].action == nil)
    }

    @MainActor @Test func rendererBuildsTheSubmenuAndRowsOpenThePage() {
        let rig = StatusMenuControllerTests.Rig()
        rig.controller.showsEditCommands = true
        var opened = 0
        rig.controller.onOpenEditCommands = { opened += 1 }
        rig.controller.rebuild()
        let parent = try! #require(rig.controller.menu.items.first {
            $0.identifier?.rawValue == StatusMenuSpec.ID.editCommands })
        let sub = try! #require(parent.submenu)
        let rows = sub.items.filter { !$0.isSectionHeader }
        #expect(rows.count == EditCommandCatalog.entries.count)
        #expect(sub.items.filter(\.isSectionHeader).count == EditCommandCatalog.grouped.count)
        rig.controller.run(.openEditCommands)
        #expect(opened == 1)
    }
}
