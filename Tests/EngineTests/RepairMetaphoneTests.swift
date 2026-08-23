import Foundation
import Testing
import Shared
@testable import Engine

@Suite("P1.6 T2 — Double Metaphone")
struct RepairMetaphoneTests {
    /// Hand-derived from the published algorithm (primary, secondary; nil = same as primary).
    static let vectors: [(String, String, String?)] = [
        ("Smith", "SM0", "XMT"),
        ("Schmidt", "XMT", "SMT"),
        ("Kothari", "K0R", "KTR"),
        ("Thomas", "TMS", nil),
        ("Knight", "NT", nil),
        ("Philip", "FLP", nil),
        ("Wright", "RT", nil),
        ("Ghost", "KST", nil),
        ("Caesar", "SSR", nil),
        ("Allen", "ALN", nil),
        ("Zhang", "JNK", nil),
        ("Dumb", "TM", nil),
        ("Judge", "JJ", "AJ"),
        ("Michael", "MKL", "MXL"),
        ("Catherine", "K0RN", "KTRN"),
        ("Jose", "HS", nil),
        ("school", "SKL", nil),
        ("", "", nil),
    ]

    @Test(arguments: vectors)
    func vector(_ v: (String, String, String?)) {
        let codes = DoubleMetaphone.encode(v.0)
        #expect(codes.primary == v.1, "\(v.0) primary")
        #expect(codes.secondary == v.2, "\(v.0) secondary")
    }

    @Test func phoneticNeighboursCollide() {
        #expect(DoubleMetaphone.encode("Kothari").matches(DoubleMetaphone.encode("Cotari")))
        #expect(DoubleMetaphone.encode("Stephen").matches(DoubleMetaphone.encode("Steven")))
        #expect(DoubleMetaphone.encode("Catherine").matches(DoubleMetaphone.encode("Katherine")))
        #expect(!DoubleMetaphone.encode("Kothari").matches(DoubleMetaphone.encode("Monday")))
    }

    @Test func ignoresCaseDiacriticsAndPunctuation() {
        #expect(DoubleMetaphone.encode("müller") == DoubleMetaphone.encode("MULLER"))
        #expect(DoubleMetaphone.encode("o'brien") == DoubleMetaphone.encode("obrien"))
    }

    @Test func longerCapKeepsMoreOfLongNames() {
        let short = DoubleMetaphone.encode("Venkatasubramanian", maxLength: 4).primary
        let long = DoubleMetaphone.encode("Venkatasubramanian", maxLength: 10).primary
        #expect(short.count == 4)
        #expect(long.count > 4 && long.hasPrefix(short))
    }
}
