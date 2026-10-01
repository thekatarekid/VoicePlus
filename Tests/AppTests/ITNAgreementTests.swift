import Engine
import Foundation
import Lab
import Pipeline
import Shared
import Testing
@testable import VoicePlusApp

/// V5 D1 + K7 — NeMo ITN wired into the one `ITNStage`, preview == final, LANG locale, Hindi through
/// the wrapper, and the LibriSpeech numeric subset (opt-in: needs the V1 eval cache).
///
/// Nothing here installs process-wide state (`ITNStage.backend`, `PreviewFormatter`'s hook): every
/// suite runs in one process, and Pipeline goldens elsewhere assume the Swift rules alone.
@Suite struct ITNAgreementTests {
    static let nemo = NemoITN.shared
    static var backend: ClosureITNBackend {
        ClosureITNBackend(supports: { nemo.supports($0) }, normalize: { nemo.normalizeSentence($0, language: $1) })
    }

    /// One span per word, 200 ms each, `gap` seconds apart.
    static func spans(_ text: String, gap: Double) -> [TranscriptSpan] {
        text.split(separator: " ").enumerated().map { i, w in
            let start = Double(i) * (0.2 + gap)
            return TranscriptSpan(text: String(w), confidence: 0.95, audioRange: start...(start + 0.2), provenance: [.asr])
        }
    }

    static func preview(_ text: String, _ config: ITNStage.Config, backend: (any ITNBackend)? = nil) -> String {
        PreviewFormatter.format(text, normalizer: { ITNStage.normalize(text: $0, config: config, backend: backend) })
    }

    static var noPeriod: ProseListFormatter {
        var o = ProseListFormatter.Options()
        o.addTerminalPeriod = false
        return ProseListFormatter(options: o)
    }

    // MARK: - NeMo through the wrapper

    @Test func nemoIsLinkedAndNormalisesEnglish() throws {
        #expect(Self.nemo.isAvailable, "FluidAudio's NemoTextProcessing binary should be linked")
        guard Self.nemo.isAvailable else { return }
        print("NeMo ITN version: \(Self.nemo.version ?? "?") · language entry point: \(Self.nemo.hasLanguageEntryPoint)")
        let cases = ["five thousand one hundred and fifty", "five dollars and fifty cents", "two point five",
                     "three thirty p m", "january fifth twenty twenty five"]
        for c in cases { print("  nemo(en) \(c) → \(Self.nemo.normalizeSentence(c, language: "en") ?? "nil")") }
        #expect(Self.nemo.normalizeSentence("two hundred thirty two", language: "en") == "232")
    }

