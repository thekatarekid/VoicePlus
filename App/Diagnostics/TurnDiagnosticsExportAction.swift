import AppKit
import Foundation
import Shared

// V5 Q13 — Settings › Privacy › "Export turn diagnostics…". Owner-triggered only: the export runs
// solely from this action, behind a save panel the user confirms. Nothing is ever uploaded.

public extension TurnDiagnostics {
    /// The store on the app database (`turn_diagnostics` lives beside the other local tables).
    convenience init(database: AppDatabase) throws {
        try self.init(writer: database.writer)
    }
}

@MainActor
public enum TurnDiagnosticsExportAction {
    public static let buttonTitle = "Export turn diagnostics…"
    public static let explanation = "Pill placement, window and pause reasons, landing results and decisions from the last 7 days. No dictated text or audio."

    /// Shows a save panel and writes the JSON export where the user chose. Returns the URL written,
    /// or nil when cancelled.
    @discardableResult
    public static func run(store: TurnDiagnostics, now: Date = Date()) throws -> URL? {
        let panel = NSSavePanel()
        panel.title = buttonTitle
        panel.message = explanation
        panel.nameFieldStringValue = TurnDiagnostics.exportFileName(at: now)
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        try store.exportJSON(to: url)
        return url
    }
}
