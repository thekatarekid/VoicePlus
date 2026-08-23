import Foundation

/// Double Metaphone (Lawrence Philips, 2000) in Swift. Produces a primary and an optional
/// secondary phonetic code so that "Kothari" / "Cotari" / "Kuthary" collide — the basis for
/// the phonetic-neighbour alternates of T2. Codes are capped at `maxLength` (4 by default,
/// matching the reference; use a larger cap for long names).
///
/// This is an independent implementation of the published algorithm (no GPL code copied).
public struct DoubleMetaphone: Sendable {
    public struct Codes: Equatable, Hashable, Sendable {
        public var primary: String
        public var secondary: String?
        public init(primary: String, secondary: String?) {
            self.primary = primary
            self.secondary = (secondary == nil || secondary == primary) ? nil : secondary
        }
        public func matches(_ other: Codes) -> Bool {
            let a = [primary, secondary].compactMap { $0 }
            let b = [other.primary, other.secondary].compactMap { $0 }
            return a.contains { b.contains($0) }
        }
    }

    public var maxLength: Int
    public init(maxLength: Int = 4) { self.maxLength = maxLength }

    public static func encode(_ word: String, maxLength: Int = 4) -> Codes {
        DoubleMetaphone(maxLength: maxLength).encode(word)
    }

    // MARK: - Encoder

    public func encode(_ input: String) -> Codes {
        let s = Array(input.uppercased().folding(options: .diacriticInsensitive, locale: nil)
            .unicodeScalars.filter { CharacterSet.letters.contains($0) }.map { Character($0) })
        var st = State(w: s, maxLength: maxLength)
        st.run()
        return Codes(primary: st.primary, secondary: st.secondary)
    }

    private struct State {
        let w: [Character]
        let maxLength: Int
        var primary = ""
        var secondary = ""
        var cur = 0
        var last: Int { w.count - 1 }
        let vowels: Set<Character> = ["A", "E", "I", "O", "U", "Y"]
        let slavoGermanic: Bool

        init(w: [Character], maxLength: Int) {
            self.w = w
            self.maxLength = maxLength
            let str = String(w)
            slavoGermanic = str.contains("W") || str.contains("K") || str.contains("CZ") || str.contains("WITZ")
        }

        func at(_ i: Int) -> Character { (i >= 0 && i < w.count) ? w[i] : "\0" }
        func isVowel(_ i: Int) -> Bool { vowels.contains(at(i)) }
        func string(_ start: Int, _ length: Int, _ list: [String]) -> Bool {
            guard start >= 0, length > 0, start + length <= w.count else { return false }
            let sub = String(w[start..<(start + length)])
            return list.contains(sub)
        }
        mutating func add(_ p: String, _ s: String? = nil) {
            primary += p
            secondary += s ?? p
        }
        var done: Bool { primary.count >= maxLength && secondary.count >= maxLength }

