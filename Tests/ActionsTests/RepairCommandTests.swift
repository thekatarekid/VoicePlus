import Foundation
import Testing
import Shared
@testable import Actions

/// R2.5 — the three repair commands, the region-matches / region-changed / quoted-command matrix,
/// context expiry, and the standing prohibition on destructive re-editing.
@Suite("R2.5 repair commands")
struct RepairCommandTests {
    static let session = UUID()
    static func segment(_ index: Int) -> SegmentID { SegmentID(sessionID: session, index: index) }

    /// "Ship it to kothari" with the last committed segment being the misheard name.
    static let document = "Ship it to kothari"
    static let landed = "kothari"
    static let landedRange = 11..<18

    struct Bench {
        let editor: InMemoryRepairEditor
        let ledger: InMemoryRepairLedger
        let coordinator: RepairCommandCoordinator
        let suggestions: SuggestionSpy
    }

    final class SuggestionSpy: RepairSuggestionPresenter, @unchecked Sendable {
        private let lock = NSLock()
        private var _seen: [RepairSuggestion] = []
        var seen: [RepairSuggestion] { lock.withLock { _seen } }
        func present(_ suggestion: RepairSuggestion) { lock.withLock { _seen.append(suggestion) } }
    }

    static func bench(bindRegion: Bool = true, stability: Stability = .committed) -> Bench {
        let editor = InMemoryRepairEditor(document: document)
        let ledger = InMemoryRepairLedger()
        let spy = SuggestionSpy()
        let coordinator = RepairCommandCoordinator(reader: editor.reader(), editor: editor, ledger: ledger,
                                                   now: { Date(timeIntervalSince1970: 100) })
        coordinator.presenter = spy
        if bindRegion {
            coordinator.committed(CommittedTextRegion(segment: segment(3), stability: stability, range: landedRange,
                                                      text: landed, destination: RepairDestination(bundleID: "com.apple.Notes", label: "Notes")))
        }
        return Bench(editor: editor, ledger: ledger, coordinator: coordinator, suggestions: spy)
    }

    // MARK: - Region matches

    @Test func scratchThatRemovesTheCommittedRegion() throws {
        let b = Self.bench()
        let decision = b.coordinator.handle("Scratch that.")
        let applied = try #require(decision.application)
        #expect(applied.command == .scratchThat)
        #expect(applied.was == Self.landed && applied.now.isEmpty)
        #expect(applied.segment == Self.segment(3))
        #expect(b.editor.document == "Ship it to ")
        #expect(decision.consumedUtterance)
        #expect(b.ledger.entries.count == 1 && b.ledger.entries[0].was == Self.landed)
        #expect(b.suggestions.seen.isEmpty)
    }

    @Test func noReplacementRewritesTheCommittedRegion() throws {
        let b = Self.bench()
        let applied = try #require(b.coordinator.handle("No, Kothari").application)
        #expect(applied.command == .replaceWith("Kothari"))
        #expect(b.editor.document == "Ship it to Kothari")
        #expect(applied.range == 11..<18 && applied.verified)
        // The context follows the repair, so a second repair still has a matching region.
        #expect(b.coordinator.activeRegion?.text == "Kothari")
    }

    @Test func putItBackRestoresFromTheLedgerRecord() throws {
        let b = Self.bench()
        #expect(b.coordinator.handle("no, Kothari").application != nil)
        let restored = try #require(b.coordinator.handle("Put it back").application)
        #expect(restored.command == .putItBack)
        #expect(restored.was == "Kothari" && restored.now == Self.landed)
        #expect(b.editor.document == Self.document)
        #expect(b.coordinator.activeRegion?.text == Self.landed)
        // The reverted record is closed, and the revert itself is not revertable.
        #expect(b.ledger.latestRevertable(segment: Self.segment(3)) == nil)
    }

    @Test func putItBackAfterScratchPutsTheTextBack() throws {
        let b = Self.bench()
        #expect(b.coordinator.handle("scratch that").application != nil)
        #expect(b.editor.document == "Ship it to ")
        let restored = try #require(b.coordinator.handle("put that back").application)
        #expect(restored.now == Self.landed)
        #expect(b.editor.document == Self.document)
    }

