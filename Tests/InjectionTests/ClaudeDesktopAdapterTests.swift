import Foundation
import Testing
import Shared
@testable import Injection

/// J2 (V4.40) — the Claude desktop app is Electron (its bundle ships `Electron Framework`), so its
/// composer must be routed to `ElectronAdapter`: keystrokes, then paste, never an `AXValue` write.
@Suite struct ClaudeDesktopAdapterTests {
    /// Verified on the build machine with `osascript -e 'id of app "Claude"'` (Claude 2.110.0).
    static let claudeBundleID = "com.anthropic.claudefordesktop"

    @Test func theClaudeBundleIDIsInTheElectronSet() {
        #expect(ElectronAdapter.claudeDesktopBundleID == Self.claudeBundleID)
        #expect(ElectronAdapter.bundleIDs.contains(Self.claudeBundleID))
        #expect(ElectronAdapter().matches(bundleID: Self.claudeBundleID))
    }

    @Test func theStandardRegistryRoutesClaudeToElectronNotDefault() {
        let adapter = AdapterRegistry.standard().adapter(for: Self.claudeBundleID)
        #expect(adapter.id == "electron")
        #expect(adapter.methodOrder == [.keystroke, .paste])
        #expect(!adapter.methodOrder.contains(.ax))
    }

    /// The match is exact: nothing else Anthropic ships (or a lookalike id) is swept in by accident.
    @Test func onlyTheExactIDMatches() {
        let electron = ElectronAdapter()
        for id in ["com.anthropic.claudefordesktop.helper", "com.anthropic.claude", "com.anthropic", "claudefordesktop"] {
            #expect(!electron.matches(bundleID: id), "\(id)")
        }
    }

    /// End to end through the injector: an AX-writable, readable field in Claude still receives the
    /// text by keystrokes — the AX write that desyncs ProseMirror is never attempted.
    @Test func dictationIntoClaudeLandsByKeystrokesAndNeverWritesAX() {
        let (injector, mock, _) = makeStack(Self.claudeBundleID, value: "Hi ") {
            $0.axReadable = true; $0.axWriteWorks = true; $0.keystrokesWork = true
        }
        let outcome = injector.inject(InjectionRequest(text: "there", expectedFocus: mock.frontmost))
        guard case let .injected(method, _) = outcome else { Issue.record("\(outcome)"); return }
        #expect(method == .keystroke)
        #expect(mock.field.value == "Hi there")
        #expect(!mock.journal.contains { $0.hasPrefix("ax.") })
    }
}
