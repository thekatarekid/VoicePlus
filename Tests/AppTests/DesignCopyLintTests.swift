import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// FX4 — designer and engineer notes never reach the user. 1.11.1 showed "After 2 seconds name the
/// wait; after failure offer recovery." under "The speech model isn’t ready": a note from the design's
/// §10 table, copied verbatim into the catalogue and locked in by the exact-match parity test. Every
/// string a user can read — the recovery catalogue's headline, consequence and action, and the
/// prototype's pill, screen and empty-state copy — is held here to the voice of `DESIGN.md` §7.1: it
/// talks to the user about what happened, never to the builder about what the UI should do.
///
/// Not linted: an entry's trigger (documentation) and data policy (the design's data rule), and the
/// state inventory's descriptions (`design_copy.json` › `states`), which describe drawings.
@Suite("FX4 — user-facing copy carries no designer notes")
struct DesignCopyLintTests {

    // MARK: The lint

    /// A clause that opens with one of these is an instruction to whoever builds the UI.
    static let specVerbAtClauseStart = #"^(show|display|name|say|offer|isolate|hide|teach|surface|render|do not|don[’']t|never|must)\b"#

    /// Phrasing that only a spec uses, anywhere in the string.
    static let specPhrases: [(rule: String, pattern: String)] = [
        ("time as a spec", #"\bafter \d+(\.\d+)?\s*(s|sec|secs|seconds?|ms|milliseconds?)\b"#),
        ("time as a spec", #"\b\d+(\.\d+)?\s*(ms|milliseconds?)\b"#),
        ("spec instruction", #"\bname the (wait|missing|reason|cause|error)\b"#),
        ("spec instruction", #"\boffer (recovery|retry|a retry|the user)\b"#),
        ("spec instruction", #"\bafter failure\b"#),
        ("spec instruction", #"\bkeep\b[^.;·]*\bvisible\b"#),
        ("spec modal", #"\b(must|should)\b"#),
        ("third person", #"\bthe user\b"#),
        ("spec wording", #"\b(claim|teach|belongs to)\b"#),
        ("engineering term", #"\b(legacy|listener|relaunch|aligned|alignment|on disk)\b"#),
        ("UI anatomy", #"\b(row|banner|toast|tooltip|popover|caption|badge)\b"#),
        ("prototype note", #"\b(study|prototype|in this preview)\b"#),
    ]

    /// The rules a string breaks; empty when it reads as copy for the user.
    static func violations(_ text: String) -> [String] {
        var found: [String] = []
        for (rule, pattern) in specPhrases where Self.matches(pattern, text) {
            found.append(rule)
        }
        for clause in clauses(text) where Self.matches(specVerbAtClauseStart, clause) {
            found.append("spec verb “\(clause.prefix(24))”")
        }
        return found
    }

    /// Sentences, and the parts of a sentence a semicolon, colon, dash or middle dot starts.
    static func clauses(_ text: String) -> [String] {
        var parts = [text]
        for separator in [". ", "; ", ": ", " — ", " · "] {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: Fixture

    static func copyFixture() throws -> [String: Any] {
        let dir = try #require(AppPaths.fixturesDirectory())
        let data = try Data(contentsOf: dir.appendingPathComponent("design/design_copy.json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The prototype's note about its own looping demo (`pill` › `inserting`). The app draws "Same text ·
    /// one insertion attempt" there instead (`DesignCopyParityTests`), so this line never reaches a user.
    static let prototypeAnnotations: Set<String> = ["Looping tape-feed study · no text is inserted"]

    /// Every user-facing string in the fixture outside the catalogue, with where it came from.
    static func fixtureCopy() throws -> [(place: String, text: String)] {
        let root = try copyFixture()
        var out: [(String, String)] = []
        let pill = try #require(root["pill"] as? [String: [String: Any]])
        for (key, entry) in pill {
            if let status = entry["status"] as? String { out.append(("pill.\(key).status", status)) }
            if let text = entry["text"] as? String { out.append(("pill.\(key).text", text)) }
            for s in entry["strings"] as? [String] ?? [] { out.append(("pill.\(key).strings", s)) }
            for b in entry["buttons"] as? [[String: Any]] ?? [] {
                if let label = b["label"] as? String { out.append(("pill.\(key).button", label)) }
            }
        }
        let screens = try #require(root["screens"] as? [String: [String: String]])
        for (key, s) in screens {
            out.append(("screens.\(key).title", s["title"] ?? ""))
            out.append(("screens.\(key).subtitle", s["subtitle"] ?? ""))
        }
        let empty = try #require(root["emptyCopy"] as? [String: [String]])
        for (key, lines) in empty {
            for line in lines { out.append(("emptyCopy.\(key)", line)) }
        }
        // Markup and element ids the prototype keeps beside its copy (`#manualReview`, `<span …>`).
        return out.filter { !$0.1.isEmpty && !$0.1.hasPrefix("#") && !$0.1.hasPrefix("<")
            && !prototypeAnnotations.contains($0.1) }
    }

    // MARK: Tests

    /// The lint is not vacuous: every note 1.11.1 shipped as a consequence is caught.
    @Test(arguments: [
        "After 2 seconds name the wait; after failure offer recovery.",
        "Only the selected legacy listener needs this grant.",
        "Save held text before relaunch.",
        "Nothing was typed. First isolated tap is quiet; teach only after repeated misses.",
        "Keep live words visible with a small quality warning.",
        "Do not start a second conflicting audio session.",
        "Do not claim that unmarked words were checked.",
        "Uncertainty belongs to the smallest reliably aligned phrase.",
        "Show precisely which items remain.",
        "Recover only audio or text that is actually on disk.",
        "Show retry time when the provider supplies one.",
        "Name the missing permission; microphone-only capture may still work.",
        "Keep other meetings visible and isolate the affected row.",
        "Say whether text exists and whether anything may have been inserted.",
    ])
    func theLintCatchesEveryNoteThatShipped(_ note: String) {
        #expect(!Self.violations(note).isEmpty, "not caught: \(note)")
    }

    /// Copy that talks to the user passes, imperatives addressed to the user included.
    @Test(arguments: [
        "Check the field before trying again.",
        "Keep this window open until you copy it.",
        "Resolve or save this draft before a new dictation.",
        "Hold Right Control and say something. Your recent words will appear here.",
        "Final preview · hover to pause",
        "Recording starts when the microphone is open",
    ])
    func userFacingImperativesPass(_ copy: String) {
        #expect(Self.violations(copy).isEmpty, "\(copy): \(Self.violations(copy))")
    }

    @Test func everyCatalogueEntryReadsAsUserCopy() {
        for entry in RecoveryCatalog.entries {
            for (field, text) in [("headline", entry.headline), ("consequence", entry.consequence),
                                  ("action", entry.action)] {
                #expect(!text.isEmpty, "\(entry.id.rawValue) \(field) is empty")
                let found = Self.violations(text)
                #expect(found.isEmpty, "\(entry.id.rawValue) \(field) “\(text)”: \(found)")
            }
        }
    }

    /// The design source itself is clean, so a regenerated fixture cannot bring a note back.
    @Test func everyFixtureRecoveryEntryReadsAsUserCopy() throws {
        let errors = try #require(try Self.copyFixture()["errors"] as? [[String: Any]])
        #expect(errors.count == 59)
        for row in errors {
            let id = row["id"] as? String ?? "?"
            for field in ["headline", "consequence", "action"] {
                let text = try #require(row[field] as? String, "\(id) \(field)")
                let found = Self.violations(text)
                #expect(found.isEmpty, "\(id) \(field) “\(text)”: \(found)")
            }
        }
    }

    @Test func everyFixturePillScreenAndEmptyStringReadsAsUserCopy() throws {
        let copy = try Self.fixtureCopy()
        #expect(copy.count > 100, "fixture copy was not read (\(copy.count) strings)")
        for (place, text) in copy {
            let found = Self.violations(text)
            #expect(found.isEmpty, "\(place) “\(text)”: \(found)")
        }
    }

    /// The owner's report: the grey line under "The speech model isn’t ready" in onboarding step 4.
    @Test func theModelNotReadyCaptionTellsTheUserWhatIsHappening() {
        let m07 = RecoveryCatalog.entry(.M07)
        #expect(m07.headline == "The speech model isn’t ready")
        #expect(m07.consequence == "The model is installed but hasn’t finished loading.")
        #expect(m07.action == "Retry loading")
    }
}