    @Test func putItBackDoesNotDependOnADecoderOrASecondLedgerEntry() throws {
        // No reader/editor of any decoder kind is involved: only the region and the record.
        let b = Self.bench()
        _ = b.coordinator.handle("no, Kothari")
        _ = b.coordinator.handle("put it back")
        // Said twice, it does not toggle back to the repair.
        let second = b.coordinator.handle("put it back")
        #expect(second.suggestion?.reason == .nothingToPutBack)
        #expect(b.editor.document == Self.document)
    }

    // MARK: - Region changed

    @Test func regionChangedLeavesTheFieldAloneForEveryCommand() throws {
        for command in ["scratch that", "no, Kothari", "put it back"] {
            let b = Self.bench()
            if command == "put it back" {
                // Give "put it back" something to revert, then move the text out from under it.
                #expect(b.coordinator.handle("no, Kothari").application != nil)
            }
            let editsBefore = b.editor.edits.count
            let documentBefore = "Ship it to someone else"
            b.editor.overwrite(documentBefore)
            let decision = b.coordinator.handle(command)
            let suggestion = try #require(decision.suggestion, "\(command) should have been refused")
            #expect(suggestion.reason.isRegionMismatch)
            #expect(b.editor.document == documentBefore, "\(command) touched the field")
            #expect(b.editor.edits.count == editsBefore, "\(command) attempted a write after a failed read")
            #expect(decision.consumedUtterance)
            #expect(b.suggestions.seen.last?.id == suggestion.id)
            #expect(!suggestion.pillLine.isEmpty && !suggestion.detail.isEmpty)
        }
    }

    @Test func regionChangedReportsWhatIsThereNow() throws {
        let b = Self.bench()
        b.editor.overwrite("Ship it to Kothari")
        let suggestion = try #require(b.coordinator.handle("scratch that").suggestion)
        #expect(suggestion.reason == .regionChanged(actual: "Kothari"))
        #expect(suggestion.was == Self.landed)
        #expect(suggestion.detail.contains("Kothari"))
    }

    @Test func unreadableDestinationIsAlsoARefusal() throws {
        let b = Self.bench()
        b.coordinator.reader = DocumentTextRegionReader { nil }
        let suggestion = try #require(b.coordinator.handle("no, Kothari").suggestion)
        #expect(suggestion.reason == .regionUnreadable("destination unreadable"))
        #expect(b.editor.edits.isEmpty)
        #expect(suggestion.copyPayload == "Kothari" && suggestion.actionTitle == "Copy replacement")
    }

    @Test func aWriterThatRefusesAtWriteTimeBecomesASuggestion() throws {
        let b = Self.bench()
        b.editor.refuseNext = .mismatch(actual: "Kothari")
        let suggestion = try #require(b.coordinator.handle("scratch that").suggestion)
        #expect(suggestion.reason == .regionChanged(actual: "Kothari"))
        #expect(b.editor.document == Self.document)
        #expect(b.ledger.entries.isEmpty)
    }

    @Test func anUnverifiedWriteIsReportedHonestlyAndNeverRetried() throws {
        let b = Self.bench()
        b.editor.verify = false
        let applied = try #require(b.coordinator.handle("scratch that").application)
        #expect(!applied.verified)
        #expect(b.editor.edits.count == 1)
    }

    // MARK: - Quoted commands are dictation

    @Test func quotedCommandsStayDictation() throws {
        let cases: [(String, RepairVoiceCommand)] = [
            ("Say \"scratch that\" when you want it gone", .scratchThat),
            ("\u{201C}no, Kothari\u{201D}", .replaceWith("Kothari")),
            ("the phrase \u{2018}put it back\u{2019} undoes a repair", .putItBack),
            ("\"scratch that\"", .scratchThat),
            ("he said 'put it back' twice", .putItBack),
        ]
        for (text, quoted) in cases {
            let b = Self.bench()
            let decision = b.coordinator.handle(text)
            #expect(decision == .dictation(text: text, quotedCommand: quoted), "\(text)")
            #expect(!decision.consumedUtterance)
            #expect(b.editor.document == Self.document, "\(text) edited the field")
            #expect(b.editor.edits.isEmpty)
            #expect(b.suggestions.seen.isEmpty)
        }
    }