    /// D1: "verify `hi`/`hi_en` grammars load through the wrapper — if not, document and fall back to `en`".
    @Test func hindiThroughTheWrapper() {
        let hi = Self.nemo.normalizeSentence("बारह सौ", language: "hi")
        print("NeMo hi: बारह सौ → \(hi ?? "nil (no language entry point; hi falls back to the Swift rules + en)")")
        if Self.nemo.hasLanguageEntryPoint {
            #expect(Self.nemo.supports("hi"))
            #expect(hi != nil)
        } else {
            #expect(!Self.nemo.supports("hi"))
        }
        // hi_en is Latin-script: it always uses the English grammar, plus the en-IN locale rules.
        #expect(ITNLocale.hiEn.backendLanguage == "en")
        let config = ITNStage.Config(locale: .hiEn)
        #expect(ITNStage.normalize(text: "barah lakh nahi twelve lakh", config: config, backend: Self.backend)
                .hasSuffix("12,00,000"))
    }

    // MARK: - Goldens with the real backend

    @Test func goldensWithNemo() {
        let en = ITNStage.Config(locale: .en)
        func final(_ s: String, gap: Double = 0.05, _ c: ITNStage.Config = en) -> String {
            ITNStage.normalizeSpans(Self.spans(s, gap: gap), config: c, backend: Self.backend)
        }
        #expect(final("five thousand one hundred and fifty") == "5150")
        #expect(final("one two three four") == "1234")
        #expect(final("three thirty p.m.") == "3:30 PM")
        #expect(final("twelve lakh", ITNStage.Config(locale: .enIN)) == "12,00,000")
        // NeMo's residual reaches what the Swift rules do not.
        print("residual: five dollars and fifty cents → \(final("it was five dollars and fifty cents", gap: 0.4))")
    }

    // MARK: - Preview == final (K7)

    static let agreement: [(String, String)] = [
        ("about one hundred and twenty guests", "About 120 guests"),
        ("five thousand one hundred and fifty", "5150"),
        ("one hundred and fifteen", "115"),
        ("twelve hundred and five", "1205"),
        ("twenty five hundred and six", "2506"),
        ("a hundred and fifty", "150"),                       // V5 D1: the article counts as one
        ("one thousand and five", "1000 and five"),
        ("twenty and thirty", "20 and 30"),
        ("rock and roll", "Rock and roll"),
        ("the total is two thousand three hundred forty", "The total is 2340"),
        ("their new address is fourteen carter road", "Their new address is 14 carter road"),
        ("twenty five people", "25 people"),
        ("order two of the large ones and one of the small ones", "Order two of the large ones and one of the small ones"),
        ("five thousand one hundred and fifty.", "5150."),
        ("we sold one hundred and fifty, then stopped", "We sold 150, then stopped"),
        ("twenty, five", "20, five"),
        ("one hundred and", "100 and"),
    ]

    @Test(arguments: agreement)
    func previewWritesTheFinalDigits(_ spoken: String, _ expected: String) {
        let en = ITNStage.Config(locale: .en)
        #expect(Self.preview(spoken, en) == expected)
        // The final pass on the same words (no timing-joined digits: 400 ms gaps), minus its period.
        let final = Self.noPeriod.format(Self.spans(spoken, gap: 0.4), itn: en).renderedText
        #expect(final.lowercased() == Self.preview(spoken, en).lowercased(), "final: \(final)")
    }

    @Test func previewEqualsFinalWithNemoAndEnIN() {
        let inputs = ["twelve lakh rupees", "two crore fifty lakh", "the fifth of march twenty twenty four",
                      "it was five dollars and fifty cents", "meet at three thirty pm", "fifty percent"]
        for locale in [ITNLocale.en, .enIN] {
            let c = ITNStage.Config(locale: locale)
            for input in inputs {
                let p = Self.preview(input, c, backend: Self.backend)
                let f = ITNStage.normalizeSpans(Self.spans(input, gap: 0.4), config: c, backend: Self.backend)
                #expect(p.lowercased() == f.lowercased(), "\(locale): preview '\(p)' vs final '\(f)'")
                #expect(PreviewFormatter.addsNoPunctuation(input: input, output: p), "\(input) → \(p)")
            }
        }
    }

    // MARK: - Wiring

    @Test func localeFromLang() {
        #expect(ITNWiring.locale(environment: ["LANG": "en_IN.UTF-8"], systemLocale: "en_US") == .enIN)
        #expect(ITNWiring.locale(environment: ["LANG": "C"], systemLocale: "en_IN") == .enIN)
        #expect(ITNWiring.locale(environment: [:], systemLocale: "en_US") == .en)
        #expect(ITNWiring.locale(environment: ["VOICEPLUS_ITN_LOCALE": "hi_en", "LANG": "en_US.UTF-8"], systemLocale: "en_US") == .hiEn)
        #expect(ITNWiring.locale(environment: ["LANG": "hi_IN.UTF-8"], systemLocale: "en_US") == .hi)
    }

    // MARK: - LibriSpeech numeric subset (V1 cache; skipped when absent)

    /// The real model's test-clean hypotheses (V1 `hyp-parakeet-tdt-v3.json`) on the utterances whose
    /// reference says a number: the ITN must not cost word errors under the Open ASR normaliser
    /// (which reads "fifty" and "50" alike), with the Swift rules alone and with NeMo.
    @Test(.timeLimit(.minutes(5)))
    func libriSpeechNumericSubset() throws {
        let fm = FileManager.default
        let cache = ProcessInfo.processInfo.environment["VOICEPLUS_EVAL_CACHE"].map { URL(fileURLWithPath: $0) }
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/VoicePlus/Eval")
        let hypURL = cache.appendingPathComponent("librispeech-test-clean/hyp-parakeet-tdt-v3.json")
        let refRoot = cache.appendingPathComponent("librispeech/LibriSpeech/test-clean")
        guard fm.fileExists(atPath: hypURL.path), fm.fileExists(atPath: refRoot.path) else {
            print("SKIPPED: LibriSpeech test-clean hypotheses not in the V1 eval cache."); return
        }
        struct Hyp: Decodable { let text: String }
        struct File: Decodable { let items: [String: Hyp] }
        let hyps = try JSONDecoder().decode(File.self, from: Data(contentsOf: hypURL)).items

        var refs: [String: String] = [:]
        let walker = fm.enumerator(at: refRoot, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "txt" else { continue }
            for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
                guard let space = line.firstIndex(of: " ") else { continue }
                refs[String(line[..<space])] = String(line[line.index(after: space)...])
            }
        }
        let numberWords: Set<String> = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                                        "eleven", "twelve", "fifteen", "twenty", "thirty", "forty", "fifty", "sixty",
                                        "hundred", "thousand", "million"]
        let subset = refs.filter { id, ref in
            hyps[id] != nil && ref.lowercased().split(separator: " ").contains { numberWords.contains(String($0)) }
        }
        #expect(subset.count >= 50, "numeric subset too small: \(subset.count)")

        func errors(_ transform: (String) -> String) -> (errors: Int, words: Int) {
            var e = 0, w = 0
            for (id, ref) in subset {
                let r = OpenASRNormalizer.words(ref), h = OpenASRNormalizer.words(transform(hyps[id]!.text))
                let s = WERScorer.score(reference: r, hypothesis: h)
                e += s.errors; w += s.referenceWords
            }
            return (e, w)
        }
        let en = ITNStage.Config(locale: .en)
        if ProcessInfo.processInfo.environment["VOICEPLUS_ITN_DUMP"] != nil {
            for (id, ref) in subset.sorted(by: { $0.key < $1.key }) {
                let h = hyps[id]!.text
                for (label, t) in [("swift", ITNStage.normalize(text: h, config: en, backend: nil)),
                                   ("nemo", ITNStage.normalize(text: h, config: en, backend: Self.backend))] {
                    let a = WERScorer.score(reference: OpenASRNormalizer.words(ref), hypothesis: OpenASRNormalizer.words(h)).errors
                    let b = WERScorer.score(reference: OpenASRNormalizer.words(ref), hypothesis: OpenASRNormalizer.words(t)).errors
                    if b > a { print("DUMP \(label) +\(b - a) | \(h) | \(t)") }
                }
            }
        }
        let base = errors { $0 }
        let swift = errors { ITNStage.normalize(text: $0, config: en, backend: nil) }
        let nemo = errors { ITNStage.normalize(text: $0, config: en, backend: Self.backend) }
        func pct(_ x: (errors: Int, words: Int)) -> String { String(format: "%.2f%%", 100 * Double(x.errors) / Double(max(x.words, 1))) }
        print("D1 LibriSpeech test-clean numeric subset (\(subset.count) utts): raw \(pct(base)) · ITN swift \(pct(swift)) · ITN swift+nemo \(pct(nemo))")
        // ≤ 0.5 pp worse than the untouched hypothesis.
        #expect(Double(swift.errors - base.errors) / Double(max(base.words, 1)) <= 0.005)
        #expect(Double(nemo.errors - base.errors) / Double(max(base.words, 1)) <= 0.005)
    }
}
