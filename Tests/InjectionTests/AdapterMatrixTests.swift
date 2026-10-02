import Foundation
import Testing
import Shared
@testable import Injection

// MARK: - Adapters + 12-app routing matrix (T2)

@Suite struct AdapterMatrixTests {
    struct Row { let bundleID: String; let adapter: String; let method: InjectionMethod; let readable: Bool; let ax: Bool; let keys: Bool }

    static let matrix: [Row] = [
        Row(bundleID: "com.apple.TextEdit", adapter: "default", method: .ax, readable: true, ax: true, keys: true),
        Row(bundleID: "com.apple.Notes", adapter: "default", method: .ax, readable: true, ax: true, keys: true),
        Row(bundleID: "com.apple.mail", adapter: "default", method: .ax, readable: true, ax: true, keys: true),
        Row(bundleID: "com.apple.Safari", adapter: "default", method: .keystroke, readable: true, ax: false, keys: true),
        Row(bundleID: "com.google.Chrome", adapter: "chromium", method: .keystroke, readable: true, ax: false, keys: true),
        Row(bundleID: "com.brave.Browser", adapter: "chromium", method: .keystroke, readable: true, ax: false, keys: true),
        Row(bundleID: "company.thebrowser.Browser", adapter: "chromium", method: .keystroke, readable: true, ax: false, keys: true),
        Row(bundleID: "com.apple.Terminal", adapter: "terminal", method: .adapter, readable: false, ax: false, keys: true),
        Row(bundleID: "com.googlecode.iterm2", adapter: "terminal", method: .adapter, readable: false, ax: false, keys: true),
        Row(bundleID: "com.mitchellh.ghostty", adapter: "terminal", method: .adapter, readable: false, ax: false, keys: true),
        Row(bundleID: "com.tinyspeck.slackmacgap", adapter: "electron", method: .paste, readable: false, ax: false, keys: true),
        Row(bundleID: "com.microsoft.VSCode", adapter: "electron", method: .keystroke, readable: false, ax: false, keys: true),
        Row(bundleID: "com.todesktop.230313mzl4w4u92", adapter: "cursor", method: .keystroke, readable: false, ax: false, keys: true),
        Row(bundleID: "com.microsoft.Excel", adapter: "spreadsheet", method: .adapter, readable: true, ax: false, keys: true),
        Row(bundleID: "com.apple.iWork.Numbers", adapter: "spreadsheet", method: .adapter, readable: true, ax: false, keys: true),
        Row(bundleID: "com.figma.Desktop", adapter: "figma", method: .keystroke, readable: false, ax: false, keys: true),
    ]

    @Test("dictation lands in every matrix app", arguments: matrix)
    func lands(row: Row) {
        let (injector, mock, _) = makeStack(row.bundleID, value: "") {
            $0.axReadable = row.readable; $0.axWriteWorks = row.ax; $0.keystrokesWork = row.keys
        }
        #expect(injector.registry.adapter(for: row.bundleID).id == row.adapter)
        let outcome = injector.inject(InjectionRequest(text: "hello there", expectedFocus: mock.frontmost))
        guard case let .injected(method, _) = outcome else { Issue.record("\(row.bundleID): \(outcome)"); return }
        #expect(method == row.method, "\(row.bundleID)")
        #expect(mock.field.value == "hello there", "\(row.bundleID)")
    }

    @Test func matrixCoversAtLeastTwelveApps() {
        #expect(Set(Self.matrix.map(\.bundleID)).count >= 12)
    }

    @Test func terminalStripsSmartPunctuationAndBracketsMultiline() {
        let (injector, mock, _) = makeStack("com.apple.Terminal") { $0.axReadable = false }
        _ = injector.inject(InjectionRequest(text: "echo \u{201C}hi\u{201D}\nls \u{2014} -la"))
        #expect(mock.field.value == "\u{1B}[200~echo \"hi\"\nls -- -la\u{1B}[201~")
        #expect(!mock.journal.contains { $0.hasPrefix("ax.") })
    }

    @Test func terminalSingleLineIsNotBracketed() {
        #expect(TerminalAdapter.bracketed("ls -la") == "ls -la")
    }

    @Test func electronNeverUsesAX() {
        let (injector, mock, _) = makeStack("com.microsoft.VSCode", value: "let ") { $0.axReadable = true; $0.axWriteWorks = true }
        let outcome = injector.inject(InjectionRequest(text: "x = 1"))
        #expect(outcome == .injected(method: .keystroke, verified: true))
        #expect(!mock.journal.contains { $0.hasPrefix("ax.") })
    }

    @Test func cursorMatchesByNameToo() {
        #expect(AdapterRegistry.standard().adapter(for: "com.anysphere.cursor").id == "cursor")
    }

    @Test func spreadsheetCellModeFlattensNewlinesWhenCellFocused() {
        let (injector, mock, _) = makeStack("com.microsoft.Excel") { $0.field.role = "AXCell"; $0.axWriteWorks = false }
        _ = injector.inject(InjectionRequest(text: "line one\nline two"))
        #expect(mock.field.value == "line one line two")
        #expect(!mock.journal.contains { $0.contains("+opt") })
    }

    @Test func spreadsheetInCellEditorUsesOptionReturn() {
        let (injector, mock, _) = makeStack("com.apple.iWork.Numbers") { $0.field.role = "AXTextField"; $0.axWriteWorks = false }
        _ = injector.inject(InjectionRequest(text: "a\nb"))
        #expect(mock.field.value == "a\nb")
        #expect(mock.journal.contains("key.combo(100):36+opt"))
    }

    /// R2.3: paste is reached only because the keystroke call itself failed with nothing on the
    /// wire. Keystrokes that were *posted* and then swallowed end the attempt unverified instead.
    @Test func figmaFallsToPasteWhenKeystrokesThrowBeforePosting() {
        let (injector, mock, _) = makeStack("com.figma.Desktop") { $0.throwsBeforePosting = [.keystrokes] }
        #expect(injector.inject(InjectionRequest(text: "Label")) == .injected(method: .paste, verified: true))
        #expect(mock.field.value == "Label")
    }

    @Test func registryPrefersCustomAdapterRegisteredFirst() {
        final class Custom: AppAdapter {
            let id = "custom"; func matches(bundleID: String) -> Bool { bundleID == "com.apple.Terminal" }
            var methodOrder: [InjectionMethod] { [.paste] }
        }
        let registry = AdapterRegistry.standard()
        registry.register(Custom())
        #expect(registry.adapter(for: "com.apple.Terminal").id == "custom")
        #expect(registry.adapter(for: "com.unknown.App").id == "default")
    }
}
