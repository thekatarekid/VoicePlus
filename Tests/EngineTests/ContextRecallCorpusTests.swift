import Foundation
import Testing
import Shared
@testable import Engine

/// R4.1b acceptance — **entity recall and false insertions on the real corpus, with and without the
/// ranked context list.**
///
/// How the two arms are produced, and what the numbers do and do not mean.
///
/// - Pass 1 is the shipping recognizer (Parakeet TDT 0.6B v3) on the twenty real-room recordings.
///   That text is the *without list* arm: today's behaviour, since nothing in the shipping path can
///   act on the list (`Engine/Biasing/README.md` — the rescorer cannot substitute a word).
/// - The *with list* arm applies `ContextRecallProbe`, a **reference-blind** stand-in for what a
///   context-primed second pass does: a hypothesis word that sounds like a list term, and is not
///   that term, becomes that term. It never sees the reference. It is a measurement instrument, not
///   a pipeline stage — R5.2 wires the real consumer and R5.4 re-measures with Qwen3 in place.
/// - The simulated screen is **one workspace for all twenty utterances**, not per-utterance
///   tailoring: the corpus's own names alongside sixty unrelated ones, several of which are
///   phonetic neighbours of words the corpus gets *right*. That is where false insertions come
///   from, and a list that only ever helped would mean the screen had been cooked.
///
/// Skips loudly (never silently passes) when the corpus WAVs are absent (they are git-ignored) or
/// the model is not on disk. Nothing is downloaded here.
///
/// **Measured 11 September 2026** (Parakeet TDT 0.6B v3, `real-room/builtin`, 20 utterances, 10
/// curated entities):
///
///     without list  recall 0.600 (6/10)  false insertions 2  rate 0.0090  223 words
///     with list     recall 0.800 (8/10)  false insertions 6  rate 0.0270  222 words
///     recall gain +20.0 pp · false insertions +4 · list 189/400 · prompt 1000/1000 chars
///     gate opened on 6 of 20 utterances
///
/// Read the +4 honestly: three of them are the stand-in being blunt, not the list being wrong —
/// it rewrote "Sundays" as "Sundaes", "Thanks" as "Think" and "gate" as "Gateway", because a
/// phonetic rewriter has no acoustics and no language model to tell it not to. A real second pass
/// has both. The recalled words ("stand-up" → "standup", "Dr. Manon" → "Dr. Menon") are the ones
/// the list exists for.
@Suite("Ranked context list on the real corpus (R4.1b, real model)", .serialized)
struct ContextRecallCorpusTests {

    // MARK: what counts as an entity in this corpus

    /// Curated per script line: the tokens whose spelling a context list could plausibly decide.
    /// Numbers whose *formatting* differs between arms are deliberately excluded — that is R4.2's
    /// formatting work, not this list's job.
    static let entitiesByLine: [Int: [String]] = [
        2: ["Priya", "standup"],
        3: ["Kothari"],
        11: ["Carter", "Bandra", "Mumbai", "400050"],
        12: ["Menon"],
        15: ["Friday"],
        17: ["swift"],
    ]

    /// The workspace on screen while all twenty lines are dictated: a contact list, a chat sidebar,
    /// a file tree, a terminal. Contains the corpus's names — the premise of V3 §7.2 is that the
    /// visible words are the words about to be spoken — and a great deal else.
    static let screenBlocks: [(String, Double)] = [
        ("Kothari's — table for six — Thursday", 1.0),
        ("Priya Sharma · standup · deck review", 0.9),
        ("14 Carter Road, Bandra, Mumbai 400050", 0.8),
        ("Dr Menon · Monday morning · clinic", 0.8),
        ("Friday quarterly report · effect size", 0.7),
        ("swift build --scratch-path .build-r41b", 0.7),
        ("Devanagari transliteration notes", 0.6),
        // Sixty unrelated names, several of them sound-alikes of words this corpus gets right.
        ("Priyanka Bandana Menendez Mumbles Cartier Fridge Swifty Kothary", 0.5),
        ("TeamViewer AG Sundar Pichai Anthropic GRDB FluidAudio kubectl", 0.5),
        ("Zsh SQLite Devanagari Bengaluru Chennai Kolkata Hyderabad Pune", 0.5),
        ("Aarav Ananya Vihaan Diya Reyansh Ishaan Saanvi Aditi Kabir Myra", 0.5),
        ("Rohan Neha Arjun Kavya Nikhil Shreya Varun Pooja Manav Riya", 0.5),
        ("Quartermaster Lazarus Foxglove Museo Sundaes Recorded Gateway", 0.4),
        ("Invoice Rupees Deckhand Standoff Sessions Tokenizer Branches", 0.4),
    ]

