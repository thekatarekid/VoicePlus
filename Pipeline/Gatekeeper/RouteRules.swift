import Foundation
import Shared

/// Deterministic keyword/grammar rules. A hit is high-confidence; no hit means "ask Bayes".
enum RouteRules {
    struct Hit { let route: Utterance.Route; let confidence: Float; let reason: String }

    static let fillers: Set<String> = ["um", "uh", "hmm", "mm", "er", "ah", "uhm", "like", "okay", "ok", "so", "well"]

    static func evaluate(_ words: [String]) -> Hit? {
        guard !words.isEmpty else { return Hit(route: .none, confidence: 1, reason: "empty") }
        if words.allSatisfy({ fillers.contains($0) }) { return Hit(route: .none, confidence: 0.95, reason: "fillers-only") }

        let joined = words.joined(separator: " ")
        let first = words[0]
        let long = words.count > 8

        // Dictation-formatting commands are typed-through by formatters, not routed.
        if ["new paragraph", "new line", "full stop", "comma", "period", "question mark"].contains(joined) {
            return Hit(route: .dictate, confidence: 0.95, reason: "inline-format-command")
        }

        // Repair: short utterances opening with a negation/correction cue (Bet 3).
        if !long {
            if (first == "no" || first == "nope") && words.count <= 6 {
                return Hit(route: .repairCommand, confidence: 0.9, reason: "leading-no")
            }
            if joined.hasPrefix("not that") || joined.hasPrefix("not the ") || joined == "not that one" {
                return Hit(route: .repairCommand, confidence: 0.9, reason: "not-that")
            }
            if joined.hasPrefix("i said ") || joined.hasPrefix("i meant ") || joined.hasPrefix("it's spelled") || joined.hasPrefix("spell it") {
                return Hit(route: .repairCommand, confidence: 0.92, reason: "i-said")
            }
            for phrase in ["scratch that", "undo", "redo", "put it back", "go back", "strike that", "erase that",
                           "remove that", "delete that", "delete the last", "delete last", "never mind", "nevermind",
                           "fix the last", "capital", "lowercase", "uppercase", "the first one", "the second one", "the third one",
                           "the first option", "the second option", "that's wrong", "that is wrong", "wrong"] {
                if joined == phrase || joined.hasPrefix(phrase + " ") || (phrase.count > 5 && joined.contains(phrase)) {
                    return Hit(route: .repairCommand, confidence: 0.9, reason: "repair-phrase:\(phrase)")
                }
            }
            if (first == "replace" || first == "change" || first == "swap") && (words.contains("with") || words.contains("to")) {
                return Hit(route: .repairCommand, confidence: 0.88, reason: "replace-x-with-y")
            }
        }

        // Transform: imperative over "this/it/that" with an edit verb, or an edit verb up front.
        let transformVerbs: Set<String> = ["rewrite", "summarize", "summarise", "translate", "shorten", "simplify",
                                           "expand", "paraphrase", "proofread", "condense", "reword", "bulletize", "tighten", "formalize"]
        if transformVerbs.contains(first) && words.count <= 8 {
            return Hit(route: .transform, confidence: 0.9, reason: "transform-verb")
        }
        let pronouns: Set<String> = ["this", "it", "that", "these", "those"]
        if words.count >= 2, words.count <= 9, ["make", "turn", "convert", "clean", "fix", "tighten", "flip", "reply", "respond", "add"].contains(first) {
            let object = words[1]
            if pronouns.contains(object) || (words.count >= 3 && pronouns.contains(words[2])) || first == "fix" && words.contains("grammar") {
                if first == "make" && (object == "sure" || object == "a" || object == "an") { return nil }
                return Hit(route: .transform, confidence: 0.88, reason: "edit-verb-pronoun")
            }
        }

        // Question about the current text.
        if !long, ["what", "who", "is", "does", "how", "why", "when", "where", "which", "can"].contains(first),
           words.contains("this") || words.contains("that") || words.contains("it") {
            let aboutText = words.contains("say") || words.contains("mean") || words.contains("about") || words.contains("correct")
                || words.contains("sent") || words.contains("sound") || words.contains("error") || words.contains("deadline")
            if aboutText { return Hit(route: .question, confidence: 0.8, reason: "question-about-text") }
        }
        return nil
    }
}
