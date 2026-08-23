import Foundation

/// Word lists used by `EmailFormatter`. Named after the formatter to avoid collisions
/// with sibling formatter agents' Common helpers.
enum EmailWordLists {
    /// Single-token disfluencies removed outright.
    static let fillers: Set<String> = [
        "um", "umm", "uh", "uhm", "uhh", "er", "erm", "ah", "hmm", "hm", "mm", "mhm", "huh",
    ]

    /// Words that, when following a bare "no", mean it is not a self-correction marker.
    static let noFalsePositives: Set<String> = [
        "thanks", "thank", "way", "problem", "worries", "one", "longer", "more", "idea", "matter",
        "need", "doubt", "rush", "pressure", "later", "big", "deal", "but", "and", "not", "we", "i", "you",
    ]

    /// Greeting phrases (lowercase, tokenised).
    static let greetings: [[String]] = [
        ["good", "morning"], ["good", "afternoon"], ["good", "evening"], ["hi", "there"], ["hey", "there"],
        ["hello", "there"], ["hi"], ["hello"], ["hey"], ["dear"],
    ]

    /// Words after a greeting that are not a name (so the greeting has no addressee).
    static let greetingStoppers: Set<String> = [
        "i", "i'm", "i've", "i'd", "i'll", "just", "thanks", "thank", "hope", "we", "we're", "please",
        "this", "the", "can", "could", "are", "do", "it", "it's", "here", "following", "quick", "let",
        "sorry", "as", "wanted", "a", "my", "our", "your", "so", "in", "on", "per", "re", "regarding",
        "good", "great", "how", "what", "when", "is", "there", "did", "have", "has", "sounds", "not",
    ]

    /// Addressee words that stay lowercase in a greeting ("Hi all,").
    static let lowercaseAddressees: Set<String> = ["all", "everyone", "both", "there", "folks", "guys"]

    /// Sign-off phrases (lowercase, tokenised), longest first.
    static let signOffs: [[String]] = [
        ["thanks", "so", "much"], ["thank", "you", "so", "much"], ["thanks", "very", "much"],
        ["thank", "you", "very", "much"], ["all", "the", "best"], ["best", "regards"], ["kind", "regards"],
        ["warm", "regards"], ["thanks", "again"], ["thank", "you", "again"], ["many", "thanks"],
        ["talk", "soon"], ["take", "care"], ["thank", "you"], ["thanks"], ["cheers"], ["regards"],
        ["sincerely"], ["best"], ["yours"],
    ]

    /// Single-word sign-offs that are too common mid-sentence to accept without extra evidence.
    static let ambiguousSignOffs: Set<String> = ["best", "cheers", "regards", "yours"]

    /// Tokens that cannot be a sign-off name.
    static let notNames: Set<String> = [
        "a", "an", "for", "so", "you", "the", "to", "in", "lot", "much", "and", "it", "that", "this",
        "me", "us", "him", "her", "them", "again", "very", "of", "on", "at", "by", "guys",
    ]

    /// Words before "period" that make it a noun, not a punctuation command.
    static let periodNounCues: Set<String> = ["a", "the", "this", "that", "grace", "trial", "time", "long", "short", "same"]

    /// Ordinal list markers → number (0 = "next").
    static let ordinals: [String: Int] = [
        "first": 1, "firstly": 1, "second": 2, "secondly": 2, "third": 3, "thirdly": 3,
        "fourth": 4, "fourthly": 4, "fifth": 5, "finally": 0, "lastly": 0,
    ]

    /// Function words that end a replacement phrase in a self-correction ("thursday at noon").
    static let functionWords: Set<String> = [
        "at", "on", "in", "to", "for", "by", "with", "from", "and", "or", "of", "the", "a", "an", "is", "are",
        "was", "were", "that", "this", "it", "we", "i", "you", "next", "before", "after", "until", "please",
        "so", "but", "then", "if", "not", "instead",
    ]

    /// Always capitalised (days, months).
    static let properNouns: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "june", "july", "august", "september", "october", "november", "december",
    ]

    static let numberWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
    ]
}
