import Foundation
import Testing

/// G0.3 verify — `DESIGN.md` v2 quotes the verified design's copy; these tests hold every quoted
/// table to its source so the document cannot drift from the fixtures S2, S6, S7 and S8 build from.
///
/// Sources: `Fixtures/design/design_copy.json` (pill statuses and actions, screen titles, empty
/// states, per-screen error mapping, recovery catalogue) and the prototype `docs/design-history/design/design_v3.html`
/// (onboarding steps, menu rows), which the fixture script does not export. Sample data in the
/// prototype ("Mail", "Friday check-in", counts, "Right Control") is written in the document as a
/// placeholder (`<app>`, `<turn title>`, `N`, `<key>`); `template(_:)` applies the same mapping.
@Suite("DESIGN.md copy parity (G0.3)")
struct DesignDocumentCopyTests {

    static let packageRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url
    }()

    static func read(_ relativePath: String) throws -> String {
        try String(contentsOf: packageRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    static func copyFixture() throws -> [String: Any] {
        let data = try Data(contentsOf: packageRoot.appendingPathComponent("Fixtures/design/design_copy.json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - §8.6 state inventory: status line and actions per state

    @Test func stateInventoryCarriesTheFixtureStatusAndActions() throws {
        let doc = try Self.read("DESIGN.md")
        let copy = try Self.copyFixture()
        let pill = try #require(copy["pill"] as? [String: [String: Any]])
        let states = try #require(copy["states"] as? [[String]])
        let rows = Self.tableRows(try #require(Self.section(doc, from: "### 8.6 State inventory", to: "**State priority:**")))
        var order: [String] = []
        for state in states {
            let key = state[0], id = state[1]
            let row = try #require(rows.first { $0.count == 6 && $0[0] == id && $0[1] == "`\(key)`" },
                                   "§8.6 has no row \(id) `\(key)`")
            order.append(id)
            let status = row[4]
            let entry = try #require(pill[key], "fixture has no pill copy for \(key)")
            if key == "idle" {
                #expect(status == "—", "I0 idle shows no status line")
                continue
            }
            let line = try #require((entry["status"] as? String) ?? (entry["text"] as? String), "\(key) has no status")
            let expected = Self.template(line)
            #expect(status.contains(expected), "\(id) status \"\(status)\" does not carry the fixture's \"\(expected)\"")
            for button in (entry["buttons"] as? [[String: Any]]) ?? [] {
                let label = try #require(button["label"] as? String)
                #expect(status.contains(label), "\(id) is missing the fixture action \"\(label)\"")
            }
        }
        #expect(order.count == 26 && Set(order).count == 26)
    }

    /// Delivery outcomes (§4) read as the fixture's pill statuses.
    @Test func deliveryOutcomesUseTheFixtureStatuses() throws {
        let doc = try Self.read("DESIGN.md")
        let pill = try #require(try Self.copyFixture()["pill"] as? [String: [String: Any]])
        let rows = Self.tableRows(try #require(Self.section(doc, from: "| Outcome | Pill status | Today tag |", to: "Kept from v1")))
        let expected: [(String, String)] = [
            ("`delivered(verified: true)`", "inserted"), ("`partial`", "partial"), ("`held`", "held"), ("`failed`", "error"),
        ]
        for (outcome, key) in expected {
            let row = try #require(rows.first { $0.first == outcome }, "§4 has no row \(outcome)")
            let status = try #require(pill[key]?["status"] as? String)
            #expect(row[1] == Self.template(status), "\(outcome): \(row[1]) ≠ fixture \(status)")
        }
        let unverified = try #require(rows.first { $0.first?.hasPrefix("`delivered(verified: false)`") == true })
        #expect(unverified[1] == (pill["unconfirmed"]?["status"] as? String))
    }

    // MARK: - §9 window copy

    static let screenLabels: [String: String] = [
        "today": "Today", "turn": "Turn detail", "meetings": "Meetings", "dictionary": "Dictionary & Apps",
        "voice": "Voice", "privacy": "Privacy", "settings": "Settings", "shortcuts": "Shortcuts",
        "models": "Models", "services": "Providers & Sync", "menu": "Menu (review surface)",
        "recovery": "Recovery sheet",
    ]

    static let emptyLabels: [String: String] = [
        "today": "Today", "turn": "Turn detail", "meetings": "Meetings", "meeting-detail": "Meeting detail",
        "dictionary": "Dictionary", "voice": "Voice", "privacy": "Privacy", "settings": "Settings",
        "shortcuts": "Shortcuts", "models": "Models", "services": "Providers & Sync", "onboarding": "Onboarding",
        "menu": "Menu", "recovery": "Recovery",
    ]

    @Test func screenTitlesAndSubtitlesAreTheFixtures() throws {
        let doc = try Self.read("DESIGN.md")
        let screens = try #require(try Self.copyFixture()["screens"] as? [String: [String: String]])
        let rows = Self.tableRows(try #require(Self.section(doc, from: "**Titles and subtitles**", to: "**Four renderings.**")))
        #expect(Set(screens.keys) == Set(Self.screenLabels.keys))
        for (key, label) in Self.screenLabels {
            let row = try #require(rows.first { $0.first == label }, "§9 titles table has no row \(label)")
            let fixture = try #require(screens[key])
            #expect(row[1] == Self.template(fixture["title"] ?? ""), "\(label) title \(row[1])")
            #expect(row[2] == Self.template(fixture["subtitle"] ?? ""), "\(label) subtitle \(row[2])")
        }
    }

    @Test func emptyStatesAreTheFixtures() throws {
        let doc = try Self.read("DESIGN.md")
        let empty = try #require(try Self.copyFixture()["emptyCopy"] as? [String: [String]])
        let rows = Self.tableRows(try #require(Self.section(doc, from: "**Empty states**", to: "**Each screen's error example**")))
        #expect(Set(empty.keys) == Set(Self.emptyLabels.keys))
        #expect(rows.count == empty.count + 1, "header + one row per fixture empty state")
        for (key, label) in Self.emptyLabels {
            let row = try #require(rows.first { $0.first == label }, "§9 empty-state table has no row \(label)")
            let fixture = try #require(empty[key])
            #expect(Array(row.dropFirst()) == fixture.map(Self.template), "\(label): \(row) ≠ \(fixture)")
        }
    }

    @Test func screenErrorsAreTheFixtureMappingAndExistInTheCatalogue() throws {
        let doc = try Self.read("DESIGN.md")
        let copy = try Self.copyFixture()
        let mapping = try #require(copy["screenError"] as? [String: String])
        let errors = try #require(copy["errors"] as? [[String: Any]])
        let ids = Set(errors.compactMap { $0["id"] as? String })
        #expect(errors.count == 59)
        // The paragraph is hard-wrapped; compare with line breaks read as spaces.
        let paragraph = try #require(Self.section(doc, from: "**Each screen's error example**", to: "### 9.1"))
            .replacingOccurrences(of: "\n", with: " ")
        for (key, id) in mapping {
            let label = try #require(Self.emptyLabels[key])
            #expect(paragraph.contains("\(label) \(id)"), "§9 does not map \(label) to \(id)")
            #expect(ids.contains(id), "\(id) is not in the recovery catalogue")
        }
    }

    // MARK: - §7.1 canonical strings → recovery catalogue

    @Test func canonicalV3StringsMapToCatalogueEntriesVerbatim() throws {
        let doc = try Self.read("DESIGN.md")
        let errors = try #require(try Self.copyFixture()["errors"] as? [[String: Any]])
        let rows = Self.tableRows(try #require(Self.section(doc, from: "| V3 string | Catalogue |", to: "Further rules from design §10")))
        for id in ["D01", "A02", "A06"] {
            let entry = try #require(errors.first { $0["id"] as? String == id })
            let row = try #require(rows.first { $0.count == 3 && $0[1] == id }, "§7.1 has no row \(id)")
            for field in ["headline", "consequence", "action"] {
                let value = try #require(entry[field] as? String)
                #expect(row[2].contains(value), "\(id) \(field) \"\(value)\" not quoted verbatim")
            }
        }
    }

    // MARK: - §11 onboarding (prototype `steps`) and §10 menu (prototype `case'menu'`)

    @Test func onboardingStepsAreThePrototypeStepsPlusTheOwnersVoiceStep() throws {
        let doc = try Self.read("DESIGN.md")
        let html = try Self.read("docs/design-history/design/design_v3.html")
        let source = try #require(Self.section(html, from: "case'onboarding':{const steps=[", to: "];"))
        let steps = Self.captures(#"\['([^']*)','([^']*)','([^']*)'\]"#, in: source)
        #expect(steps.count == 6, "prototype onboarding has \(steps.count) steps")
        #expect(html.contains("Setup · ${setupStep+1} of 6"))

        let rows = Self.tableRows(try #require(Self.section(doc, from: "| Step | Heading (prototype) |", to: "- The prototype's Microphone body")))
        let names = ["Welcome", "Microphone", "Typing access", "Model", "Try dictation", "Ready"]
        #expect(rows.dropFirst().map { $0[0] }
                == ["Welcome", "Microphone", "Typing access", "Model", "Try dictation",
                    "**Voice** (owner addition, skippable)", "Ready"])
        // The prototype's own annotation of its simulation is not product copy (DESIGN.md §0, §11).
        let annotation = " The real app requests the macOS permission here."
        for (name, step) in zip(names, steps) {
            let row = try #require(rows.first { $0.first == name }, "§11 has no step \(name)")
            #expect(row[1] == step[0], "\(name) heading")
            #expect(row[2] == Self.template(step[1].replacingOccurrences(of: annotation, with: "")), "\(name) body")
            #expect(row[3] == step[2], "\(name) primary")
        }
        #expect(steps[1][1].contains(annotation), "the dropped sentence is still the prototype's")
        #expect(doc.contains("**Welcome → Microphone → Typing access → Model → Try dictation → Voice → Ready**"))
        #expect(doc.contains("\"Setup · N of 7\""))
    }

    @Test func menuRowsAreThePrototypeRows() throws {
        let doc = try Self.read("DESIGN.md")
        let html = try Self.read("docs/design-history/design/design_v3.html")
        let source = try #require(Self.section(html, from: "case'menu':", to: "break;"))
        let menu = try #require(Self.section(doc, from: "## 10. The menu", to: "## 11. Onboarding"))
        let rows = Self.captures(#"row\('([^']*)','([^']*)'"#, in: source)
        #expect(rows.count == 6)
        for row in rows {
            let title = row[0].replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            #expect(menu.contains("\"\(title)\""), "§10 is missing the prototype row \"\(title)\"")
            #expect(menu.contains("\"\(row[1])\""), "§10 is missing the helper \"\(row[1])\"")
        }
        for label in Self.captures(#"btn\('([^']*)'"#, in: source).map({ $0[0] }) {
            #expect(menu.contains("**\(label)**"), "§10 is missing the control \"\(label)\"")
        }
    }

    // MARK: - Owner key substitution

    /// Every "Right Control" in the document is about the substitution itself, never a quoted
    /// string that should have been rendered as `<key>` (DESIGN.md §0.1).
    @Test func noQuotedCopyHardCodesTheDesignsDefaultKey() throws {
        let doc = try Self.read("DESIGN.md")
        for line in doc.split(separator: "\n") where line.contains("Right Control") {
            #expect(line.contains("rendered") || line.contains("| Default key |"), "unsubstituted key: \(line)")
        }
    }

    // MARK: - Helpers

    /// The document's placeholder for each piece of prototype sample data.
    static func template(_ text: String) -> String {
        var out = text
            .replacingOccurrences(of: "Right Control", with: "<key>")
            .replacingOccurrences(of: "Friday check-in", with: "<turn title>")
            .replacingOccurrences(of: "Today, 12:42", with: "<day>, <time>")
            .replacingOccurrences(of: "Mail", with: "<app>")
            .replacingOccurrences(of: #"\b\d+ words\b"#, with: "N words", options: .regularExpression)
        while out.hasSuffix(" ") || out.hasSuffix("·") { out.removeLast() }
        return out
    }

    /// Text strictly between the first `from` and the next `to` after it.
    static func section(_ text: String, from: String, to: String) -> String? {
        guard let start = text.range(of: from) else { return nil }
        guard let end = text.range(of: to, range: start.upperBound..<text.endIndex) else { return nil }
        return String(text[start.lowerBound..<end.lowerBound])
    }

    /// Cells of every Markdown table row in `text` (separator rows skipped).
    static func tableRows(_ text: String) -> [[String]] {
        text.split(separator: "\n").compactMap { line -> [String]? in
            guard line.hasPrefix("|") else { return nil }
            let cells = line.split(separator: "|", omittingEmptySubsequences: false)
                .dropFirst().dropLast().map { $0.trimmingCharacters(in: .whitespaces) }
            if cells.allSatisfy({ $0.allSatisfy { $0 == "-" || $0 == ":" } }) { return nil }
            return Array(cells)
        }
    }

    /// Capture groups of every match of `pattern`.
    static func captures(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            (1..<match.numberOfRanges).map { ns.substring(with: match.range(at: $0)) }
        }
    }
}
