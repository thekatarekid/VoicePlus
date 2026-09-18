import Foundation
import Testing
@testable import Pipeline
import Shared

/// R4.2 — golden files for field-role formatting and continuation.
///
/// One `.golden` file per case in `Fixtures/formatters/fieldrole/`: the input block describes the
/// app, the AX role/hints and the text around the cursor; the block after `---` is the recorded
/// decision and output. A formatting change shows up as a readable diff in that file rather than
/// as a rewritten assertion, which is the point.
///
/// Re-record after an intentional change:
///     VOICEPLUS_UPDATE_GOLDENS=1 swift test --scratch-path .build-r42 --filter FieldRoleGolden
/// and read the diff before committing it.
struct FieldRoleGoldenTests {

    // MARK: - Golden file

    struct Golden {
        var url: URL
        var inputBlock: String
        var expected: String

        static let separator = "---"

        static func load(_ url: URL) throws -> Golden {
            let raw = try String(contentsOf: url, encoding: .utf8)
            let lines = raw.components(separatedBy: "\n")
            guard let cut = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == separator }) else {
                throw GoldenError.malformed(url.lastPathComponent)
            }
            return Golden(url: url,
                          inputBlock: lines[..<cut].joined(separator: "\n"),
                          expected: lines[(cut + 1)...].joined(separator: "\n").trimmingCharacters(in: .newlines))
        }

        func write(actual: String) throws {
            let body = inputBlock.trimmingCharacters(in: .newlines) + "\n" + Self.separator + "\n" + actual + "\n"
            try body.write(to: url, atomically: true, encoding: .utf8)
        }

        var fields: [String: String] {
            var out: [String: String] = [:]
            for line in inputBlock.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let colon = trimmed.firstIndex(of: ":") else { continue }
                let key = String(trimmed[..<colon])
                out[key] = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
            return out
        }
    }

    enum GoldenError: Error { case malformed(String), noFixtures }

    // MARK: - Value coding (readable, unambiguous about whitespace)

    static func quote(_ s: String) -> String {
        var out = "\""
        for c in s {
            switch c {
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            default: out.append(c)
            }
        }
        return out + "\""
    }

    static func unquote(_ s: String) -> String {
        guard s.hasPrefix("\""), s.hasSuffix("\""), s.count >= 2 else { return s }
        var out = ""
        var escaped = false
        for c in s.dropFirst().dropLast() {
            if escaped {
                switch c {
                case "n": out += "\n"
                case "t": out += "\t"
                default: out.append(c)
                }
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else {
                out.append(c)
            }
        }
        return out
    }

    // MARK: - Input decoding

    static func field(from f: [String: String]) -> FieldContext {
        let hints = (f["hints"] ?? "").split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        return FieldContext(
            appBundleID: (f["app"]?.isEmpty ?? true) ? nil : f["app"],
            axRole: (f["role"]?.isEmpty ?? true) ? nil : f["role"],
            axSubrole: (f["subrole"]?.isEmpty ?? true) ? nil : f["subrole"],
            hints: hints.filter { !$0.isEmpty },
            isMultiline: f["multiline"].flatMap(Bool.init),
            submitsOnReturn: f["submits"].flatMap(Bool.init),
            textBeforeCursor: unquote(f["before"] ?? ""),
            textAfterCursor: unquote(f["after"] ?? "")
        )
    }

    /// `words` is the ASR output: space-separated tokens, each optionally `token@confidence`
    /// (`memoized@0.41` exercises the Bet 9 low-confidence path). 0.3 s of audio per token.
    static func spans(from line: String) -> [TranscriptSpan] {
        line.split(separator: " ").enumerated().map { i, raw in
            var text = String(raw)
            var confidence: Float = 0.95
            if let at = text.lastIndex(of: "@"), let value = Float(text[text.index(after: at)...]) {
                confidence = value
                text = String(text[..<at])
            }
            return TranscriptSpan(text: text, confidence: confidence,
                                  audioRange: (Double(i) * 0.3)...(Double(i) * 0.3 + 0.3),
                                  provenance: [.asr])
        }
    }

    // MARK: - Output encoding

    static func record(_ result: FormattedField) -> String {
        let r = result.rules, c = result.continuation
        return """
        fieldRole: \(result.role.rawValue)
        formatter: \(r.category.rawValue)
        autoCapitalize: \(r.autoCapitalize)
        trailingPeriod: \(r.trailingPeriod)
        allowSubmit: \(r.allowSubmit)
        preserveIdentifiers: \(r.preserveIdentifiers)
        leading: \(quote(c.leading))
        trailing: \(quote(c.trailing))
        capitalizeFirstWord: \(c.capitalizeFirstWord)
        paragraphBreak: \(c.paragraphBreak)
        words: \(quote(result.spans.renderedText))
        text: \(quote(result.text))
        """
    }

    // MARK: - The test

    static var goldenDirectory: URL? {
        AppPaths.fixturesDirectory()?.appendingPathComponent("formatters/fieldrole", isDirectory: true)
    }

    static var goldenFiles: [URL] {
        guard let dir = goldenDirectory,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        return files.filter { $0.pathExtension == "golden" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static let updating = ProcessInfo.processInfo.environment["VOICEPLUS_UPDATE_GOLDENS"] == "1"

    @Test("golden fixtures exist for terminal, editor, chat, mail and mid-sentence")
    func fixturesPresent() throws {
        let names = Self.goldenFiles.map { $0.deletingPathExtension().lastPathComponent }
        #expect(names.count >= 5, "expected the R4.2 golden set in Fixtures/formatters/fieldrole")
        for required in ["terminal_in_editor", "terminal_identifiers", "editor_code",
                         "chat_composer", "mail_body_paragraph", "mail_mid_sentence"] {
            #expect(names.contains(required), "missing golden \(required)")
        }
    }

    @Test("field-role formatting matches the golden", arguments: FieldRoleGoldenTests.goldenFiles)
    func golden(url: URL) async throws {
        let golden = try Golden.load(url)
        let fields = golden.fields
        let field = Self.field(from: fields)
        let input = Self.spans(from: fields["words"] ?? "")
        try #require(!input.isEmpty, "golden \(url.lastPathComponent) has no words")

        let result = try await FieldRoleFormatter().format(input, field: field)
        let actual = Self.record(result)

        if Self.updating {
            try golden.write(actual: actual)
            return
        }
        #expect(actual == golden.expected, """
        golden \(url.lastPathComponent) changed.
        --- expected ---
        \(golden.expected)
        --- actual ---
        \(actual)
        """)

        // The contract every stage owes, checked on every golden.
        #expect(ConfidenceContract.verify(input: input, output: result.spans).isEmpty)
        #expect(result.spans.allSatisfy { $0.provenance.last == FieldRoleFormatterStage.stageID })
        #expect(result.spans.allSatisfy { $0.provenance.first == .asr })
    }
}