    /// The user's own words: what the Dictionary and the correction ledger hold.
    static let dictionaryTerms: [(term: String, weight: Double)] = [("Kothari", 1.0), ("Devanagari", 1.0)]
    static let correctedTerms: [String] = ["Priya", "Menon"]

    // MARK: counters (the same fields as `Lab`'s `ContextRecallCounts`, which `Lab` cannot see)

    struct Counts {
        var utterances = 0
        var entitiesExpected = 0
        var entitiesRecalled = 0
        var falseInsertions = 0
        var hypothesisWords = 0
        var recall: Double? {
            entitiesExpected == 0 ? nil : Double(entitiesRecalled) / Double(entitiesExpected)
        }
        var falseInsertionRate: Double {
            hypothesisWords == 0 ? 0 : Double(falseInsertions) / Double(hypothesisWords)
        }
    }

    static func words(_ text: String) -> [String] { RealRoomCorpus.normalizedWords(text) }

    /// Case- and punctuation-insensitive word membership, so "Kothari's" recalls "Kothari".
    static func recalls(_ entity: String, in hypothesis: String) -> Bool {
        let needle = words(entity)
        guard !needle.isEmpty else { return false }
        let haystack = words(hypothesis)
        if needle.count == 1 { return haystack.contains(needle[0]) }
        return haystack.indices.contains {
            $0 + needle.count <= haystack.count && Array(haystack[$0..<($0 + needle.count)]) == needle
        }
    }

    /// List terms that the arm's text contains and the reference does not.
    static func falseInsertions(list: [String], hypothesis: String, reference: String) -> [String] {
        let hypothesisWords = Set(words(hypothesis))
        let referenceWords = Set(words(reference))
        var out: [String] = []
        for term in list {
            let termWords = words(term)
            guard termWords.count == 1, let word = termWords.first, word.count >= 3 else { continue }
            if hypothesisWords.contains(word), !referenceWords.contains(word) { out.append(term) }
        }
        return out
    }

    // MARK: the measurement

