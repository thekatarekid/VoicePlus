import Foundation
import Testing
import Shared
@testable import Actions

/// R2.5 — the repair-command grammar and the standing prohibition on destructive re-editing.
/// V5 X19 removed the never-wired `RepairCommandCoordinator` and its bench tests; the grammar,
/// region types and suggestion vocabulary stay (the pill and recovery catalogue use them).
@Suite("R2.5 repair commands")
struct RepairCommandTests {
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

    @Test func apostrophesAreNotQuotes() {
        #expect(RepairCommandGrammar.classify("don't scratch that").command == nil) // not anchored either
        #expect(RepairCommandGrammar.classify("no, it's Kothari").command == .replaceWith("Kothari"))
    }

    // MARK: - The prohibition (V3 §12.2)

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
