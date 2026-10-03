import Foundation
import Shared

/// Learns a per-app `StyleProfile` from `(original, edited)` pairs — what the pipeline
/// produced vs. what the user actually sent. The *edited* text is the ground truth for the
/// user's register; an unedited acceptance still counts, at lower weight.
public struct StyleLearner: Sendable {
    public let store: any StyleProfileStore
    /// Weight of a sample the user actively edited vs. one accepted verbatim.
    public var editedWeight: Double = 1.0
    public var acceptedWeight: Double = 0.4
    /// Samples shorter than this (in words) are ignored — too little signal.
    public var minimumWords = 2

    public init(store: any StyleProfileStore) { self.store = store }

    /// Current (or cold-start) profile for an app. Never returns nil; never writes.
    public func profile(for bundleID: String, register: Utterance.Register = .unknown) throws -> StyleProfile {
        if let stored = try store.profile(for: bundleID) { return stored }
        return StyleProfile.coldStart(appBundleID: bundleID, category: AppCategoryTable.category(for: bundleID))
    }

    /// Updates and persists the profile for `bundleID`. Returns the new profile.
    @discardableResult
    public func ingest(original: String, edited: String, bundleID: String) throws -> StyleProfile {
        var profile = try profile(for: bundleID)
        let obs = Self.observe(edited)
        guard obs.wordCount >= minimumWords else { return profile }
        let normalizedOriginal = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedEdited = edited.trimmingCharacters(in: .whitespacesAndNewlines)
        let weight = normalizedOriginal == normalizedEdited ? acceptedWeight : editedWeight
        // H22 — a missing full stop the pipeline produced is not the user's style: only learn
        // "no period" when the user removed one we wrote. Learning "period" always counts.
        let learnsPeriod = obs.hasTerminalPeriod || Self.observe(normalizedOriginal).hasTerminalPeriod
        Self.update(&profile, with: obs, weight: weight, learnsPeriod: learnsPeriod)
        try store.save(profile)
        return profile
    }

    /// Pure running-mean update (windowed: effective weight capped at `maxEffectiveSamples`).
    public static func update(_ p: inout StyleProfile, with obs: StyleObservation, weight: Double,
                              learnsPeriod: Bool = true) {
        let n = min(p.sampleCount, StyleProfile.maxEffectiveSamples)
        let total = n + weight
        func mean(_ old: Double, _ new: Double) -> Double { (old * n + new * weight) / total }
        p.capitalizationRate = mean(p.capitalizationRate, obs.capitalizedSentenceRate)
        if learnsPeriod { p.terminalPeriodRate = mean(p.terminalPeriodRate, obs.hasTerminalPeriod ? 1 : 0) }
        p.punctuationDensity = mean(p.punctuationDensity, obs.punctuationDensity)
        p.emojiRate = mean(p.emojiRate, obs.hasEmoji ? 1 : 0)
        p.greetingRate = mean(p.greetingRate, obs.greeting == nil ? 0 : 1)
        p.signOffRate = mean(p.signOffRate, obs.signOff == nil ? 0 : 1)
        p.avgSentenceLength = mean(p.avgSentenceLength, obs.avgSentenceLength)
        if let g = obs.greeting { p.preferredGreeting = g }
        if let s = obs.signOff { p.preferredSignOff = s }
        p.sampleCount += weight
        p.dictationCount += 1
        p.updatedAt = Date()
    }

    // MARK: - Feature extraction

    static let greetings: Set<String> = ["hi", "hey", "hello", "dear", "morning", "yo", "greetings", "hiya"]
    static let signOffs: Set<String> = ["thanks", "thank you", "cheers", "best", "regards", "kind regards",
                                        "best regards", "talk soon", "ttyl", "thx", "ty", "later"]
    static let punctuation = CharacterSet(charactersIn: ".,;:!?—–-()\"'…")

    public static func observe(_ text: String) -> StyleObservation {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
        let sentences = splitSentences(trimmed)
        let capitalized = sentences.filter { s in
            guard let first = s.unicodeScalars.first(where: { CharacterSet.letters.contains($0) }) else { return false }
            return CharacterSet.uppercaseLetters.contains(first)
        }
        let punctCount = trimmed.unicodeScalars.filter { punctuation.contains($0) }.count
        let lastScalar = trimmed.unicodeScalars.last
        let hasTerminalPeriod = lastScalar == "." && !trimmed.hasSuffix("...") && !trimmed.hasSuffix("…")
        let hasEmoji = trimmed.unicodeScalars.contains { $0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x238C) }
        return StyleObservation(
            capitalizedSentenceRate: sentences.isEmpty ? 0 : Double(capitalized.count) / Double(sentences.count),
            hasTerminalPeriod: hasTerminalPeriod,
            punctuationDensity: words.isEmpty ? 0 : Double(punctCount) / Double(words.count),
            hasEmoji: hasEmoji,
            greeting: detectGreeting(words),
            signOff: detectSignOff(lines: trimmed.split(separator: "\n").map(String.init), words: words),
            avgSentenceLength: sentences.isEmpty ? 0 : Double(words.count) / Double(sentences.count),
            wordCount: words.count
        )
    }

    static func splitSentences(_ text: String) -> [String] {
        var out: [String] = [], current = ""
        for ch in text {
            current.append(ch)
            if ch == "." || ch == "!" || ch == "?" || ch == "\n" {
                let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { out.append(t) }
                current = ""
            }
        }
        let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { out.append(t) }
        return out
    }

    static func clean(_ w: String) -> String {
        w.lowercased().trimmingCharacters(in: punctuation)
    }

    static func detectGreeting(_ words: [String]) -> String? {
        guard let first = words.first, greetings.contains(clean(first)) else { return nil }
        return first.trimmingCharacters(in: punctuation)
    }

    static func detectSignOff(lines: [String], words: [String]) -> String? {
        // Prefer the last non-empty line ("Thanks,\nAditya" → check last two lines).
        let tail = lines.count > 1 ? lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.suffix(2) : []
        for line in tail.reversed() {
            let key = clean(line)
            if signOffs.contains(key) { return line.trimmingCharacters(in: punctuation) }
        }
        // Single-line messages: trailing "… thanks" / "… cheers".
        if let last = words.last, signOffs.contains(clean(last)), words.count > 2 {
            return last.trimmingCharacters(in: punctuation)
        }
        return nil
    }
}