        mutating func run() {
            guard !w.isEmpty else { return }
            // Skip silent letters at start.
            if string(0, 2, ["GN", "KN", "PN", "WR", "PS"]) { cur += 1 }
            if at(0) == "X" { add("S"); cur += 1 }

            while !done, cur < w.count {
                let c = at(cur)
                switch c {
                case "A", "E", "I", "O", "U", "Y":
                    if cur == 0 { add("A") }
                    cur += 1
                case "B":
                    add("P"); cur += at(cur + 1) == "B" ? 2 : 1
                case "C": handleC()
                case "D":
                    if string(cur, 2, ["DG"]) {
                        if string(cur + 2, 1, ["I", "E", "Y"]) { add("J"); cur += 3 }
                        else { add("TK"); cur += 2 }
                    } else if string(cur, 2, ["DT", "DD"]) { add("T"); cur += 2 }
                    else { add("T"); cur += 1 }
                case "F":
                    add("F"); cur += at(cur + 1) == "F" ? 2 : 1
                case "G": handleG()
                case "H":
                    if (cur == 0 || isVowel(cur - 1)) && isVowel(cur + 1) { add("H"); cur += 2 }
                    else { cur += 1 }
                case "J":
                    if string(cur, 4, ["JOSE"]) || string(0, 4, ["SAN "]) {
                        if (cur == 0 && at(cur + 4) == " ") || string(0, 4, ["SAN "]) { add("H") } else { add("J", "H") }
                        cur += 1
                    } else {
                        if cur == 0 && !string(cur, 4, ["JOSE"]) { add("J", "A") }
                        else if isVowel(cur - 1) && !slavoGermanic && (at(cur + 1) == "A" || at(cur + 1) == "O") { add("J", "H") }
                        else if cur == last { add("J", "") }
                        else if !string(cur + 1, 1, ["L", "T", "K", "S", "N", "M", "B", "Z"]) && !string(cur - 1, 1, ["S", "K", "L"]) { add("J") }
                        cur += at(cur + 1) == "J" ? 2 : 1
                    }
                case "K":
                    add("K"); cur += at(cur + 1) == "K" ? 2 : 1
                case "L":
                    if at(cur + 1) == "L" {
                        if (cur == w.count - 3 && string(cur - 1, 4, ["ILLO", "ILLA", "ALLE"]))
                            || ((string(last - 1, 2, ["AS", "OS"]) || string(last, 1, ["A", "O"])) && string(cur - 1, 4, ["ALLE"])) {
                            add("L", ""); cur += 2
                        } else { add("L"); cur += 2 }
                    } else { add("L"); cur += 1 }
                case "M":
                    if (string(cur - 1, 3, ["UMB"]) && (cur + 1 == last || string(cur + 2, 2, ["ER"]))) || at(cur + 1) == "M" { cur += 2 }
                    else { cur += 1 }
                    add("M")
                case "N":
                    add("N"); cur += at(cur + 1) == "N" ? 2 : 1
                case "Ñ":
                    add("N"); cur += 1
                case "P":
                    if at(cur + 1) == "H" { add("F"); cur += 2 }
                    else { add("P"); cur += string(cur + 1, 1, ["P", "B"]) ? 2 : 1 }
                case "Q":
                    add("K"); cur += at(cur + 1) == "Q" ? 2 : 1
                case "R":
                    if cur == last && !slavoGermanic && string(cur - 2, 2, ["IE"]) && !string(cur - 4, 2, ["ME", "MA"]) { add("", "R") }
                    else { add("R") }
                    cur += at(cur + 1) == "R" ? 2 : 1
                case "S": handleS()
                case "T":
                    if string(cur, 4, ["TION"]) { add("X"); cur += 3 }
                    else if string(cur, 3, ["TIA", "TCH"]) { add("X"); cur += 3 }
                    else if string(cur, 2, ["TH"]) || string(cur, 3, ["TTH"]) {
                        if string(cur + 2, 2, ["OM", "AM"]) || string(0, 4, ["VAN ", "VON "]) || string(0, 3, ["SCH"]) { add("T") }
                        else { add("0", "T") }
                        cur += 2
                    } else { add("T"); cur += string(cur + 1, 1, ["T", "D"]) ? 2 : 1 }
                case "V":
                    add("F"); cur += at(cur + 1) == "V" ? 2 : 1
                case "W":
                    if string(cur, 2, ["WR"]) { add("R"); cur += 2 }
                    else {
                        if cur == 0 && (isVowel(cur + 1) || string(cur, 2, ["WH"])) {
                            if isVowel(cur + 1) { add("A", "F") } else { add("A") }
                        }
                        if (cur == last && isVowel(cur - 1)) || string(cur - 1, 5, ["EWSKI", "EWSKY", "OWSKI", "OWSKY"]) || string(0, 3, ["SCH"]) {
                            add("", "F"); cur += 1
                        } else if string(cur, 4, ["WICZ", "WITZ"]) { add("TS", "FX"); cur += 4 }
                        else { cur += 1 }
                    }
                case "X":
                    if !(cur == last && (string(cur - 3, 3, ["IAU", "EAU"]) || string(cur - 2, 2, ["AU", "OU"]))) { add("KS") }
                    cur += string(cur + 1, 1, ["C", "X"]) ? 2 : 1
                case "Z":
                    if at(cur + 1) == "H" { add("J"); cur += 2 }
                    else {
                        if string(cur + 1, 2, ["ZO", "ZI", "ZA"]) || (slavoGermanic && cur > 0 && at(cur - 1) != "T") { add("S", "TS") }
                        else { add("S") }
                        cur += at(cur + 1) == "Z" ? 2 : 1
                    }
                default:
                    cur += 1
                }
            }
            if primary.count > maxLength { primary = String(primary.prefix(maxLength)) }
            if secondary.count > maxLength { secondary = String(secondary.prefix(maxLength)) }
        }

