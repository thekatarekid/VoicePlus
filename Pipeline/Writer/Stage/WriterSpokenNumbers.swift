import Foundation

/// Spoken-number reading for the per-change guard: "twenty five" ⇄ "25", "four B" ⇄ "4B",
/// "fifty dollars" ⇄ "$50", "third" ⇄ "3rd", "five thirty" ⇄ "5:30", "three point five" ⇄ "3.5".
/// A number the model wrote is formatting, never content, when the heard words read as that
/// number — so it is allowed even on confident words. Deliberately small: anything this does not
/// read falls through to the word-level rules (and reverts when it is a real change).
enum WriterSpokenNumbers {
    static let units: [String: Int] = [
        "zero": 0, "oh": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    static let scales: [String: Int] = ["hundred": 100, "thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000]
    /// Ordinal word → (cardinal word, suffix).
    static let ordinals: [String: (String, String)] = [
        "first": ("one", "st"), "second": ("two", "nd"), "third": ("three", "rd"), "fourth": ("four", "th"),
        "fifth": ("five", "th"), "sixth": ("six", "th"), "seventh": ("seven", "th"), "eighth": ("eight", "th"),
        "ninth": ("nine", "th"), "tenth": ("ten", "th"), "eleventh": ("eleven", "th"), "twelfth": ("twelve", "th"),
        "thirteenth": ("thirteen", "th"), "fourteenth": ("fourteen", "th"), "fifteenth": ("fifteen", "th"),
        "sixteenth": ("sixteen", "th"), "seventeenth": ("seventeen", "th"), "eighteenth": ("eighteen", "th"),
        "nineteenth": ("nineteen", "th"), "twentieth": ("twenty", "th"), "thirtieth": ("thirty", "th"),
        "fortieth": ("forty", "th"), "fiftieth": ("fifty", "th"), "sixtieth": ("sixty", "th"),
        "seventieth": ("seventy", "th"), "eightieth": ("eighty", "th"), "ninetieth": ("ninety", "th"),
        "hundredth": ("hundred", "th"), "thousandth": ("thousand", "th"),
    ]
    /// Unit words → the symbol the model may write.
    static let unitSymbols: [String: String] = [
        "dollar": "$", "dollars": "$", "bucks": "$", "percent": "%", "euro": "€", "euros": "€",
        "pound": "£", "pounds": "£", "rupee": "₹", "rupees": "₹",
    ]

    static func isNumberWord(_ key: String) -> Bool {
        units[key] != nil || tens[key] != nil || scales[key] != nil || ordinals[key] != nil
            || key == "point" || key == "and" || key == "a"
    }

    /// The written forms a run of heard words can take as a number, e.g. ["twenty", "five"] →
    /// ["25"]; ["four", "one", "five"] → ["415", "410"]; ["third"] → ["3rd"]; ["five", "thirty"] →
    /// ["35", "5:30"]; ["fifty", "dollars"] → ["$50"] (a unit word is consumed only into its symbol;
    /// "50 dollars" is the shorter run ["fifty"] plus the word itself).
    static func readings(_ keys: [String]) -> [String] {
        guard !keys.isEmpty else { return [] }
        var words = keys
        var unit = ""
        if let last = words.last, let symbol = unitSymbols[last] { unit = symbol; words.removeLast() }
        guard !words.isEmpty else { return [] }
        var suffix = ""
        if let last = words.last, let (cardinal, s) = ordinals[last] { words[words.count - 1] = cardinal; suffix = s }
        // Only "a hundred" / "a thousand" reads "a" as one; a leading article elsewhere is a word.
        if words.first == "a" { guard words.count >= 2, scales[words[1]] != nil else { return [] }; words[0] = "one" }
        guard words.allSatisfy({ units[$0] != nil || tens[$0] != nil || scales[$0] != nil || $0 == "point" || $0 == "and" }) else { return [] }
        var out: [String] = []
        if let p = words.firstIndex(of: "point"), suffix.isEmpty {
            let whole = Array(words[..<p]), frac = Array(words[(p + 1)...])
            guard !frac.isEmpty, frac.allSatisfy({ (units[$0] ?? 10) < 10 }), let w = composite(whole) else { return [] }
            out.append("\(w)." + frac.map { String(units[$0]!) }.joined())
        } else {
            if let value = composite(words) { out.append("\(value)\(suffix)") }
            if words.count >= 2, words.allSatisfy({ (units[$0] ?? 10) < 10 }), suffix.isEmpty {
                out.append(words.map { String(units[$0]!) }.joined())
            }
            // Clock reading: "five thirty" → 5:30, "nine oh five" → 9:05.
            if words.count >= 2, suffix.isEmpty, let h = units[words[0]], h <= 24, h > 0,
               let m = composite(Array(words[1...])), m < 60, !words[1...].contains(where: { scales[$0] != nil }) {
                out.append(String(format: "%d:%02d", h, m))
            }
        }
        guard !unit.isEmpty else { return out }
        return out.map { unit == "%" ? $0 + "%" : unit + $0 }
    }

    /// "twenty five" → 25, "two hundred and three" → 203, "one thousand two hundred" → 1200.
    static func composite(_ words: [String]) -> Int? {
        guard !words.isEmpty else { return nil }
        var total = 0, current = 0, sawDigit = false
        for w in words {
            if w == "and" { continue }
            if let u = units[w] { current += u; sawDigit = true }
            else if let t = tens[w] { current += t; sawDigit = true }
            else if let s = scales[w] {
                guard sawDigit else { return nil }
                if s >= 1000 { total += current * s; current = 0 } else { current *= s }
            } else { return nil }
        }
        return sawDigit ? total + current : nil
    }

    /// The written token stripped to what `readings` produces: "25,000" → ("25000", ""),
    /// "$50." → ("$50", ""), "4B" → ("4", "b"), "10%" → ("10%", ""). Nil when it holds no digit.
    static func writtenNumber(_ token: String) -> (number: String, suffix: String)? {
        var s = token.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols).subtracting(CharacterSet(charactersIn: "$€£₹%")))
        guard s.contains(where: \.isNumber) else { return nil }
        var prefix = ""
        if let f = s.first, "$€£₹".contains(f) { prefix = String(f); s.removeFirst() }
        var number = "", suffix = ""
        var i = s.startIndex
        while i < s.endIndex, s[i].isNumber || s[i] == ":" || s[i] == "." || s[i] == "," {
            if s[i] != "," { number.append(s[i]) }
            i = s.index(after: i)
        }
        suffix = String(s[i...]).lowercased()
        if suffix == "%" { number += "%"; suffix = "" }
        if suffix.hasPrefix("%") { number += "%"; suffix.removeFirst() }
        while let l = number.last, l == "." || l == ":" { number.removeLast() }   // "25." at a sentence end
        guard !number.isEmpty else { return nil }
        return (prefix + number, suffix)
    }
}