    @Test func quotedPayloadInsideARealCommandIsStillACommand() throws {
        let b = Self.bench()
        let applied = try #require(b.coordinator.handle("no, \"Kothari\"").application)
        #expect(applied.now == "Kothari")
    }

    @Test func apostrophesAreNotQuotes() {
        #expect(RepairCommandGrammar.classify("don't scratch that").command == nil) // not anchored either
        #expect(RepairCommandGrammar.classify("no, it's Kothari").command == .replaceWith("Kothari"))
    }

    // MARK: - Context lifetime

    @Test func contextExpiresAfterTheNextNonRepairUtterance() throws {
        let b = Self.bench()
        let dictation = b.coordinator.handle("Send it this afternoon.")
        #expect(dictation == .dictation(text: "Send it this afternoon.", quotedCommand: nil))
        #expect(b.coordinator.activeRegion == nil)
        let suggestion = try #require(b.coordinator.handle("scratch that").suggestion)
        #expect(suggestion.reason == .contextExpired)
        #expect(b.editor.document == Self.document)
        #expect(b.editor.edits.isEmpty)
    }

    @Test func aQuotedCommandCountsAsANonRepairUtterance() throws {
        let b = Self.bench()
        _ = b.coordinator.handle("\"scratch that\"")
        #expect(b.coordinator.activeRegion == nil)
        #expect(b.coordinator.handle("scratch that").suggestion?.reason == .contextExpired)
    }

    @Test func repairCommandsDoNotExpireTheContext() throws {
        let b = Self.bench()
        _ = b.coordinator.handle("no, Kothari")
        #expect(b.coordinator.activeRegion != nil)
        _ = b.coordinator.handle("scratch that")
        #expect(b.editor.document == "Ship it to ")
    }

    @Test func withoutACommittedRegionThereIsNothingToRepair() throws {
        let b = Self.bench(bindRegion: false)
        for command in ["scratch that", "no, Kothari", "put it back"] {
            let suggestion = try #require(b.coordinator.handle(command).suggestion)
            #expect(suggestion.reason == .noCommittedRegion)
            #expect(suggestion.actionTitle == nil)
        }
        #expect(b.editor.edits.isEmpty)
    }

    @Test func provisionalTextIsNotBindable() throws {
        let b = Self.bench(bindRegion: false)
        let bound = b.coordinator.committed(CommittedTextRegion(segment: Self.segment(3), stability: .provisional,
                                                                range: Self.landedRange, text: Self.landed))
        #expect(!bound)
        #expect(b.coordinator.activeRegion == nil)
        #expect(b.coordinator.handle("scratch that").suggestion?.reason == .noCommittedRegion)
    }

    @Test func aLateEarlierSegmentDoesNotRebindTheContext() {
        let b = Self.bench()
        let stale = CommittedTextRegion(segment: Self.segment(1), range: 0..<4, text: "Ship")
        #expect(!b.coordinator.committed(stale))
        #expect(b.coordinator.activeRegion?.segment == Self.segment(3))
        // A newer segment in the same session does rebind.
        #expect(b.coordinator.committed(CommittedTextRegion(segment: Self.segment(4), range: 0..<4, text: "Ship")))
        #expect(b.coordinator.activeRegion?.segment == Self.segment(4))
        // So does a segment from a different session (nothing to compare across sessions).
        let other = SegmentID(sessionID: UUID(), index: 0)
        #expect(b.coordinator.committed(CommittedTextRegion(segment: other, range: 0..<4, text: "Ship")))
        #expect(b.coordinator.activeRegion?.segment == other)
    }

    @Test func scratchingTwiceHasNothingLeftToScratch() throws {
        let b = Self.bench()
        _ = b.coordinator.handle("scratch that")
        let suggestion = try #require(b.coordinator.handle("scratch that").suggestion)
        #expect(suggestion.reason == .nothingToScratch)
    }

