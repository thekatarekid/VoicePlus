import Foundation
import Shared

/// Per-app writing register, learned from the user's edits (P1.7 T7). Every feature is a
/// weighted running mean; `sampleCount` is the total weight seen. Cold-start profiles carry a
/// prior pseudo-count so a few real observations dominate quickly (see `StyleLearner`).
public struct StyleProfile: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public var version: Int = StyleProfile.schemaVersion
    public var appBundleID: String
    public var category: AppCategory
    /// Total observation weight (prior pseudo-count + ingested samples).
    public var sampleCount: Double
    /// Fraction of sentences that start with a capital letter.
    public var capitalizationRate: Double
    /// Fraction of utterances that end with a terminal period.
    public var terminalPeriodRate: Double
    /// Punctuation characters per word.
    public var punctuationDensity: Double
    /// Fraction of utterances containing at least one emoji.
    public var emojiRate: Double
    /// Fraction of utterances starting with a greeting ("hi", "hey", "hello", "dear"…).
    public var greetingRate: Double
    /// Fraction of utterances ending with a sign-off ("thanks", "cheers", "best"…).
    public var signOffRate: Double
    /// Average words per sentence.
    public var avgSentenceLength: Double
    /// Most frequent greeting / sign-off observed (verbatim, for persona consumers).
    public var preferredGreeting: String?
    public var preferredSignOff: String?
    public var updatedAt: Date
    /// V5 F1 — real landings learned from (accepted or edited), excluding the cold-start prior.
    /// Shown in Settings as "learned from N dictations". Absent in pre-V5 rows → 0.
    public var dictationCount: Int = 0

    /// Samples required before the stage trusts a learned feature over the prior.
    public static let confidentSampleCount: Double = 8
    /// Cap on effective weight so the profile keeps adapting (windowed mean).
    public static let maxEffectiveSamples: Double = 40

    public var isConfident: Bool { sampleCount >= Self.confidentSampleCount }

    /// Cold-start heuristics per app category.
    public static func coldStart(appBundleID: String, category: AppCategory, priorWeight: Double = 3) -> StyleProfile {
        var p = StyleProfile(appBundleID: appBundleID, category: category, sampleCount: priorWeight,
                             capitalizationRate: 1, terminalPeriodRate: 1, punctuationDensity: 0.12,
                             emojiRate: 0, greetingRate: 0, signOffRate: 0, avgSentenceLength: 14,
                             preferredGreeting: nil, preferredSignOff: nil, updatedAt: Date())
        switch category {
        case .mail:
            p.greetingRate = 0.6; p.signOffRate = 0.6; p.avgSentenceLength = 16
            p.preferredGreeting = "Hi"; p.preferredSignOff = "Thanks"
        case .chat:
            p.capitalizationRate = 0.25; p.terminalPeriodRate = 0.1; p.punctuationDensity = 0.06
            p.emojiRate = 0.2; p.avgSentenceLength = 8
        case .code, .terminal:
            // Verbatim registers: the style stage must not touch capitalization/punctuation.
            p.capitalizationRate = 0.5; p.terminalPeriodRate = 0.5; p.punctuationDensity = 0.2
            p.avgSentenceLength = 6
        case .prose:
            break
        }
        return p
    }

    public func encodedJSON() throws -> String {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        return String(decoding: try enc.encode(self), as: UTF8.self)
    }

    public static func decode(json: String) throws -> StyleProfile {
        try JSONDecoder().decode(StyleProfile.self, from: Data(json.utf8))
    }
}

extension StyleProfile {
    private enum CodingKeys: String, CodingKey {
        case version, appBundleID, category, sampleCount, capitalizationRate, terminalPeriodRate, punctuationDensity,
             emojiRate, greetingRate, signOffRate, avgSentenceLength, preferredGreeting, preferredSignOff, updatedAt,
             dictationCount
    }

    /// Tolerates profiles persisted before `dictationCount` existed.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? StyleProfile.schemaVersion
        appBundleID = try c.decode(String.self, forKey: .appBundleID)
        category = try c.decode(AppCategory.self, forKey: .category)
        sampleCount = try c.decode(Double.self, forKey: .sampleCount)
        capitalizationRate = try c.decode(Double.self, forKey: .capitalizationRate)
        terminalPeriodRate = try c.decode(Double.self, forKey: .terminalPeriodRate)
        punctuationDensity = try c.decode(Double.self, forKey: .punctuationDensity)
        emojiRate = try c.decode(Double.self, forKey: .emojiRate)
        greetingRate = try c.decode(Double.self, forKey: .greetingRate)
        signOffRate = try c.decode(Double.self, forKey: .signOffRate)
        avgSentenceLength = try c.decode(Double.self, forKey: .avgSentenceLength)
        preferredGreeting = try c.decodeIfPresent(String.self, forKey: .preferredGreeting)
        preferredSignOff = try c.decodeIfPresent(String.self, forKey: .preferredSignOff)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        dictationCount = try c.decodeIfPresent(Int.self, forKey: .dictationCount) ?? 0
    }
}

/// Style features of one piece of text. Computed by `StyleLearner.observe`.
public struct StyleObservation: Equatable, Sendable {
    public var capitalizedSentenceRate: Double
    public var hasTerminalPeriod: Bool
    public var punctuationDensity: Double
    public var hasEmoji: Bool
    public var greeting: String?
    public var signOff: String?
    public var avgSentenceLength: Double
    public var wordCount: Int
}
