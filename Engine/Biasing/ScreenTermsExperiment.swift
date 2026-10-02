import Foundation
import Shared

// N11-lab (F27, Investigation R3 §E6) — does putting on-screen words into the per-turn boost layer
// help recognition? Three arms over the entity suite, through the rubric and whatever recognizer
// (normally the CTC rescorer) the caller supplies:
//
//   noScreen          the boost list without any screen candidates (today's default)
//   matchingScreen    the window shows the spoken entity → screen terms admitted to the per-turn layer
//   distractorScreen  the window shows plausible but unspoken terms → measures false insertions
//
// Screen terms stay OFF by default (`ContextRubric.Config.screenTermsInBoost == false`) until a
// measured Lab report passes (`ScreenTermsReport.passes` in Lab). Screen text here is synthetic
// fixture text; it is data, never instructions, and only typed terms ever reach the boost list.

public struct ScreenTermsExperiment: Sendable {
    public enum Arm: String, CaseIterable, Sendable, Codable {
        case noScreen, matchingScreen, distractorScreen
    }

    /// One utterance of the suite (decoded from `Fixtures/context/entity_screens.json`).
    public struct Item: Sendable, Codable, Equatable {
        public var file: String
        public var entities: [String]
        /// `SurfaceKind.id` of the field being dictated into.
        public var surface: String
        public var matching: String
        public var distractor: String

        public init(file: String, entities: [String], surface: String, matching: String, distractor: String) {
            self.file = file; self.entities = entities; self.surface = surface
            self.matching = matching; self.distractor = distractor
        }
    }

    public struct Suite: Sendable, Codable, Equatable {
        public var distractorTerms: [String]
        public var items: [Item]

        public static func load(from url: URL) throws -> Suite {
            try JSONDecoder().decode(Suite.self, from: Data(contentsOf: url))
        }

        /// `Fixtures/context/entity_screens.json`, when the fixtures directory exists.
        public static func bundled() throws -> Suite? {
            guard let dir = AppPaths.fixturesDirectory() else { return nil }
            let url = dir.appendingPathComponent("context/entity_screens.json")
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try load(from: url)
        }
    }

    /// Dictionary terms present in every arm (the user's own list; the screen is the only variable).
    public var dictionary: [String]
    public var rubric: ContextRubric
    public var now: Date

    public init(dictionary: [String] = [], rubric: ContextRubric = ContextRubric(), now: Date = Date()) {
        self.dictionary = dictionary
        self.rubric = rubric
        self.now = now
    }

    public static func surface(_ id: String) -> SurfaceResolution {
        let kind: SurfaceKind
        switch id {
        case "terminal": kind = .terminal
        case "spreadsheetCell": kind = .spreadsheetCell
        case "chatComposer": kind = .chatComposer
        case "urlBar": kind = .urlBar
        case "searchField": kind = .searchField
        case "emailBody": kind = .emailBody
        case "markdownEditor": kind = .markdownEditor
        case "codeEditor": kind = .codeEditor
        case "canvas": kind = .canvas
        case "secure": kind = .secure
        default:
            if id.hasPrefix("formField:") { kind = .formField(label: String(id.dropFirst("formField:".count))) }
            else { kind = .prose }
        }
        return SurfaceResolution(kind: kind, confidence: 0.9, isWebArea: false, signals: ["lab"])
    }

    /// The boost list one arm hands the recognizer for one item.
    public func boostTerms(for item: Item, arm: Arm) -> [String] {
        var candidates = ContextCandidates.dictionary(dictionary.map { DictionaryEntry(term: $0, origin: .personal) })
        var r = rubric
        switch arm {
        case .noScreen:
            r.config.screenTermsInBoost = false
        case .matchingScreen, .distractorScreen:
            r.config.screenTermsInBoost = true
            let text = arm == .matchingScreen ? item.matching : item.distractor
            candidates += ContextCandidates.screen(text: text, caretOffset: text.count, observedAt: now)
        }
        return r.ranked(candidates: candidates, surface: Self.surface(item.surface), now: now).boostTerms
    }

    /// Runs every arm over `items`. `recognize(item, boostTerms)` returns the final hypothesis; the
    /// caller owns audio, models and residency. Metrics count entity recall and false insertions of
    /// boosted terms that are not in the reference.
    public func run(items: [Item], reference: (Item) -> String,
                    recognize: (Item, [String]) async throws -> String) async rethrows -> [Arm: BiasingMetrics] {
        var out: [Arm: BiasingMetrics] = [:]
        for arm in Arm.allCases {
            var m = BiasingMetrics()
            for item in items {
                let terms = boostTerms(for: item, arm: arm)
                let hypothesis = try await recognize(item, terms)
                m.record(reference: reference(item), hypothesis: hypothesis, entities: item.entities, biasList: terms)
            }
            out[arm] = m
        }
        return out
    }
}
