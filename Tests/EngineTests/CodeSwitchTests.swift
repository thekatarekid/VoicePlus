import Foundation
import Testing
import Shared
@testable import Engine

private func span(_ t: String, _ s: TimeInterval, _ e: TimeInterval, c: Float = 0.9) -> TranscriptSpan {
    TranscriptSpan(text: t, confidence: c, audioRange: s...e, provenance: [.asr])
}

private struct Fixture: Decodable {
    struct S: Decodable { let text: String; let confidence: Float; let audioStart: Double; let audioEnd: Double }
    let expected: String
    let spans: [S]
    static func hinglish() throws -> Fixture {
        let url = try #require(AppPaths.fixturesDirectory()).appendingPathComponent("transcripts/hinglish.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }
    var transcript: [TranscriptSpan] { spans.map { span($0.text, $0.audioStart, $0.audioEnd, c: $0.confidence) } }
}

@Suite("CodeSwitch: Script")
struct CodeSwitchScriptTests {
    @Test func scalarsClassify() {
        #expect(Script.of("a") == .latin)
        #expect(Script.of("क") == .devanagari)
        #expect(Script.of("ा") == .neutral)   // matra is a mark
        #expect(Script.of("।") == .neutral)   // danda is punctuation
        #expect(Script.of("5") == .neutral)
        #expect(Script.of("я") == .other)
    }
    @Test func dominantScriptOfWords() {
        #expect(Script.dominant(in: "बजे,") == .devanagari)
        #expect(Script.dominant(in: "meeting") == .latin)
        #expect(Script.dominant(in: "10,") == .neutral)
    }
}

@Suite("CodeSwitch: LanguageDetector")
struct CodeSwitchDetectorTests {
    @Test func pureEnglish() {
        let d = LanguageDetector.detect("please send the deck before lunch")
        #expect(d.language == .english && d.dominantScript == .latin && d.confidence == 1)
    }
    @Test func devanagariIsHindi() {
        let d = LanguageDetector.detect("कल मीटिंग दस बजे है")
        #expect(d.language == .hindi && d.dominantScript == .devanagari && d.scripts == [.devanagari])
    }
    @Test func romanizedHindiIsHindi() {
        let d = LanguageDetector.detect("kal meeting hai kya bhai")
        #expect(d.language == .mixed || d.language == .hindi)
        #expect(LanguageDetector.isRomanHindi("chahiye"))
        #expect(!LanguageDetector.isRomanHindi("the"))
        #expect(!LanguageDetector.isRomanHindi("main")) // vetoed ambiguous English word
    }
    @Test func mixedUtteranceIsMixed() {
        let d = LanguageDetector.detect("please deck भेज दो before lunch")
        #expect(d.language == .mixed)
        #expect(d.scripts == [.latin, .devanagari])
        #expect(d.confidence >= 0.5 && d.confidence <= 1)
    }
    @Test func streamingAccumulates() {
        var det = LanguageDetector()
        #expect(det.feed("hello").language == .english)
        #expect(det.feed("world").language == .english)
        let d = det.feed("नमस्ते दुनिया")
        #expect(d.language == .mixed && d.words.count == 4)
        det.reset()
        #expect(det.current.language == .unknown)
    }
    @Test func emptyIsUnknown() {
        let d = LanguageDetector.detect("  ")
        #expect(d.language == .unknown && d.confidence == 0 && d.words.isEmpty)
    }
}

@Suite("CodeSwitch: ScriptAwareMerger")
struct CodeSwitchMergerTests {
    let merger = ScriptAwareMerger()

