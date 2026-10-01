import Foundation

// V5 D2 — when Automatic runs the model at all. The rules (formatters, ITN, style) handle most
// dictation; the model is worth its latency only where a rule cannot decide: the speaker corrected
// themselves, dictated a list, said a number/date/address, or spoke long enough for slips to pile up.

public struct CleanupCues: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let selfCorrection = CleanupCues(rawValue: 1 << 0)
    public static let listMarker = CleanupCues(rawValue: 1 << 1)
    public static let numberDateEmail = CleanupCues(rawValue: 1 << 2)
    public static let long = CleanupCues(rawValue: 1 << 3)

    /// Short names for the log line (never the text).
    public var names: [String] {
        var out: [String] = []
        if contains(.selfCorrection) { out.append("selfCorrection") }
        if contains(.listMarker) { out.append("list") }
        if contains(.numberDateEmail) { out.append("numberDateEmail") }
        if contains(.long) { out.append("long") }
        return out
    }
}

public enum CleanupCueDetector {
    /// "> 12 words" (D2).
    public static let longWordCount = 12

    public static func cues(in text: String) -> CleanupCues {
        let lower = " " + text.lowercased() + " "
        var cues: CleanupCues = []
        if matches(selfCorrection, lower) { cues.insert(.selfCorrection) }
        if matches(listMarker, lower) { cues.insert(.listMarker) }
        if matches(numberDateEmail, lower) { cues.insert(.numberDateEmail) }
        if text.split(whereSeparator: \.isWhitespace).count > longWordCount { cues.insert(.long) }
        return cues
    }

    private static func matches(_ regex: NSRegularExpression, _ s: String) -> Bool {
        regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    private static func re(_ pattern: String) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: [])
    }

    /// Retractions and edit commands: "Thursday, no, Friday", "I mean", "scratch that", "make that".
    static let selfCorrection = re(#"""
    (?x)
    ,\s*no\s*,                                   # "Thursday, no, Friday"
    | \bno\b[,]?\s+(?:wait|sorry|i\s+mean|make\s+that|actually)\b
    | \b(?:wait|sorry)[,]?\s+(?:no|i\s+mean|make\s+that|actually)\b
    | \bi\s+mean\b
    | \bor\s+rather\b
    | \bscratch\s+that\b | \bstrike\s+that\b | \bdelete\s+that\b | \bforget\s+that\b
    | \bmake\s+that\b
    | \blet\s+me\s+rephrase\b
    | \bcorrect(?:ion)?\b[:,]?\s+\S+\s+to\b       # "correct Tuesday to Wednesday"
    | \bchange\s+that\s+to\b
    | \bactually[,]?\s+(?:no|make|it'?s|its)\b
    """#)

    /// Dictated structure: ordinals used as markers, "bullet", "number one", "new line/paragraph".
    static let listMarker = re(#"""
    (?x)
    \b(?:firstly|secondly|thirdly)\b
    | \bfirst[,]?\s.+\bsecond\b
    | \b(?:bullet|bullet\s+point|point|number|item|step)\s+(?:one|two|three|four|five|1|2|3|4|5)\b
    | \bnext\s+(?:item|bullet|point)\b
    | \bnew\s+(?:line|paragraph|bullet)\b
    | (?:^|\s)[1-9][.)]\s
    """#)

    /// Numbers, dates, times, money, emails and URLs said aloud.
    static let numberDateEmail = re(#"""
    (?x)
    \d
    | \b(?:eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen
        |twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|thousand|million|billion)\b
    | \b(?:percent|dollars?|euros?|pounds|rupees|o'?clock|a\.?m\.?|p\.?m\.?)\s
    | \b(?:january|february|march|april|june|july|august|september|october|november|december)\b
    | \b(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday|tomorrow|tonight)\b
    | \s(?:at|@)\s\S+\s(?:dot|\.)\s(?:com|org|net|io|in|co|dev|edu)\b
    | \bdot\s(?:com|org|net|io|dev)\b
    | @
    """#)
}