        mutating func handleC() {
            // Various germanic
            if cur > 1 && !isVowel(cur - 2) && string(cur - 1, 3, ["ACH"]) && at(cur + 2) != "I"
                && (at(cur + 2) != "E" || string(cur - 2, 6, ["BACHER", "MACHER"])) {
                add("K"); cur += 2; return
            }
            if cur == 0 && string(cur, 6, ["CAESAR"]) { add("S"); cur += 2; return }
            if string(cur, 4, ["CHIA"]) { add("K"); cur += 2; return }
            if string(cur, 2, ["CH"]) {
                if cur > 0 && string(cur, 4, ["CHAE"]) { add("K", "X"); cur += 2; return }
                if cur == 0 && (string(cur + 1, 5, ["HARAC", "HARIS"]) || string(cur + 1, 3, ["HOR", "HYM", "HIA", "HEM"])) && !string(0, 5, ["CHORE"]) {
                    add("K"); cur += 2; return
                }
                if string(0, 4, ["VAN ", "VON "]) || string(0, 3, ["SCH"])
                    || string(cur - 2, 6, ["ORCHES", "ARCHIT", "ORCHID"])
                    || string(cur + 2, 1, ["T", "S"])
                    || ((string(cur - 1, 1, ["A", "O", "U", "E"]) || cur == 0) && string(cur + 2, 1, ["L", "R", "N", "M", "B", "H", "F", "V", "W", " "])) {
                    add("K")
                } else if cur > 0 {
                    if string(0, 2, ["MC"]) { add("K") } else { add("X", "K") }
                } else { add("X") }
                cur += 2; return
            }
            if string(cur, 2, ["CZ"]) && !string(cur - 2, 4, ["WICZ"]) { add("S", "X"); cur += 2; return }
            if string(cur + 1, 3, ["CIA"]) { add("X"); cur += 3; return }
            if string(cur, 2, ["CC"]) && !(cur == 1 && at(0) == "M") {
                if string(cur + 2, 1, ["I", "E", "H"]) && !string(cur + 2, 2, ["HU"]) {
                    if (cur == 1 && at(cur - 1) == "A") || string(cur - 1, 5, ["UCCEE", "UCCES"]) { add("KS") } else { add("X") }
                    cur += 3; return
                }
                add("K"); cur += 2; return
            }
            if string(cur, 2, ["CK", "CG", "CQ"]) { add("K"); cur += 2; return }
            if string(cur, 2, ["CI", "CE", "CY"]) {
                if string(cur, 3, ["CIO", "CIE", "CIA"]) { add("S", "X") } else { add("S") }
                cur += 2; return
            }
            add("K")
            if string(cur + 1, 2, [" C", " Q", " G"]) { cur += 3 }
            else if string(cur + 1, 1, ["C", "K", "Q"]) && !string(cur + 1, 2, ["CE", "CI"]) { cur += 2 }
            else { cur += 1 }
        }

