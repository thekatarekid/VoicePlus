import AppKit
import Testing
@testable import VoicePlusApp

@Suite("V3 compact recovery footer")
@MainActor
struct V3FooterLayoutTests {
    @Test func microphoneRecoveryKeepsEveryActionAndCompleteHelperInTwoLines() {
        let labels = ["Edit draft", "Open Microphone settings", "Copy text", "Dismiss"]
        let helper = "Recording cannot start. Nothing was typed."
        let width = PillLaneLayout(size: NotchGeometry.activeSize, hasChip: false, hasActions: true).helperRow.width
        let spacing = PillFooterSpacing(labels: labels, helper: helper, width: width)
        let helperWidth = width - spacing.actionWidth(labels) - spacing.helperGap
        #expect(lineCount(helper, width: helperWidth) == 2)
        #expect(helperWidth > 0)
        #expect(spacing.buttonPadding >= 6)
        let original = PillFooterSpacing()
        let oldHelperWidth = width - original.actionWidth(labels) - 2 * original.helperGap
        #expect(lineCount(helper, width: oldHelperWidth) > 2)
        let lanes = PillLaneLayout(size: NotchGeometry.activeSize, hasChip: false, hasActions: true)
        #expect(lanes.helperRow.height == 32)
        #expect(lanes.helperRow.maxY == 148)
    }

    @Test func ordinaryTwoActionFooterRetainsDesignSpacing() {
        let spacing = PillFooterSpacing(labels: ["Check destination", "Dismiss"],
            helper: "Check the field before trying again", width: 520)
        #expect(spacing.buttonPadding == 10)
        #expect(spacing.buttonGap == 6)
        #expect(spacing.helperGap == 12)
    }

    private func lineCount(_ text: String, width: CGFloat) -> Int {
        let storage = NSTextStorage(string: text, attributes: [.font: Tokens.Typography.pillStatus.nsFont()])
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        var count = 0
        manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) { _, _, _, _, _ in
            count += 1
        }
        return count
    }
}
