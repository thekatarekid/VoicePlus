import Foundation

/// V5 V1 — the Open ASR Leaderboard text normaliser: a Swift port of the rules in OpenAI Whisper's
/// `EnglishTextNormalizer` (MIT, `whisper/normalizers/english.py`), which the leaderboard uses for
/// every English WER it publishes. Same order of operations: lowercase → drop bracketed /
/// parenthesised spans → drop fillers → expand contractions and titles → strip symbols and
/// diacritics (keeping numeric symbols) → spoken numbers to digits → British→American spelling →
/// drop stray numeric symbols. Rules are ported, not the exact Python; the number normaliser covers
/// cardinals, ordinals, year-style pairs ("nineteen eighty four" → 1984), digit runs, decimals,
/// plurals, currency and percent — what appears in the public sets we score.
///
/// `raw` mode (LibriSpeech-PC punctuation + casing scoring) keeps case and splits `.,?!;:` into
/// their own tokens so punctuation errors count as word errors.
public enum OpenASRNormalizer {
    public enum Mode: String, Sendable, Codable { case normalized, raw }

    public static func normalize(_ text: String, mode: Mode = .normalized) -> String {
        mode == .raw ? raw(text) : english(text)
    }

    public static func words(_ text: String, mode: Mode = .normalized) -> [String] {
        normalize(text, mode: mode).split(separator: " ").map(String.init)
    }

    // MARK: raw (punctuation + casing)

