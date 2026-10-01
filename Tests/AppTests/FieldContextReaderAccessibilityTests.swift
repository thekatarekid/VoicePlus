import Foundation
import Testing
import Injection
@testable import VoicePlusApp

/// Q2 — `FieldContextReader` asks the app for its AX tree before it reads the caret: key-down →
/// enable → read. Without the enable, an Electron composer answers no caret at all.
@Suite struct FieldContextReaderAccessibilityTests {
    @Test func enablesBeforeTheCaretRead() {
        let mock = MockSystemAccess(frontmost: FocusSnapshot(pid: 200, bundleID: "com.anthropic.claudefordesktop",
                                                             appName: "Claude", elementToken: "composer"))
        mock.field = MockSystemAccess.Field(value: "Hello", selection: 5..<5)
        mock.requiresAccessibilityEnable = true
        let reader = FieldContextReader(system: mock)
        let field = reader.fieldContext(bundleID: "com.anthropic.claudefordesktop")
        #expect(mock.accessibilityEvents.first == "enable(200)")
        #expect(mock.accessibilityEvents.dropFirst().first == "read(tree)")
        #expect(reader.lastReading?.rung == .selectedRange)
        #expect(field?.caret != .unknown)
    }
}