    @Test func putItBackWithNoRepairOnRecord() throws {
        let b = Self.bench()
        let suggestion = try #require(b.coordinator.handle("put it back").suggestion)
        #expect(suggestion.reason == .nothingToPutBack)
        #expect(b.editor.edits.isEmpty)
    }

    // MARK: - Grammar

    @Test func grammarTable() {
        let commands: [(String, RepairVoiceCommand)] = [
            ("scratch that", .scratchThat),
            ("Scratch that!", .scratchThat),
            ("um, scratch that please", .scratchThat),
            ("no scratch that", .scratchThat),
            ("scratch this", .scratchThat),
            ("put it back", .putItBack),
            ("Put that back.", .putItBack),
            ("no, put it back", .putItBack),
            ("no, Kothari", .replaceWith("Kothari")),
            ("no Kothari", .replaceWith("Kothari")),
            ("nope, Kothari", .replaceWith("Kothari")),
            ("no, I said Kothari", .replaceWith("Kothari")),
            ("no, I meant Ann Arbor", .replaceWith("Ann Arbor")),
            ("no, make it Kothari", .replaceWith("Kothari")),
            ("no, that's Kothari", .replaceWith("Kothari")),
        ]
        for (text, expected) in commands {
            #expect(RepairCommandGrammar.classify(text) == .command(expected), "\(text)")
        }
        let dictation = [
            "no",                                   // ambiguous on its own
            "I had to scratch that itch",           // not anchored
            "no, I don't think so",                 // talking, not repairing
            "no, we should probably ship it today", // too long to be a replacement
            "put the invoice back in the folder",
            "scratch",
            "that should be put back later",
        ]
        for text in dictation {
            #expect(RepairCommandGrammar.classify(text).command == nil, "\(text) parsed as a command")
        }
    }

    // MARK: - The prohibition (V3 §12.2)

    @Test func theOnlyMutationIsAGuardedRangeReplacement() {
        let b = Self.bench()
        _ = b.coordinator.handle("no, Kothari")
        _ = b.coordinator.handle("put it back")
        _ = b.coordinator.handle("scratch that")
        #expect(b.editor.edits.count == 3)
        for edit in b.editor.edits {
            // Every write names what it expects to find: no unguarded edit exists.
            #expect(edit.range.lowerBound >= 0 && edit.range.upperBound >= edit.range.lowerBound)
            #expect(edit.segment.sessionID == Self.session)
            #expect(!edit.expected.isEmpty || !edit.replacement.isEmpty)
        }
        // Retracting text is a replacement of a range that still reads `expected` — never a
        // deletion keystroke, and never a rewrite of the whole field.
        let scratch = b.editor.edits.last
        #expect(scratch?.expected == "kothari" && scratch?.replacement == "")
        #expect(scratch?.range == Self.landedRange)
    }

    @Test func noRepairSourceFileReachesForADestructiveEditingPath() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        let directory = root.appendingPathComponent("Actions/Repair", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(files.count >= 3)
        for file in files {
            let code = try RepairSourceScan.strippingComments(String(contentsOf: file, encoding: .utf8))
            for banned in RepairSourceScan.banned {
                #expect(!code.localizedCaseInsensitiveContains(banned),
                        "\(file.lastPathComponent) mentions \(banned)")
            }
        }
    }
}

/// Shared with `AppTests`' bridge test in spirit: the tokens that would mean repair had reached for
/// a deletion keystroke, a wholesale field rewrite, or the system undo shortcut.
enum RepairSourceScan {
    static let banned = [
        "back" + "space", "kVK_Delete", "kVK_ForwardDelete", "CGEvent", "keyCode", "keyDown", "keyUp",
        "setFocusedValue", "AXUIElementSetAttributeValue", "cmd+z", "command+z", "\u{2318}Z", "0x33",
        "deleteBackward", "NSPasteboard",
    ]

    /// Comments are documentation, not behaviour — the rule is about code paths.
    static func strippingComments(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard let marker = line.range(of: "//") else { return String(line) }
            return String(line[line.startIndex..<marker.lowerBound])
        }.joined(separator: "\n")
    }
}
