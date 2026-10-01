import SwiftUI
import Shared

// V5 Q13 — the Settings › Privacy › Diagnostics row that exports `turn_diagnostics` as JSON.
// Owner-triggered only: nothing is written until the user presses the button and confirms the
// save panel. With no app database (tests, previews) the row says so and the button is disabled.

struct TurnDiagnosticsExportRow: View {
    let database: AppDatabase?
    @State private var status: String?

    var body: some View {
        GroupBox(TurnDiagnosticsExportAction.buttonTitle.replacingOccurrences(of: "…", with: "")) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                Text(TurnDiagnosticsExportAction.explanation)
                    .windowFont(Tokens.Typography.meta)
                    .foregroundStyle(WindowColor.secondaryInk)
                HStack(spacing: Tokens.Spacing.s) {
                    Button(TurnDiagnosticsExportAction.buttonTitle) { export() }
                        .disabled(database == nil)
                        .accessibilityIdentifier("privacy.turnDiagnostics.export")
                    if let status {
                        Text(status)
                            .windowFont(Tokens.Typography.meta)
                            .foregroundStyle(WindowColor.secondaryInk)
                    }
                }
            }
        }
        .accessibilityIdentifier("privacy.turnDiagnostics")
    }

    private func export() {
        status = TurnDiagnosticsExportRow.run(database: database) { store in
            try TurnDiagnosticsExportAction.run(store: store)
        }
    }

    /// Opens the store on `database` and runs `action`; returns the status line to show.
    static func run(database: AppDatabase?, action: (TurnDiagnostics) throws -> URL?) -> String? {
        guard let database else { return "No local database." }
        do {
            let store = try TurnDiagnostics(database: database)
            guard let url = try action(store) else { return nil }
            return "Saved \(url.lastPathComponent)"
        } catch {
            return "Couldn't export: \(error.localizedDescription)"
        }
    }
}