    @Test func hinglishFixtureLandsAsOneString() throws {
        let f = try Fixture.hinglish()
        let out = merger.merge(f.transcript)
        #expect(out.text == f.expected)
        #expect(out.isCodeSwitched && out.language == .mixed)
    }
    @Test func fixtureSegmentsAlternateScripts() throws {
        let out = merger.merge(try Fixture.hinglish().transcript)
        #expect(out.segments.map(\.script) == [.latin, .devanagari, .latin, .devanagari, .latin])
        #expect(out.segments[1].text == "बजे है,")
        #expect(out.segments[1].spanIndices == [3, 4])
        #expect(out.segments[1].audioRange == 0.95...1.50)
        // "10" is neutral and extends the Latin segment; audio range covers it.
        #expect(out.segments[0].text == "Kal meeting 10" && out.segments[0].audioRange == 0.0...0.95)
    }
    @Test func preservesConfidenceAudioAndProvenance() throws {
        let input = try Fixture.hinglish().transcript
        let out = merger.merge(input)
        #expect(out.spans.count == input.count)
        for (a, b) in zip(input, out.spans) {
            #expect(a.confidence == b.confidence && a.audioRange == b.audioRange)
            #expect(b.provenance == [.asr, .codeSwitchMerge])
        }
    }
    @Test func punctuationSpacing() {
        let out = merger.merge([span("ठीक", 0, 0.3), span("है", 0.3, 0.5), span("।", 0.5, 0.55), span("ok", 0.6, 0.8), span("?", 0.8, 0.85)])
        #expect(out.text == "ठीक है। ok?")
        #expect(out.segments.count == 2)
        #expect(out.segments[0].text == "ठीक है।" && out.segments[0].spanIndices == [0, 1, 2])
    }
    @Test func openingQuoteNoSpaceAfter() {
        let out = merger.merge([span("say", 0, 0.2), span("\"", 0.2, 0.21), span("नमस्ते", 0.21, 0.5), span("\"", 0.5, 0.51)])
        #expect(out.text == "say \"नमस्ते\"")
    }
    @Test func emptyAndWhitespaceSpansSkipped() {
        let out = merger.merge([span("hi", 0, 0.1), span("  ", 0.1, 0.2), span("वहाँ", 0.2, 0.4)])
        #expect(out.text == "hi वहाँ" && out.spans.count == 3 && out.segments.count == 2)
    }
    @Test func pureLatinIsNotCodeSwitched() {
        let out = merger.merge([span("hello", 0, 0.1), span("world", 0.1, 0.2)])
        #expect(out.text == "hello world" && !out.isCodeSwitched && out.language == .english)
    }
    @Test func segmentsRoundTripJSON() throws {
        let out = merger.merge(try Fixture.hinglish().transcript)
        let data = try JSONEncoder().encode(out)
        #expect(try JSONDecoder().decode(ScriptSegments.self, from: data) == out)
    }
}

@Suite("CodeSwitch: IndicASRBackend")
struct CodeSwitchBackendTests {
    @Test func availabilityMissingFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cs-\(UUID().uuidString)")
        #expect(IndicASRAvailability.check(modelsDirectory: nil) == .noModelsDirectory)
        #expect(IndicASRAvailability.check(modelsDirectory: dir) == .missing(files: IndicASRAvailability.requiredFiles))
        let model = dir.appendingPathComponent(IndicASRAvailability.modelFolder)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        for f in IndicASRAvailability.requiredFiles { FileManager.default.createFile(atPath: model.appendingPathComponent(f).path, contents: Data()) }
        #expect(IndicASRAvailability.check(modelsDirectory: dir) == .available(path: model.standardizedFileURL.path))
        try? FileManager.default.removeItem(at: dir)
    }
    @Test func unavailableBackendThrows() async {
        let b = UnavailableIndicBackend(status: .noModelsDirectory)
        #expect(!b.isAvailable && b.languages.isEmpty)
        await #expect(throws: UnavailableIndicBackend.NotInstalled(status: .noModelsDirectory)) { try await b.recognize([0, 0]) }
    }
    @Test func routerFallsBackWhenIndicMissing() async throws {
        let primary = MockIndicBackend(scripted: [span("hello", 0, 0.2)])
        let router = CodeSwitchRouter(primary: primary, indic: UnavailableIndicBackend(status: .noModelsDirectory))
        #expect(!router.shouldRouteToIndic(previewText: "कल मीटिंग है"))
        let out = try await router.recognize([], previewText: "कल मीटिंग है")
        #expect(out.text == "hello" && primary.calls == 1)
    }
    @Test func routerUsesIndicWhenHindiHeard() async throws {
        let primary = MockIndicBackend(scripted: [span("hello", 0, 0.2)])
        let indic = MockIndicBackend(scripted: try Fixture.hinglish().transcript)
        let router = CodeSwitchRouter(primary: primary, indic: indic)
        #expect(!router.shouldRouteToIndic(previewText: "send the deck"))
        #expect(router.shouldRouteToIndic(previewText: "deck bhej do"))
        let out = try await router.recognize([], previewText: "kal meeting hai")
        #expect(out.isCodeSwitched && indic.calls == 1 && primary.calls == 0)
    }
}

@Suite("CodeSwitch: ScriptIndicatorModel")
struct CodeSwitchIndicatorTests {
    @Test func labelsFollowScripts() {
        var m = ScriptIndicatorModel()
        #expect(m.label == "")
        m.update(with: LanguageDetector.detect("hello there"))
        #expect(m.state == .latin && m.label == "EN")
        m.update(with: LanguageDetector.detect("नमस्ते"))
        #expect(m.state == .devanagari && m.label == "हि")
        m.update(with: LanguageDetector.detect("please deck भेज दो"))
        #expect(m.state == .mixed && m.label == "EN·हि" && m.accessibilityLabel == "Hindi and English")
        m.reset()
        #expect(m.state == .none)
    }
    @Test func lowConfidenceDoesNotFlicker() {
        var m = ScriptIndicatorModel(minimumConfidence: 0.99)
        m.update(with: LanguageDetector.detect("hello"))
        #expect(m.state == .latin)
        var weak = LanguageDetector.detect("नमस्ते")
        weak.confidence = 0.3; weak.language = .hindi
        m.update(with: weak)
        #expect(m.state == .latin)
    }
    @Test func updatesFromMergedSegments() throws {
        var m = ScriptIndicatorModel()
        m.update(with: ScriptAwareMerger().merge(try Fixture.hinglish().transcript))
        #expect(m.state == .mixed)
    }
}