        mutating func handleG() {
            if at(cur + 1) == "H" {
                if cur > 0 && !isVowel(cur - 1) { add("K"); cur += 2; return }
                if cur == 0 {
                    if at(cur + 2) == "I" { add("J") } else { add("K") }
                    cur += 2; return
                }
                if (cur > 1 && string(cur - 2, 1, ["B", "H", "D"]))
                    || (cur > 2 && string(cur - 3, 1, ["B", "H", "D"]))
                    || (cur > 3 && string(cur - 4, 1, ["B", "H"])) {
                    cur += 2; return
                }
                if cur > 2 && at(cur - 1) == "U" && string(cur - 3, 1, ["C", "G", "L", "R", "T"]) { add("F") }
                else if cur > 0 && at(cur - 1) != "I" { add("K") }
                cur += 2; return
            }
            if at(cur + 1) == "N" {
                if cur == 1 && isVowel(0) && !slavoGermanic { add("KN", "N") }
                else if !string(cur + 2, 2, ["EY"]) && at(cur + 1) != "Y" && !slavoGermanic { add("N", "KN") }
                else { add("KN") }
                cur += 2; return
            }
            if string(cur + 1, 2, ["LI"]) && !slavoGermanic { add("KL", "L"); cur += 2; return }
            if cur == 0 && (at(cur + 1) == "Y" || string(cur + 1, 2, ["ES", "EP", "EB", "EL", "EY", "IB", "IL", "IN", "IE", "EI", "ER"])) {
                add("K", "J"); cur += 2; return
            }
            if (string(cur + 1, 2, ["ER"]) || at(cur + 1) == "Y")
                && !string(0, 6, ["DANGER", "RANGER", "MANGER"])
                && !string(cur - 1, 1, ["E", "I"]) && !string(cur - 1, 3, ["RGY", "OGY"]) {
                add("K", "J"); cur += 2; return
            }
            if string(cur + 1, 1, ["E", "I", "Y"]) || string(cur - 1, 4, ["AGGI", "OGGI"]) {
                if string(0, 4, ["VAN ", "VON "]) || string(0, 3, ["SCH"]) || string(cur + 1, 2, ["ET"]) { add("K") }
                else if string(cur + 1, 4, ["IER "]) || cur + 1 == last && string(cur + 1, 3, ["IER"]) { add("J") }
                else { add("J", "K") }
                cur += 2; return
            }
            add("K"); cur += at(cur + 1) == "G" ? 2 : 1
        }

        mutating func handleS() {
            if string(cur - 1, 3, ["ISL", "YSL"]) { cur += 1; return }
            if cur == 0 && string(cur, 5, ["SUGAR"]) { add("X", "S"); cur += 1; return }
            if string(cur, 2, ["SH"]) {
                if string(cur + 1, 4, ["HEIM", "HOEK", "HOLM", "HOLZ"]) { add("S") } else { add("X") }
                cur += 2; return
            }
            if string(cur, 3, ["SIO", "SIA"]) || string(cur, 4, ["SIAN"]) {
                if !slavoGermanic { add("S", "X") } else { add("S") }
                cur += 3; return
            }
            if (cur == 0 && string(cur + 1, 1, ["M", "N", "L", "W"])) || string(cur + 1, 1, ["Z"]) {
                add("S", "X"); cur += string(cur + 1, 1, ["Z"]) ? 2 : 1; return
            }
            if string(cur, 2, ["SC"]) {
                if at(cur + 2) == "H" {
                    if string(cur + 3, 2, ["OO", "ER", "EN", "UY", "ED", "EM"]) {
                        if string(cur + 3, 2, ["ER", "EN"]) { add("X", "SK") } else { add("SK") }
                    } else if cur == 0 && !isVowel(3) && at(3) != "W" { add("X", "S") }
                    else { add("X") }
                    cur += 3; return
                }
                if string(cur + 2, 1, ["I", "E", "Y"]) { add("S"); cur += 3; return }
                add("SK"); cur += 3; return
            }
            if cur == last && string(cur - 2, 2, ["AI", "OI"]) { add("", "S") } else { add("S") }
            cur += string(cur + 1, 1, ["S", "Z"]) ? 2 : 1
        }
    }
}