    @Test(.timeLimit(.minutes(60)))
    func entityRecallAndFalseInsertionsWithAndWithoutTheList() async throws {
        let pass = ProcessInfo.processInfo.environment["VOICEPLUS_CORPUS_PASS"] ?? "builtin"
        guard let items = RealRoomCorpus.items(pass: pass) else {
            print("SKIPPED: Fixtures/real-room/\(pass) and script.md have different counts — pairing would be wrong.")
            return
        }
        guard !items.isEmpty else {
            print("SKIPPED: no recordings in Fixtures/real-room/\(pass) (the WAVs are git-ignored).")
            return
        }
        let manager = ModelManager(maintenance: .skip)
        guard await manager.isPresent(.parakeetTDTv3) else {
            print("SKIPPED: parakeet-tdt-0.6b-v3 is not on disk; nothing is downloaded here.")
            return
        }
        let recognizer = try await RecognizerFactory.makeFinal(manager: manager)

        // One session for the corpus: the screen is fixed, the recent-words ring learns as it goes,
        // and the list is rebuilt before every utterance (V3 §7.3).
        let ring = RecentWordsRing()
        let harvester = ContextHarvester(sources: [
            AXTreeSource(provider: MockFocusedWindowText(Self.screenBlocks)),
            CorrectionSource(store: MockCorrectionStore(
                corrections: Self.correctedTerms.map { ($0, Date()) },
                dictionary: Self.dictionaryTerms)),
            ring,
        ])
        let session = ContextSession(harvester: harvester)
        let builder = PromptBuilder()
        let probe = ContextRecallProbe()
        let gate = ContextGate()

        var without = Counts()
        var with = Counts()
        var largestList = 0
        var longestPrompt = 0
        var gateOpened = 0
        var rows: [String] = []

        for item in items {
            let samples = try SampleAudioSource.load16k(url: item.processed ?? item.raw)
            let pass1 = try await recognizer.recognize(samples).joinedText
            let ranked = session.rebuild()
            let prompt = builder.build(ranked)
            largestList = max(largestList, ranked.count)
            longestPrompt = max(longestPrompt, prompt.prompt.count)

            // Caps hold for every single utterance, not just on average.
            #expect(ranked.count <= 400, "utterance \(item.index): list of \(ranked.count) terms")
            #expect(prompt.prompt.count <= builder.limits.maxCharacters,
                    "utterance \(item.index): prompt of \(prompt.prompt.count) characters")

            let decision = gate.decide(hypothesis: pass1, confidence: 0.9, context: ranked, prompt: prompt)
            if decision.shouldRefine { gateOpened += 1 }
            let resolved = probe.resolve(hypothesis: pass1, context: ranked)

            let expected = Self.entitiesByLine[item.index] ?? []
            let list = ranked.texts
            for (counts, text) in [(0, pass1), (1, resolved.text)] {
                var c = counts == 0 ? without : with
                c.utterances += 1
                c.entitiesExpected += expected.count
                c.entitiesRecalled += expected.filter { Self.recalls($0, in: text) }.count
                c.falseInsertions += Self.falseInsertions(list: list, hypothesis: text,
                                                          reference: item.reference).count
                c.hypothesisWords += Self.words(text).count
                if counts == 0 { without = c } else { with = c }
            }

            rows.append(String(format: "%02d  entities %d  pass1 %d  with-list %d  subs %d  %@",
                               item.index, expected.count,
                               expected.filter { Self.recalls($0, in: pass1) }.count,
                               expected.filter { Self.recalls($0, in: resolved.text) }.count,
                               resolved.count, decision.reason.rawValue))
            if resolved.count > 0 {
                rows.append("     pass1: \(pass1)")
                rows.append("     with:  \(resolved.text)")
            }
            // Recent confirmed vocabulary for the next utterance is the text that just landed.
            ring.record(pass1)
        }
        session.discard()
        #expect(session.current.isEmpty)

        // MARK: the table (fields match `Lab`'s `ContextRecallReport`, which renders it in R4.3)
        print("\n== R4.1b ranked context list · real-room/\(pass) · pass 1 = \(recognizer.name) ==")
        for row in rows { print(row) }
        print(String(repeating: "-", count: 78))
        func line(_ name: String, _ c: Counts) -> String {
            let pad = name.count >= 13 ? name : name + String(repeating: " ", count: 13 - name.count)
            let recall = c.recall.map { String(format: "%.3f", $0) } ?? "n/a"
            return pad + String(format: " utts %2d  entities %2d  recalled %2d  recall ", c.utterances,
                                c.entitiesExpected, c.entitiesRecalled)
                + recall
                + String(format: "  falseIns %2d  rate %.4f  words %4d",
                         c.falseInsertions, c.falseInsertionRate, c.hypothesisWords)
        }
        print(line("without list", without))
        print(line("with list", with))
        let gain = ((with.recall ?? 0) - (without.recall ?? 0)) * 100
        print(String(format: "recall gain %+.1f pp · false insertions %+d · list %d/400 · prompt %d/%d chars · gate opened %d/%d",
                     gain, with.falseInsertions - without.falseInsertions,
                     largestList, longestPrompt, builder.limits.maxCharacters, gateOpened, items.count))

        // MARK: the gate this item is measured by
        try #require(without.entitiesExpected > 0, "the corpus must contribute entities to score")
        #expect(with.entitiesRecalled >= without.entitiesRecalled,
                "the list must not cost entity recall on the real corpus")
        #expect(with.falseInsertions <= without.falseInsertions + items.count,
                "the list may not add more than one false insertion per utterance")
        #expect(largestList <= 400)
        #expect(longestPrompt <= builder.limits.maxCharacters)
    }
}