    static func raw(_ text: String) -> String {
        var s = text.precomposedStringWithCanonicalMapping
        s = sub(#"([.,?!;:])"#, " $1 ", s)
        return collapse(s)
    }

    // MARK: english (Whisper rules)

    static func english(_ text: String) -> String {
        var s = text.lowercased()
        s = sub(#"[<\[][^>\]]*[>\]]"#, "", s)            // words between brackets
        s = sub(#"\(([^)]+?)\)"#, "", s)                  // words between parentheses
        s = sub(#"\b(hmm|mm|mhm|mmm|uh|um)\b"#, "", s)    // fillers
        s = sub(#"\s+'"#, "'", s)                         // space before an apostrophe
        s = s.replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "\u{2018}", with: "'")
        for (pattern, replacement) in replacers { s = sub(pattern, replacement, s) }
        s = sub(#"(\d),(\d)"#, "$1$2", s)                 // commas between digits
        s = sub(#"\.([^0-9]|$)"#, " $1", s)               // periods not followed by numbers
        s = removeSymbolsAndDiacritics(s, keep: ".%$¢€£")
        s = NumberNormalizer.normalize(s)
        s = standardizeSpellings(s)
        s = sub(#"[.$¢€£]([^0-9])"#, " $1", s)            // prefix symbols not followed by a number
        s = sub(#"[.$¢€£]$"#, " ", s)
        s = sub(#"([^0-9])%"#, "$1 ", s)                  // suffix symbols not preceded by a number
        return collapse(s)
    }

    /// Whisper's `EnglishTextNormalizer.replacers`, in order.
    static let replacers: [(String, String)] = [
        (#"\bwon't\b"#, "will not"), (#"\bcan't\b"#, "can not"), (#"\blet's\b"#, "let us"), (#"\bain't\b"#, "aint"),
        (#"\by'all\b"#, "you all"), (#"\bwanna\b"#, "want to"), (#"\bgotta\b"#, "got to"), (#"\bgonna\b"#, "going to"),
        (#"\bi'ma\b"#, "i am going to"), (#"\bimma\b"#, "i am going to"), (#"\bwoulda\b"#, "would have"),
        (#"\bcoulda\b"#, "could have"), (#"\bshoulda\b"#, "should have"), (#"\bma'am\b"#, "madam"),
        (#"\bmr\b"#, "mister "), (#"\bmrs\b"#, "missus "), (#"\bst\b"#, "saint "), (#"\bdr\b"#, "doctor "),
        (#"\bprof\b"#, "professor "), (#"\bcapt\b"#, "captain "), (#"\bgov\b"#, "governor "), (#"\bald\b"#, "alderman "),
        (#"\bgen\b"#, "general "), (#"\bsen\b"#, "senator "), (#"\brep\b"#, "representative "), (#"\bpres\b"#, "president "),
        (#"\brev\b"#, "reverend "), (#"\bhon\b"#, "honorable "), (#"\basst\b"#, "assistant "), (#"\bassoc\b"#, "associate "),
        (#"\blt\b"#, "lieutenant "), (#"\bcol\b"#, "colonel "), (#"\bjr\b"#, "junior "), (#"\bsr\b"#, "senior "),
        (#"\besq\b"#, "esquire "),
        (#"'d been\b"#, " had been"), (#"'s been\b"#, " has been"), (#"'d gone\b"#, " had gone"), (#"'s gone\b"#, " has gone"),
        (#"'d done\b"#, " had done"), (#"'s got\b"#, " has got"),
        (#"n't\b"#, " not"), (#"'re\b"#, " are"), (#"'s\b"#, " is"), (#"'d\b"#, " would"), (#"'ll\b"#, " will"),
        (#"'t\b"#, " not"), (#"'ve\b"#, " have"), (#"'m\b"#, " am"),
    ]

    /// Whisper's ADDITIONAL_DIACRITICS — letters NFKD does not decompose.
    static let extraDiacritics: [Character: String] = [
        "œ": "oe", "Œ": "OE", "ø": "o", "Ø": "O", "æ": "ae", "Æ": "AE", "ß": "ss", "ẞ": "SS", "đ": "d", "Đ": "D",
        "ð": "d", "Ð": "D", "þ": "th", "Þ": "th", "ł": "l", "Ł": "L",
    ]

    /// NFKD, drop combining marks, map the extra diacritics, replace every other symbol / punctuation
    /// with a space (characters in `keep` survive).
    static func removeSymbolsAndDiacritics(_ s: String, keep: String) -> String {
        var out = ""
        for ch in s.decomposedStringWithCompatibilityMapping {
            if keep.contains(ch) { out.append(ch); continue }
            if let mapped = extraDiacritics[ch] { out += mapped; continue }
            guard let scalar = ch.unicodeScalars.first else { continue }
            switch scalar.properties.generalCategory {
            case .nonspacingMark: continue
            case .spacingMark, .enclosingMark,
                 .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol,
                 .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
                 .initialPunctuation, .finalPunctuation, .otherPunctuation:
                out.append(" ")
            default:
                // A base character followed by combining marks arrives as one Character: keep the base.
                if ch.unicodeScalars.count > 1 {
                    out += String(String.UnicodeScalarView(ch.unicodeScalars.filter { $0.properties.generalCategory != .nonspacingMark }))
                } else {
                    out.append(ch)
                }
            }
        }
        return out
    }

    static func standardizeSpellings(_ s: String) -> String {
        s.split(separator: " ", omittingEmptySubsequences: false)
            .map { BritishSpellings.map[String($0)] ?? String($0) }
            .joined(separator: " ")
    }

    // MARK: helpers

    static func collapse(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    nonisolated(unsafe) private static var regexCache: [String: NSRegularExpression] = [:]
    private static let cacheLock = NSLock()

    static func sub(_ pattern: String, _ template: String, _ s: String) -> String {
        cacheLock.lock()
        let re: NSRegularExpression
        if let cached = regexCache[pattern] {
            re = cached
        } else {
            re = try! NSRegularExpression(pattern: pattern)
            regexCache[pattern] = re
        }
        cacheLock.unlock()
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }
}

/// Spoken numbers → digits (port of the rules in Whisper's `EnglishNumberNormalizer`).
enum NumberNormalizer {
    static let ones: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    static let multipliers: [String: Int] = [
        "hundred": 100, "thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000,
    ]
    static let onesOrdinal: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8,
        "ninth": 9, "tenth": 10, "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14, "fifteenth": 15,
        "sixteenth": 16, "seventeenth": 17, "eighteenth": 18, "nineteenth": 19,
    ]
    static let tensOrdinal: [String: Int] = [
        "twentieth": 20, "thirtieth": 30, "fortieth": 40, "fiftieth": 50, "sixtieth": 60, "seventieth": 70,
        "eightieth": 80, "ninetieth": 90,
    ]
    static let multiplierOrdinal: [String: Int] = ["hundredth": 100, "thousandth": 1_000, "millionth": 1_000_000]
    static let onesPlural: [String: Int] = [
        "ones": 1, "twos": 2, "threes": 3, "fours": 4, "fives": 5, "sixes": 6, "sevens": 7, "eights": 8, "nines": 9,
        "tens": 10, "elevens": 11, "twelves": 12, "thirteens": 13, "fourteens": 14, "fifteens": 15, "sixteens": 16,
        "seventeens": 17, "eighteens": 18, "nineteens": 19,
    ]
    static let tensPlural: [String: Int] = [
        "twenties": 20, "thirties": 30, "forties": 40, "fifties": 50, "sixties": 60, "seventies": 70, "eighties": 80,
        "nineties": 90,
    ]
    static let suffixCurrency: [String: String] = [
        "dollar": "$", "dollars": "$", "pound": "£", "pounds": "£", "euro": "€", "euros": "€", "cent": "¢", "cents": "¢",
    ]

    static func ordinalSuffix(_ n: Int) -> String {
        if (11...13).contains(n % 100) { return "th" }
        switch n % 10 { case 1: return "st"; case 2: return "nd"; case 3: return "rd"; default: return "th" }
    }

    /// A number under construction: an integer (composed arithmetically) or a digit string
    /// (composed by concatenation: "nine one one" → "911", "nineteen eighty" → "1980").
    enum Value { case int(Int), digits(String)
        var text: String { switch self { case .int(let i): return String(i); case .digits(let d): return d } }
        var intValue: Int { switch self { case .int(let i): return i; case .digits(let d): return Int(d) ?? 0 } }
    }

    static func normalize(_ s: String) -> String {
        let words = s.split(separator: " ").map(String.init)
        var out: [String] = []
        var big = 0                 // accumulated thousands/millions
        var value: Value?           // current sub-thousand part
        var prev: String?
        var decimal: String?        // digits after "point"
        var inNumber: Bool { value != nil || big > 0 }

        func flush(suffix: String = "") {
            guard inNumber else { return }
            var text: String
            if big > 0 { text = String(big + (value?.intValue ?? 0)) } else { text = value!.text }
            if let d = decimal { text += "." + d }
            out.append(text + suffix)
            big = 0; value = nil; decimal = nil
        }

        var i = 0
        while i < words.count {
            let w = words[i]
            let next = i + 1 < words.count ? words[i + 1] : nil
            defer { prev = w; i += 1 }

            if decimal != nil {
                if let o = ones[w], o < 10 { decimal! += String(o); continue }
                if suffixCurrency[w] == nil, w != "percent" { flush() }
            }
            if let o = ones[w] {
                switch value {
                case nil: value = .int(o)
                case .digits(let d)?:
                    if let p = prev, tens[p] != nil, o < 10 { value = .digits(String(d.dropLast()) + String(o)) }
                    else { value = .digits(d + String(o)) }
                case .int(let v)?:
                    if let p = prev, tens[p] != nil, o < 10 { value = .int(v + o) }
                    else if let p = prev, multipliers[p] != nil || p == "and" { value = .int(v + o) }
                    else { value = .digits(String(v) + String(o)) }
                }
                continue
            }
            if let t = tens[w] {
                switch value {
                case nil: value = .int(t)
                case .digits(let d)?: value = .digits(d + String(t))
                case .int(let v)?:
                    if v % 100 == 0 || prev.map({ multipliers[$0] != nil || $0 == "and" }) == true { value = .int(v + t) }
                    else { value = .digits(String(v) + String(t)) }
                }
                continue
            }
            if let m = multipliers[w], inNumber || ["a", "one"].contains(prev ?? "") {
                let v = value?.intValue ?? 1
                if m == 100 {
                    value = .int(v * 100)
                } else {
                    big += v * m; value = nil
                }
                continue
            }
            if w == "and", inNumber, let n = next, ones[n] != nil || tens[n] != nil,
               let p = prev, multipliers[p] != nil { continue }
            if w == "point", inNumber, let n = next, ones[n].map({ $0 < 10 }) == true {
                decimal = ""; continue
            }
            if let o = onesOrdinal[w] ?? tensOrdinal[w] {
                let total: Int
                switch value {
                case nil: total = big + o
                case .digits(let d)?: out.append(d.dropLast().description + String(o) + ordinalSuffix(o)); big = 0; value = nil; continue
                case .int(let v)?: total = big + v + o
                }
                big = 0; value = nil
                out.append(String(total) + ordinalSuffix(total)); continue
            }
            if let m = multiplierOrdinal[w], inNumber {
                let total = big + (value?.intValue ?? 1) * m
                big = 0; value = nil
                out.append(String(total) + "th"); continue
            }
            if let o = onesPlural[w] ?? tensPlural[w] {
                if case .int(let v)? = value { value = nil; out.append(String(big + v + o) + "s"); big = 0 }
                else { flush(); out.append(String(o) + "s") }
                continue
            }
            if inNumber, let sym = suffixCurrency[w] {
                var text = big > 0 ? String(big + (value?.intValue ?? 0)) : value!.text
                if let d = decimal { text += "." + d }
                big = 0; value = nil; decimal = nil
                out.append(sym == "¢" ? text + "¢" : sym + text); continue
            }
            if inNumber, w == "percent" { flush(suffix: "%"); continue }
            // An "a" / "one" that may start "a hundred": defer only when a multiplier follows.
            if w == "a", let n = next, multipliers[n] != nil { continue }
            flush()
            if Double(w) != nil, let n = next {           // "3.5 percent" → 3.5%, "20 dollars" → $20
                if n == "percent" { out.append(w + "%"); i += 1; continue }
                if let sym = suffixCurrency[n] { out.append(sym == "¢" ? w + "¢" : sym + w); i += 1; continue }
            }
            out.append(w)
        }
        flush()
        return out.joined(separator: " ")
    }
}
