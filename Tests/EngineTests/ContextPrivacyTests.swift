import Foundation
import Testing
import Shared
@testable import Engine

/// R4.1b · V3 §7.3 — screen text stays in memory: rebuilt per utterance, never written to disk,
/// never logged, excluded from history, diagnostics and sync.
///
/// Two of those are proved structurally (a type that cannot be encoded cannot be persisted or
/// synced; a file with no logging call cannot log), and one behaviourally: a sentinel string is
/// pushed through the whole harvest → rank → prompt → gate path, and then every byte the app owns
/// on disk is searched for it.
@Suite("Context privacy (R4.1b)", .serialized)
struct ContextPrivacyTests {

    /// A string that exists nowhere else on the machine, short enough to be harvested as a term
    /// (`EntityExtractor` drops anything longer than forty characters).
    static func sentinel() -> String {
        "Zephyr" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))
    }

    /// Repo root, from this file's path (`Tests/EngineTests/…`).
    static func repoRoot(file: StaticString = #filePath) -> URL {
        var url = URL(fileURLWithPath: "\(file)")
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url
    }

    // MARK: never persisted

    @Test
    func screenTextIsNeverWrittenToDisk() throws {
        let secret = Self.sentinel()
        let support = AppPaths.supportDirectory()
        let before = Self.files(under: support)

        // The whole path, exactly as an utterance drives it.
        let harvester = ContextHarvester(sources: [
            AXTreeSource(provider: MockFocusedWindowText([("Acme \(secret) Project", 1.0)])),
        ])
        let session = ContextSession(harvester: harvester)
        let ranked = session.rebuild()
        #expect(ranked.contains(secret), "the harvest should have seen the sentinel")
        let prompt = PromptBuilder().build(ranked)
        #expect(prompt.prompt.contains(secret), "the prompt should have carried it in memory")
        let decision = ContextGate().decide(hypothesis: "acme zephyr project", confidence: 0.9,
                                            context: ranked, prompt: prompt)
        #expect(decision.summary.contains(secret) == false, "a loggable decision must not carry a term")
        session.discard()
        #expect(session.current.isEmpty)

        // Nothing under ~/Library/Application Support/VoicePlus may contain it — not the database,
        // not a JSON file, not a log — and no new file may have appeared because of the harvest.
        // Model weights are skipped by size: a stray context write is small, and reading two
        // gigabytes of `.mlmodelc` to prove it does not contain a UUID is not evidence.
        let after = Self.files(under: support)
        for file in after {
            guard let data = Self.readable(file) else { continue }
            #expect(Self.contains(secret, in: data) == false, "screen text reached \(file.lastPathComponent)")
        }
        for file in after.subtracting(before) {
            guard let data = Self.readable(file) else { continue }
            #expect(Self.contains(secret, in: data) == false, "screen text reached new file \(file.lastPathComponent)")
        }
        // And the temporary directory, the other place a stray write would land.
        for file in Self.files(under: URL(fileURLWithPath: NSTemporaryDirectory()), limit: 400) {
            guard let data = Self.readable(file) else { continue }
            #expect(Self.contains(secret, in: data) == false, "screen text reached \(file.path)")
        }
    }

    /// History, diagnostics and sync all move `Codable` values. The list is not one, and neither is
    /// the prompt-shaped result — so there is no code path that could carry it there by accident.
    @Test
    func nothingInTheContextPathIsEncodable() {
        #expect(!(RankedContext.self is any Encodable.Type))
        #expect(!(RankedContextTerm.self is any Encodable.Type))
        #expect(!(PromptBuilder.Result.self is any Encodable.Type))
        #expect(!(ContextGate.Decision.self is any Encodable.Type))
    }

    // MARK: never logged

    /// The list and the prompt are never logged — enforced by reading the source, because a review
    /// note would not survive the next edit.
    @Test
    func theContextPathContainsNoLoggingCall() throws {
        let biasing = Self.repoRoot().appendingPathComponent("Engine/Biasing")
        let owned = ["ContextRanker.swift", "PromptBuilder.swift", "ContextGate.swift", "BoostVocabulary.swift"]
        for name in owned {
            let source = try String(contentsOf: biasing.appendingPathComponent(name), encoding: .utf8)
            for forbidden in ["Log.", "os_log", "NSLog", "Logger(", "print(", "debugPrint", "dump("] {
                // Comments say the word "log"; only a call is a leak.
                #expect(Self.codeLines(of: source).contains { $0.contains(forbidden) } == false,
                        "\(name) contains \(forbidden)")
            }
        }
    }

    /// Everything a caller is invited to log is counts and enum cases.
    @Test
    func theLoggableSummariesCarryNoTerms() {
        let ranked = ContextRanker().rank([
            ContextEntry(text: "Zephyr", source: .axTree),
            ContextEntry(text: "Devanagari", source: .dictionary),
        ])
        let prompt = PromptBuilder().build(ranked)
        let decision = ContextGate().decide(hypothesis: "zeffer", confidence: 0.9,
                                            context: ranked, prompt: prompt)
        for line in [ranked.shape, prompt.shape, decision.summary] {
            #expect(line.contains("Zephyr") == false)
            #expect(line.contains("Devanagari") == false)
        }
    }

    // MARK: helpers

    static func codeLines(of source: String) -> [String] {
        source.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") && !$0.hasPrefix("///") && !$0.hasPrefix("*") }
    }

    static func files(under directory: URL, limit: Int = 4_000) -> Set<URL> {
        var out: Set<URL> = []
        guard let walker = FileManager.default.enumerator(at: directory,
                                                          includingPropertiesForKeys: [.isRegularFileKey],
                                                          options: [.skipsHiddenFiles]) else { return out }
        for case let url as URL in walker {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                out.insert(url)
                if out.count >= limit { break }
            }
        }
        return out
    }

    /// File contents, when the file is small enough that a text write could plausibly be in it.
    static func readable(_ url: URL, maxBytes: Int = 8_000_000) -> Data? {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0, size <= maxBytes else { return nil }
        return try? Data(contentsOf: url)
    }

    static func contains(_ needle: String, in data: Data) -> Bool {
        guard let pattern = needle.data(using: .utf8) else { return false }
        return data.range(of: pattern) != nil
    }
}
