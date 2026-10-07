import CoreGraphics
import Engine
import Foundation
import Injection
import Shared
import Testing
@testable import VoicePlusApp

// S5 — uncertainty marks and correction (design_v1 §7, §8.8; build doc S5): the mark mapping table,
// the pill's fragments, the destination support ladder and overlay suppression, the popover model,
// the range-guarded replace, and the coordinator that ties them to the turn.

private func span(_ text: String, _ confidence: Float = 0.95, at t: Double = 0, alternates: [Alternate] = []) -> TranscriptSpan {
    TranscriptSpan(text: text, confidence: confidence, audioRange: t...(t + 0.3), alternates: alternates, provenance: [.asr])
}

private func spans(_ words: [(String, Float)]) -> [TranscriptSpan] {
    words.enumerated().map { span($0.element.0, $0.element.1, at: Double($0.offset) * 0.3) }
}

private func utf16(_ text: String, of word: String, occurrence: Int = 0) -> Range<Int> {
    let s = text as NSString
    var from = 0
    var found = NSRange(location: NSNotFound, length: 0)
    for _ in 0...occurrence {
        found = s.range(of: word, options: [], range: NSRange(location: from, length: s.length - from))
        from = found.location + found.length
    }
    return found.location..<(found.location + found.length)
}

@Suite("S5 — mark mapping through formatting")
struct MarkMappingTests {
    @Test("a preserved uncertain name keeps its mark; punctuation stays outside it")
    func preservedName() throws {
        let text = "Can we meet with Mira, on Friday?"
        let m = UncertaintyMarkMapper.map(source: spans([("can", 0.9), ("we", 0.9), ("meet", 0.9), ("with", 0.9),
                                                          ("mira", 0.3), ("on", 0.9), ("friday", 0.9)]), finalText: text)
        let mark = try #require(m.marks.first)
        #expect(m.marks.count == 1)
        #expect(mark.kind == .word && mark.text == "Mira" && mark.heard == "mira")
        #expect(mark.range == utf16(text, of: "Mira"))
        #expect(m.reviewLine == "1 word to review")
        #expect(m.uncertainRanges == [utf16(text, of: "Mira")])
        #expect(mark.accessibilityLabel == "Mira, uncertain word")
    }

    @Test("a removed filler loses its mark")
    func removedFiller() {
        let m = UncertaintyMarkMapper.map(source: spans([("um", 0.2), ("send", 0.9), ("it", 0.9)]), finalText: "Send it.")
        #expect(m.marks.isEmpty && m.confidenceAvailable)
        #expect(m.reviewLine == "")
    }

    @Test("marks never reuse offsets: the second, uncertain “the” is marked, not the first")
    func repeatedWord() throws {
        let text = "The cat saw the dog."
        let m = UncertaintyMarkMapper.map(source: spans([("the", 0.9), ("cat", 0.9), ("saw", 0.9), ("the", 0.3), ("dog", 0.9)]),
                                          finalText: text)
        let mark = try #require(m.marks.first)
        #expect(m.marks.count == 1 && mark.range == utf16(text, of: "the"))
    }

    @Test("a rewrite into one word marks that word (the smallest reliably mapped piece)")
    func rewriteIntoOneWord() throws {
        let text = "It costs $25 today."
        let m = UncertaintyMarkMapper.map(source: spans([("it", 0.9), ("costs", 0.9), ("twenty", 0.9), ("five", 0.3),
                                                          ("dollars", 0.9), ("today", 0.9)]), finalText: text)
        let mark = try #require(m.marks.first)
        #expect(m.marks.count == 1 && mark.kind == .word)
        #expect(mark.text == "25" && mark.heard == "twenty five dollars")
    }

    @Test("an unalignable rewrite flags the smallest reliably aligned phrase (T05)")
    func phrase() throws {
        let text = "a fast auburn fox jumps"
        let m = UncertaintyMarkMapper.map(source: spans([("the", 0.9), ("quick", 0.9), ("brown", 0.3), ("fox", 0.9), ("jumps", 0.9)]),
                                          finalText: text)
        let mark = try #require(m.marks.first)
        #expect(mark.kind == .phrase && mark.text == "a fast auburn")
        #expect(m.needsPhraseReview && m.reviewLine == "Review this phrase")
        #expect(m.reviewLine == RecoveryCatalog.entry(.T05).headline)
        #expect(mark.accessibilityLabel.hasSuffix("uncertain phrase"))
    }

    @Test("when nothing aligns the whole result is labelled for review")
    func wholeResult() throws {
        let m = UncertaintyMarkMapper.map(source: spans([("gonna", 0.3), ("head", 0.9), ("out", 0.9)]), finalText: "Leaving now.")
        let mark = try #require(m.marks.first)
        #expect(m.marks.count == 1 && mark.kind == .wholeResult && mark.text == "Leaving now")
    }

    @Test("words joined without spaces (code-switching, CJK) are cut in order inside the run")
    func unspacedRun() throws {
        let text = "明天见米拉。"
        let m = UncertaintyMarkMapper.map(source: spans([("明天", 0.9), ("见", 0.9), ("米拉", 0.3)]), finalText: text)
        let mark = try #require(m.marks.first)
        #expect(m.marks.count == 1 && mark.text == "米拉" && mark.kind == .word)
    }

    @Test("streaming words taken as available text carry no confidence: nothing marked, nothing claimed")
    func confidenceUnavailable() {
        let available = [TranscriptSpan(text: "call mira", confidence: 0.5, audioRange: 0...0, provenance: [.asr])]
        let m = UncertaintyMarkMapper.map(source: available, finalText: "Call Mira.")
        #expect(m.marks.isEmpty && !m.confidenceAvailable)
        #expect(!UncertaintyMarkMapper.map(source: [], finalText: "x").confidenceAvailable)
    }

    @Test("at most three credible alternatives, best first, cased like the word, never the word itself")
    func alternatives() throws {
        let alternates = [Alternate(text: "meera", score: 0.4, source: .beam), Alternate(text: "Mira", score: 0.9, source: .beam),
                          Alternate(text: "myra", score: 0.3, source: .beam), Alternate(text: "", score: 0.8, source: .beam),
                          Alternate(text: "Mera", score: 0.2, source: .beam), Alternate(text: "Meara", score: 0.1, source: .beam)]
        let source = [span("meet", 0.9), span("mira", 0.3, at: 0.3, alternates: alternates)]
        let mark = try #require(UncertaintyMarkMapper.map(source: source, finalText: "Meet Mira.").marks.first)
        #expect(mark.alternatives == ["Meera", "Myra", "Mera"])
        #expect(mark.confidence == 0.3)
    }

    @Test("what was heard is offered back when formatting changed an uncertain word")
    func heardAsAlternative() throws {
        let mark = try #require(UncertaintyMarkMapper.map(source: [span("kotari", 0.2)], finalText: "Kothari").marks.first)
        #expect(mark.kind == .word && mark.alternatives == ["Kotari"])
    }

    @Test("resolved marks leave the mapping; the rest keep their ids")
    func removing() {
        let m = UncertaintyMarkMapper.map(source: spans([("mira", 0.3), ("and", 0.9), ("joaquin", 0.2)]), finalText: "Mira and Joaquin")
        #expect(m.count == 2 && m.reviewLine == "2 words to review")
        let left = m.removing([0])
        #expect(left.marks.map(\.text) == ["Joaquin"] && left.marks.first?.id == 1)
        #expect(left.mark(at: utf16("Mira and Joaquin", of: "Joaquin").lowerBound)?.id == 1)
        #expect(m.accessibilityLabel == "Mira and Joaquin. 2 words to review: “Mira”, “Joaquin”")
    }
}

@Suite("S5 — the pill's marks")
struct PillMarkTests {
    @Test("the underline is 2 px, 3 px below the baseline, dotted")
    func style() {
        #expect(MarkStyle.thickness == 2 && MarkStyle.baselineOffset == 3 && MarkStyle.dash == [2, 2])
        let box = CGRect(x: 10, y: 100, width: 40, height: 20)
        let u = MarkStyle.underline(below: box)
        #expect(u.height == 2 && u.width == 40 && abs(u.maxY - (100 + 20 * MarkStyle.descentRatio - 3)) < 0.001)
    }

    @Test("the pill maps the final spans onto the shown text; live words are never marked")
    func pillMapping() throws {
        let model = PillViewModel()
        model.setFinalSpans(spans([("meet", 0.9), ("mira", 0.3)]))
        let mapping = model.marks(for: .final("Meet Mira."))
        #expect(mapping.marks.map(\.text) == ["Mira"])
        #expect(model.marks(for: .live("Meet Mira.")).isEmpty)
        model.resolveMarks([0])
        #expect(model.marks(for: .final("Meet Mira.")).isEmpty, "kept or corrected: cleared for this turn")
        model.setFinalSpans(spans([("meet", 0.9), ("mira", 0.3)]))
        #expect(model.resolvedMarks.isEmpty, "a new payload starts with every mark")
    }

    @Test("spans of a finished turn never mark the next turn's words")
    func staleSpans() {
        let model = PillViewModel()
        model.setFinalSpans(spans([("meet", 0.9), ("mira", 0.3)]))
        model.present(.finalPreview(FinalPreviewInfo(text: "Meet Mira.", uncertainCount: 1, dwellRemaining: 1.8)))
        #expect(model.markMapping(for: "Meet Mira.").count == 1)
        #expect(model.markMapping(for: "Tomorrow we ship the release at noon.").isEmpty, "another text")
        #expect(UncertaintyMarkMapper.belongs(spans([("meet", 0.9), ("mira", 0.3)]), to: "Meet Mira!"))
        #expect(!UncertaintyMarkMapper.belongs([], to: "Meet Mira."))
    }

    @Test("a dotted word opens the inline notch editor")
    func reviewHooks() throws {
        let model = PillViewModel()
        model.setFinalSpans(spans([("meet", 0.9), ("mira", 0.3)]))
        model.present(.finalPreview(FinalPreviewInfo(text: "Meet Mira.", uncertainCount: 1, dwellRemaining: 1.8)))
        model.reviewMark(0)
        model.reviewMark(9)
        #expect(model.isEditingDraft && model.editingMarkID == 0)
        model.cancelDraftEdits()
        #expect(!model.isEditingDraft)
    }
}

// MARK: - Destination ladder and overlay

final class ScriptedField: MarkGeometrySource {
    var value: String?
    var rects: [Range<Int>: CGRect] = [:]
    var lineHeight: CGFloat = 20
    /// Default geometry: each UTF-16 unit is 8 pt wide on one line at y 500.
    var autoRects = true
    var visible: CGRect?
    var isFrontmost = true
    var isAlive = true
    var asked: [Range<Int>] = []

    init(_ value: String?) { self.value = value }

    func currentValue() -> String? { value }
    func rect(for range: Range<Int>) -> CGRect? {
        asked.append(range)
        if let r = rects[range] { return r }
        return autoRects ? CGRect(x: 100 + CGFloat(range.lowerBound) * 8, y: 500, width: CGFloat(range.count) * 8, height: lineHeight) : nil
    }
    func visibleFrame() -> CGRect? { visible }
}

@Suite("S5 — destination support ladder and overlay suppression")
struct DestinationMarksTests {
    static let text = "Can we meet with Mira on Friday?"

    func session(_ tier: WordMarkTier = .overlay, at offset: Int = 10) -> DestinationMarkSession {
        let marks = UncertaintyMarkMapper.map(source: spans([("can", 0.9), ("we", 0.9), ("meet", 0.9), ("with", 0.9), ("mira", 0.3),
                                                              ("on", 0.9), ("friday", 0.9)]), finalText: Self.text).marks
        return DestinationMarkSession(bundleID: "com.apple.Notes", tier: tier,
                                      landed: offset..<(offset + Self.text.utf16.count), text: Self.text, marks: marks)
    }

    func field(prefix: String = "Dear team ") -> ScriptedField { ScriptedField(prefix + Self.text) }

    @Test("the ladder: VoicePlus fields native, the validated matrix overlay, everything else D09")
    func ladder() {
        let ladder = WordMarkLadder(ownBundleID: "com.voiceplus.app")
        #expect(ladder.tier(for: "com.voiceplus.app") == .native)
        for bundle in WordMarkLadder.firstMatrix { #expect(ladder.tier(for: bundle) == .overlay) }
        #expect(WordMarkLadder.firstMatrix == ["com.apple.Notes", "com.apple.TextEdit", "com.apple.mail", "com.apple.Safari"])
        #expect(ladder.tier(for: "com.google.Chrome") == .unavailable)
        #expect(ladder.tier(for: "com.apple.Notes", secure: true) == .unavailable)
        #expect(ladder.tier(for: nil) == .unavailable)
    }

    @Test("valid text and geometry: one underline per marked word, under its box")
    func shown() throws {
        let s = session(), f = field()
        let fragments = s.revalidate(f).fragments
        let fragment = try #require(fragments.first)
        #expect(fragments.count == 1 && fragment.markID == 0)
        let mira = utf16(Self.text, of: "Mira")
        #expect(f.asked.last == (10 + mira.lowerBound)..<(10 + mira.upperBound))
        #expect(fragment.underline == MarkStyle.underline(below: fragment.box))
        #expect(s.validatedOnce)
    }

    @Test("the app leaves the front: hidden; back in front: restored only after revalidation")
    func appSwitch() {
        let s = session(), f = field()
        f.isFrontmost = false
        #expect(s.revalidate(f) == .hidden(.appInactive))
        f.isFrontmost = true
        #expect(s.revalidate(f).fragments.count == 1)
        f.value = "Dear team Can we meet with Myra on Friday?"
        #expect(s.revalidate(f) == .cleared(.textChanged), "re-validated, not blindly restored")
    }

    @Test("an edit elsewhere in the field is followed; an edit in the text clears the marks")
    func edits() {
        let s = session(), f = field()
        f.value = "Hi — Dear team " + Self.text
        #expect(s.revalidate(f).fragments.count == 1)
        #expect(s.landed.lowerBound == 15)
        f.value = "Dear team Can we meet with Mira on Friday? " + Self.text   // ambiguous now
        #expect(s.revalidate(f) == .cleared(.textChanged))
    }

    @Test("no trustworthy rectangles before validation: D09 (no floating marks); after: scrolled away")
    func geometry() {
        let s1 = session(), f1 = field()
        f1.autoRects = false
        #expect(s1.revalidate(f1) == .cleared(.noGeometry))
        #expect(WordMarkCapabilityPolicy.verdict(for: s1.phase, tier: .overlay) == false)

        let s2 = session(), f2 = field()
        #expect(s2.revalidate(f2).fragments.count == 1)
        #expect(WordMarkCapabilityPolicy.verdict(for: s2.phase, tier: .overlay) == true)
        f2.autoRects = false
        #expect(s2.revalidate(f2) == .hidden(.scrolledAway))
        f2.autoRects = true
        f2.visible = CGRect(x: 0, y: 0, width: 50, height: 50)
        #expect(s2.revalidate(f2) == .hidden(.scrolledAway), "outside the field's visible frame")
        #expect(WordMarkCapabilityPolicy.verdict(for: s2.phase, tier: .overlay) == nil, "transient: no record")
    }

    @Test("closed, unreadable or unsupported destinations clear the overlay")
    func clears() {
        let a = session(), fa = field()
        fa.isAlive = false
        #expect(a.revalidate(fa) == .cleared(.destinationClosed))
        let b = session(), fb = field()
        fb.value = nil
        #expect(b.revalidate(fb) == .cleared(.unreadable))
        let c = session(.unavailable)
        #expect(c.revalidate(field()) == .cleared(.noGeometry))
        #expect(WordMarkCapabilityPolicy.verdict(for: c.phase, tier: .unavailable) == nil, "never promised, never recorded")
    }

    @Test("a wrapped phrase gets one fragment per line; words on one line merge")
    func lineFragments() {
        let boxes = [CGRect(x: 10, y: 100, width: 30, height: 20), CGRect(x: 44, y: 100, width: 30, height: 20),
                     CGRect(x: 0, y: 78, width: 40, height: 20)]
        #expect(DestinationMarkSession.lineFragments(boxes) == [CGRect(x: 10, y: 100, width: 64, height: 20),
                                                                CGRect(x: 0, y: 78, width: 40, height: 20)])
        #expect(!DestinationMarkSession.plausible(.zero) && !DestinationMarkSession.plausible(CGRect(x: 1, y: 1, width: 0, height: 20)))
    }

    @Test("the landed range: just before the caret, verified; else its one occurrence; else nothing")
    func locate() {
        let value = "Dear team " + Self.text
        #expect(LandedRangeLocator.locate(text: Self.text, value: value, caret: value.utf16.count) == 10..<(value.utf16.count))
        #expect(LandedRangeLocator.locate(text: Self.text, value: value, caret: 3) == 10..<(value.utf16.count))
        #expect(LandedRangeLocator.locate(text: Self.text, value: value + Self.text, caret: nil) == nil)
        #expect(LandedRangeLocator.locate(text: Self.text, value: "nothing", caret: 7) == nil)
    }

    @Test("the per-bundle record the Apps pane reads (“No overlay” until validated)")
    func record() throws {
        let defaults = try #require(UserDefaults(suiteName: "S5.marks.\(UUID().uuidString)"))
        let recorder = DefaultsWordMarkCapabilityRecorder(defaults: defaults)
        let pane = RecordedWordMarkCapability(defaults: defaults)
        #expect(pane.wordMarks(for: "com.apple.Notes") == .unavailable)
        recorder.record("com.apple.Notes", supported: true)
        #expect(pane.wordMarks(for: "com.apple.Notes") == .supported)
        recorder.record("com.apple.Notes", supported: false)
        #expect(pane.wordMarks(for: "com.apple.Notes").tag == "No overlay")
    }

    @Test("a correction shifts the text and the later marks; Keep drops only its mark")
    func sessionEdits() {
        let text = "Mira and Joaquin"
        let marks = UncertaintyMarkMapper.map(source: spans([("mira", 0.3), ("and", 0.9), ("joaquin", 0.2)]), finalText: text).marks
        let s = DestinationMarkSession(bundleID: "com.apple.TextEdit", tier: .overlay, landed: 5..<21, text: text, marks: marks)
        s.corrected(0, with: "Meera")
        #expect(s.landedText == "Meera and Joaquin" && s.landed == 5..<22)
        #expect(s.marks.map(\.text) == ["Joaquin"] && s.marks.first?.range == 10..<17)
        s.kept(1)
        #expect(s.marks.isEmpty && s.phase == .cleared(.kept))
    }
}

// MARK: - Popover and replace

@Suite("S5 — correction popover and range-guarded replace")
struct CorrectionPopoverS5Tests {
    static let mark = UncertainMark(id: 0, kind: .word, range: 17..<21, text: "Mira", heard: "mira", confidence: 0.3,
                                    alternatives: ["Meera", "Myra", "Mera", "Meara"])

    @Test("copy, ≤ 3 alternatives, Keep, Edit…, Remember unchecked")
    func copy() {
        let m = CorrectionPopoverModel(mark: Self.mark, origin: .destination)
        #expect(m.title == "Did you mean “Meera”?")
        #expect(m.detail == "“Mira” was uncertain. Choose a spelling or keep what you said.")
        #expect(m.alternatives == ["Meera", "Myra", "Mera"])
        #expect(m.keepLabel == "Mira · keep")
        #expect(CorrectionPopoverModel.editLabel == "Edit…" && CorrectionPopoverModel.suggestionNote == "Suggested spelling, not certainty")
        #expect(!m.remember && m.offersRemember)
        #expect(m.choose("Meera") == .replace("Meera", remember: false))
        var r = m
        r.remember = true
        #expect(r.choose("Myra") == .replace("Myra", remember: true))
        #expect(m.keep() == .keep && m.dismiss() == .dismiss)
        let bare = CorrectionPopoverModel(mark: UncertainMark(id: 1, kind: .word, range: 0..<4, text: "Mira", heard: "mira", confidence: 0.3),
                                          origin: .preview, position: (2, 3))
        #expect(bare.title == "Review “Mira”" && bare.positionLabel == "2 of 3")
    }

    @Test("Edit…: prefilled, blank does nothing, the same word keeps it")
    func edit() {
        var m = CorrectionPopoverModel(mark: Self.mark, origin: .destination)
        m.startEditing()
        #expect(m.stage == .editing && m.draft == "Mira")
        #expect(m.submitEdit() == .keep)
        m.draft = "   "
        #expect(m.submitEdit() == nil)
        m.draft = " Mīra "
        m.remember = true
        #expect(m.submitEdit() == .replace("Mīra", remember: true))
    }

    @Test("phrases (T05) and missing confidence speak honestly; phrases are not remembered")
    func honesty() {
        let phrase = UncertainMark(id: 0, kind: .phrase, range: 0..<13, text: "a fast auburn", heard: "the quick brown", confidence: 0.3)
        var m = CorrectionPopoverModel(mark: phrase, origin: .preview)
        m.remember = true
        #expect(m.title == "Review this phrase" && m.detail == RecoveryCatalog.entry(.T05).consequence)
        #expect(!m.offersRemember && m.choose("x") == .replace("x", remember: false))
        let none = CorrectionPopoverModel(mark: Self.mark, origin: .preview, confidenceAvailable: false)
        #expect(none.detail == "Confidence unavailable")
    }

    @Test("D10 inside the popover: the text has changed; Copy correction copies once")
    func textChanged() {
        var m = CorrectionPopoverModel(mark: Self.mark, origin: .destination)
        m.textChanged(replacement: "Meera")
        #expect(m.title == "The text has changed" && m.detail == "Your correction has not replaced anything.")
        #expect(m.copyCorrectionLabel == "Copy correction")
        #expect(m.copyCorrection() == "Meera")
        #expect(m.stage == .textChanged(replacement: "Meera", copied: true))
    }
}

/// An in-memory field with the ReplaceRange rule: replace only when the range still reads `expected`.
final class MemoryEditor: MarkTextEditing {
    var document: String
    var available = true
    var requests: [(Range<Int>, String, String)] = []
    init(_ document: String) { self.document = document }

    func replace(range: Range<Int>, expected: String, with replacement: String) -> ReplaceRangeOutcome {
        requests.append((range, expected, replacement))
        guard available else { return .unavailable(reason: "no AX") }
        guard MarkWords.slice(document, range) == expected else { return .mismatch(actual: MarkWords.slice(document, range)) }
        var units = Array(document.utf16)
        units.replaceSubrange(range, with: Array(replacement.utf16))
        document = String(decoding: units, as: UTF16.self)
        return .replaced(verified: true)
    }
}

final class MemorySpelling: SpellingMemory {
    var remembered: [(String, String)] = []
    func remember(heard: String, spelling: String, audioRange: ClosedRange<TimeInterval>) { remembered.append((heard, spelling)) }
}

final class MemoryClipboard: CorrectionClipboard {
    var copied: [String] = []
    func copy(_ text: String) { copied.append(text) }
}

@Suite("S5 — range-guarded replace")
struct RangeGuardedReplaceTests {
    func setup(_ document: String = "Dear team Mira and Joaquin") -> (DestinationMarkSession, MemoryEditor, MemorySpelling, WordCorrectionApplier) {
        let text = "Mira and Joaquin"
        let marks = UncertaintyMarkMapper.map(source: spans([("mira", 0.3), ("and", 0.9), ("joaquin", 0.2)]), finalText: text).marks
        let session = DestinationMarkSession(bundleID: "com.apple.TextEdit", tier: .overlay, landed: 10..<26, text: text, marks: marks)
        let editor = MemoryEditor(document), spelling = MemorySpelling()
        return (session, editor, spelling, WordCorrectionApplier(editor: editor, spelling: spelling))
    }

    @Test("the original range still matches: replaced, later marks shift, nothing else touched")
    func replaces() throws {
        let (session, editor, spelling, applier) = setup()
        let mira = try #require(session.marks.first)
        #expect(applier.apply(.replace("Meera", remember: false), mark: mira, in: session) == .replaced(verified: true))
        #expect(editor.document == "Dear team Meera and Joaquin")
        #expect(spelling.remembered.isEmpty, "unchecked: nothing goes to the lexicon")
        let joaquin = try #require(session.marks.first)
        #expect(applier.apply(.replace("Joachim", remember: true), mark: joaquin, in: session) == .replaced(verified: true))
        #expect(editor.document == "Dear team Meera and Joachim")
        #expect(spelling.remembered.map(\.1) == ["Joachim"] && spelling.remembered.first?.0 == "joaquin")
        #expect(session.phase == .cleared(.corrected))
    }

    @Test("the text changed: D10, nothing replaced, the stale range invalidated")
    func mismatch() throws {
        let (session, editor, _, applier) = setup("Dear team Myra and Joaquin")
        let mira = try #require(session.marks.first)
        let result = applier.apply(.replace("Meera", remember: false), mark: mira, in: session)
        #expect(result == .textChanged(replacement: "Meera") && result.recovery?.id == .D10)
        #expect(editor.document == "Dear team Myra and Joaquin")
        #expect(session.phase == .cleared(.textChanged))
    }

    @Test("Keep and dismiss never write")
    func keepAndDismiss() throws {
        let (session, editor, _, applier) = setup()
        let mira = try #require(session.marks.first)
        #expect(applier.apply(.dismiss, mark: mira, in: session) == .dismissed)
        #expect(applier.apply(.keep, mark: mira, in: session) == .kept)
        #expect(editor.requests.isEmpty && session.marks.map(\.text) == ["Joaquin"])
    }

    @Test("the live editor replaces only in the field the text landed in")
    func focusedFieldEditor() {
        let system = MockSystemAccess()
        system.field = .init(value: "Dear team Mira and Joaquin")
        let editor = FocusedFieldMarkEditor(system: system, landedIn: system.frontmost)
        #expect(editor.replace(range: 10..<14, expected: "Mira", with: "Meera") == .replaced(verified: true))
        #expect(system.field.value == "Dear team Meera and Joaquin")
        #expect(editor.replace(range: 10..<14, expected: "Mira", with: "Myra") == .mismatch(actual: "Meer"))
        system.frontmost = FocusSnapshot(pid: 100, bundleID: "com.apple.TextEdit", appName: "TextEdit", elementToken: "el-2")
        if case .unavailable = editor.replace(range: 10..<15, expected: "Meera", with: "Mira") {} else { Issue.record("another field") }
        system.frontmost = FocusSnapshot(pid: 7, bundleID: "com.apple.mail", appName: "Mail", elementToken: "el-1")
        if case .unavailable = editor.replace(range: 10..<15, expected: "Meera", with: "Mira") {} else { Issue.record("another app") }
        #expect(system.field.value == "Dear team Meera and Joaquin")
    }

    @Test("“Remember this spelling” goes to the correction log as a word-review record")
    func rememberRecord() {
        final class Sink: CorrectionSink, @unchecked Sendable {
            var records: [CorrectionRecord] = []
            func record(_ correction: CorrectionRecord) { records.append(correction) }
        }
        let sink = Sink()
        let memory = CorrectionLogSpellingMemory(sink: sink)
        memory.remember(heard: "mira", spelling: "Meera", audioRange: 0...1)
        memory.remember(heard: "Meera", spelling: "Meera", audioRange: 0...1)
        #expect(sink.records.count == 1)
        #expect(sink.records.first?.original == "mira" && sink.records.first?.corrected == "Meera" && sink.records.first?.source == "wordReview")
    }

    @Test("choices in the preview are staged; the last one per word wins; dismiss changes nothing")
    func staged() {
        var s = StagedCorrections()
        s.record(.replace("Meera", remember: false), for: 0)
        s.record(.dismiss, for: 1)
        s.record(.keep, for: 2)
        s.record(.replace("Myra", remember: true), for: 0)
        #expect(s.resolved == [0, 2])
        #expect(s.decisions.map(\.0) == [0, 2])
        #expect(s.decisions.first?.1 == .replace("Myra", remember: true))
    }
}

// MARK: - Coordinator

final class FakeDwell {
    var log: [String] = []
    func pauseDwell(_ reason: DwellPause) { log.append("pause.\(reason.rawValue)") }
    func resumeDwell(_ reason: DwellPause) { log.append("resume.\(reason.rawValue)") }
    func resetDwell() { log.append("reset") }
}

final class FakeDestination: MarkDestinationReading {
    var front: FocusSnapshot?
    var field: ScriptedField
    var caret: Int?
    init(bundle: String, value: String) {
        front = FocusSnapshot(pid: 42, bundleID: bundle, appName: "App", elementToken: "el")
        field = ScriptedField(value)
        caret = value.utf16.count
    }
    func frontmost() -> FocusSnapshot? { front }
    func landedField(pid: Int32) -> LandedField? { LandedField(geometry: field, value: field.value, caret: caret) }
}

final class FakeTracker: DestinationMarkTracking {
    let session: DestinationMarkSession
    let geometry: MarkGeometrySource
    let recorder: WordMarkCapabilityRecording?
    var onCleared: ((MarkClearReason) -> Void)?
    var started = false
    init(_ session: DestinationMarkSession, _ geometry: MarkGeometrySource, _ recorder: WordMarkCapabilityRecording?) {
        self.session = session
        self.geometry = geometry
        self.recorder = recorder
    }
    func start() { started = true; revalidate() }
    func stop() { started = false }
    @discardableResult func revalidate() -> DestinationMarkSession.Phase {
        let phase = session.revalidate(geometry)
        if let v = WordMarkCapabilityPolicy.verdict(for: phase, tier: session.tier) { recorder?.record(session.bundleID, supported: v) }
        if case .cleared(let reason) = phase { stop(); onCleared?(reason) }
        return phase
    }
}

final class MemoryRecorder: WordMarkCapabilityRecording {
    var records: [String: Bool] = [:]
    func record(_ bundleID: String, supported: Bool) { records[bundleID] = supported }
}

@Suite("S5 — word review through the turn")
struct WordMarksCoordinatorTests {
    static let text = "Can we meet with Mira on Friday?"
    static let finalSpans = spans([("can", 0.9), ("we", 0.9), ("meet", 0.9), ("with", 0.9), ("mira", 0.3), ("on", 0.9), ("friday", 0.9)])
        .enumerated().map { i, s in
            var s = s
            if i == 4 { s.alternates = [Alternate(text: "Meera", score: 0.5, source: .beam)] }
            return s
        }

    final class Harness {
        final class Box { var trackers: [FakeTracker] = []; var notices: [RecoveryID] = [] }

        let pill: PillViewModel
        let dwell: FakeDwell
        let destination: FakeDestination
        let editor: MemoryEditor
        let clipboard: MemoryClipboard
        let spelling: MemorySpelling
        let recorder: MemoryRecorder
        let store: TurnStore
        let box: Box
        let coordinator: WordMarksCoordinator

        /// `recordText`: the payload as the turn record stores it (A6: it may carry the continuation
        /// space the delivery row does not).
        init(bundle: String = "com.apple.Notes", fieldPrefix: String = "Dear team ",
             recordText: String = WordMarksCoordinatorTests.text) {
            let value = fieldPrefix + WordMarksCoordinatorTests.text
            let pill = PillViewModel(), dwell = FakeDwell()
            let destination = FakeDestination(bundle: bundle, value: value), editor = MemoryEditor(value)
            let clipboard = MemoryClipboard(), spelling = MemorySpelling(), recorder = MemoryRecorder()
            let store = TurnStore(database: nil), box = Box()
            let coordinator = WordMarksCoordinator(
                pill: pill,
                ladder: WordMarkLadder(ownBundleID: "com.voiceplus.app"), recorder: recorder,
                destination: destination, spelling: spelling, clipboard: clipboard, store: store,
                makeEditor: { _ in editor },
                makeTracker: { session, geometry, c in
                    let t = FakeTracker(session, geometry, c.recorder)
                    box.trackers.append(t)
                    return t
                },
                notice: { entry in box.notices.append(entry.id) })
            coordinator.fallbackAnchor = { CGRect(x: 1, y: 2, width: 3, height: 4) }
            coordinator.bind()
            pill.onDraftPause = { reason, paused in
                if paused { dwell.pauseDwell(reason) } else { dwell.resumeDwell(reason) }
            }
            pill.onApplyDraft = { [weak pill] text, mapping, spans in
                pill?.present(.finalPreview(FinalPreviewInfo(text: text, uncertainCount: mapping.count, dwellRemaining: 0.6)))
                return true
            }
            pill.onLearnDraft = { before, after in spelling.remember(heard: before, spelling: after, audioRange: 0...0) }
            store.save(TurnRecord(finalText: recordText, uncertainSpans: [utf16(recordText, of: "Mira")]), stage: .landed)
            self.pill = pill; self.dwell = dwell
            self.destination = destination; self.editor = editor; self.clipboard = clipboard; self.spelling = spelling
            self.recorder = recorder; self.store = store; self.box = box; self.coordinator = coordinator
        }

        func preview() {
            pill.setFinalSpans(WordMarksCoordinatorTests.finalSpans)
            pill.present(.finalPreview(FinalPreviewInfo(text: WordMarksCoordinatorTests.text, uncertainCount: 1, dwellRemaining: 1.8)))
        }

        func land() {
            pill.present(.landed(LandedPillInfo(text: WordMarksCoordinatorTests.text, verified: true)))
        }
    }

    @Test("clicking a preview word opens the same notch editor without a popover")
    func openFromPreview() throws {
        let h = Harness()
        h.preview()
        h.pill.reviewMark(0)
        #expect(h.pill.isEditingDraft && h.pill.editingMarkID == 0)
        #expect(h.dwell.log == ["pause.editing", "pause.review"])
        h.pill.cancelDraftEdits()
        #expect(!h.pill.isEditingDraft)
        #expect(h.pill.marks(for: .final(Self.text)).count == 1)
    }

    @Test("ending preview also ends the inline editor")
    func previewEndsUnderReview() {
        let h = Harness()
        h.preview()
        h.pill.perform(.editDraft)
        #expect(h.pill.isEditingDraft)
        h.pill.present(.cancelled)
        #expect(!h.pill.isEditingDraft)
    }

    @Test("a visible suggestion revises the preview without a post-insert staging write")
    func stagedChoiceLands() throws {
        let h = Harness()
        h.preview()
        h.pill.acceptSuggestion(markID: 0, replacement: "Meera")
        #expect(h.pill.actionText == "Can we meet with Meera on Friday?")
        #expect(h.pill.markMapping(for: h.pill.actionText).isEmpty)
        #expect(h.editor.document == "Dear team " + Self.text)
        #expect(h.spelling.remembered.count == 1)
    }

    @Test("canceling a correction neither stages a write nor learns a spelling")
    func stagedChoiceStale() {
        let h = Harness()
        h.preview()
        h.pill.reviewMark(0)
        h.pill.draftText = "Can we meet with Meera on Friday?"
        h.pill.cancelDraftEdits()
        #expect(h.pill.actionText == Self.text)
        #expect(h.spelling.remembered.isEmpty)
    }

    @Test("landed in a validated app: the overlay shows, the app is recorded as supported, a click reviews in place")
    func overlayAndDestinationCorrection() throws {
        let h = Harness()
        h.preview()
        h.land()
        let tracker = try #require(h.box.trackers.first)
        #expect(tracker.started && tracker.session.phase.fragments.count == 1)
        #expect(h.recorder.records == ["com.apple.Notes": true])

        let later = Date().addingTimeInterval(5)
        h.pill.now = { later }   // the inserted row's 650 ms have passed
        h.pill.hide()
        h.coordinator.openDestination(0, box: CGRect(x: 5, y: 5, width: 20, height: 20))
        #expect(h.pill.isEditingDraft)
        #expect(h.pill.state == .correcting, "R0 while the notch edits the word")
        h.pill.draftText = "Meera"
        #expect(h.pill.applyDraftEdits())
        #expect(h.editor.document == "Dear team Can we meet with Meera on Friday?")
        #expect(h.pill.state == .hidden)
        #expect(tracker.session.phase == .cleared(.corrected))
        #expect(h.store.recent(limit: 1).first?.record.uncertainSpans == [])
    }

    @Test("a correction after the text changed shows D10 in the popover and offers the copy")
    func destinationTextChanged() throws {
        let h = Harness()
        h.preview()
        h.land()
        h.editor.document = "edited"
        h.coordinator.openDestination(0, box: .zero)
        h.pill.draftText = "Meera"
        #expect(!h.pill.applyDraftEdits())
        #expect(h.pill.isEditingDraft && h.pill.laneNote?.contains("text has changed") == true)
        #expect(h.editor.document == "edited")
    }

    @Test("an app off the ladder: no overlay, D09 once, marks kept in Review / Today")
    func unavailableApp() {
        let h = Harness(bundle: "com.google.Chrome")
        h.preview()
        h.land()
        #expect(h.box.trackers.isEmpty && h.box.notices == [.D09])
        #expect(h.store.recent(limit: 1).first?.record.uncertainSpans == [utf16(Self.text, of: "Mira")])
        h.preview()
        h.land()
        #expect(h.box.notices == [.D09], "once per app per session")
        #expect(h.recorder.records.isEmpty, "never promised for an app nobody validated")
    }

    @Test("a validated app whose rectangles cannot be trusted: D09 and recorded as not supported")
    func noGeometry() {
        let h = Harness()
        h.destination.field.autoRects = false
        h.preview()
        h.land()
        #expect(h.box.notices == [.D09] && h.recorder.records == ["com.apple.Notes": false])
    }

}

// MARK: - A6 — the ranges index the stored text

/// A6 (investigation 2026-10-06, "Uncertainty offsets are misaligned"): `TurnRecord.uncertainSpans`
/// are UTF-16 ranges of `TurnRecord.finalText` exactly as stored, continuation whitespace included.
/// The owner's rows (`" Place two"` → `[1..<6]`, `" it's all right."` → `[6..<9, 10..<15]`) read as
/// `P⟦lace ⟧two.` only when the ranges are applied to `rawText`; against the stored text they are
/// the words. The coordinator keeps that true when the delivery row carries the payload trimmed.
@Suite("A6 — uncertain spans index the stored text")
struct UncertainSpanOffsetsA6Tests {
    /// The owner's turn as recorded: the engine's spans, the stored payload and raw text.
    static let placeTwoSpans = [
        span("Place", 0.339, at: 0, alternates: [Alternate(text: "Rlace", score: 0.077, source: .beam),
                                                 Alternate(text: "Prace", score: 0.063, source: .beam)]),
        span("two.", 0.627, at: 0.3),
    ]
    static let placeTwoStored = " Place two"
    static let placeTwoRaw = "Place two."

    static let allRightSpans = spans([("It's", 0.9), ("all", 0.3), ("right.", 0.4)])
    static let allRightStored = " it's all right."
    static let allRightRaw = "It's all right."

    @Test("“ Place two”: the mark is 1..<6 of the stored text — “Place”, after the continuation space")
    func placeTwo() throws {
        let mapping = UncertaintyMarkMapper.map(source: Self.placeTwoSpans, finalText: Self.placeTwoStored)
        #expect(mapping.uncertainRanges == [1..<6])
        #expect(MarkWords.slice(Self.placeTwoStored, 1..<6) == "Place")
        #expect(UncertainSpans.index(mapping.uncertainRanges, in: Self.placeTwoStored))
        #expect(UncertainSpans.marked(Self.placeTwoStored, spans: mapping.uncertainRanges) == " ⟦Place⟧ two")
        // The investigation's rendering: the same ranges applied to the raw text, which they never index.
        #expect(UncertainSpans.marked(Self.placeTwoRaw, spans: mapping.uncertainRanges) == "P⟦lace ⟧two.")
        #expect(!UncertainSpans.index(mapping.uncertainRanges, in: Self.placeTwoRaw), "a drifted range touches a space")
        #expect(UncertainSpans.rebased(mapping.uncertainRanges, from: Self.placeTwoStored, to: "Place two") == [0..<5])
        let mark = try #require(mapping.marks.first)
        #expect(mark.alternatives == ["Rlace", "Prace"], "the decoder's alternates ride along, best first")
    }

    @Test("“ it's all right.”: two marks, both on the stored text; the trailing period stays outside")
    func allRight() {
        let mapping = UncertaintyMarkMapper.map(source: Self.allRightSpans, finalText: Self.allRightStored)
        #expect(mapping.uncertainRanges == [6..<9, 10..<15])
        #expect(mapping.marks.map(\.text) == ["all", "right"])
        #expect(UncertainSpans.index(mapping.uncertainRanges, in: Self.allRightStored))
        #expect(UncertainSpans.marked(Self.allRightStored, spans: mapping.uncertainRanges) == " it's ⟦all⟧ ⟦right⟧.")
        #expect(UncertainSpans.marked(Self.allRightRaw, spans: mapping.uncertainRanges) == "It's a⟦ll ⟧r⟦ight.⟧")
        #expect(UncertainSpans.rebased(mapping.uncertainRanges, from: Self.allRightStored, to: "it's all right.") == [5..<8, 9..<14])
        #expect(UncertainSpans.rebased(mapping.uncertainRanges, from: Self.allRightStored, to: "something else") == nil)
    }

    @Test("“A sixtien z. ”: a trailing continuation space moves nothing; every flagged word is its own mark")
    func trailingSpace() {
        let stored = "A sixtien z. "
        let mapping = UncertaintyMarkMapper.map(source: spans([("A", 0.054), ("sixtien", 0.427), ("z.", 0.365)]), finalText: stored)
        #expect(mapping.uncertainRanges == [0..<1, 2..<9, 10..<11])
        #expect(UncertainSpans.index(mapping.uncertainRanges, in: stored))
        #expect(UncertainSpans.rebased(mapping.uncertainRanges, from: stored, to: "A sixtien z.") == [0..<1, 2..<9, 10..<11])
    }

    @Test("a phrase mark (T05) after a continuation space covers the phrase, not the space")
    func multiWordMark() throws {
        let stored = " a fast auburn fox"
        let mapping = UncertaintyMarkMapper.map(source: spans([("the", 0.9), ("quick", 0.9), ("brown", 0.3), ("fox", 0.9)]),
                                                finalText: stored)
        let mark = try #require(mapping.marks.first)
        #expect(mapping.marks.count == 1 && mark.kind == .phrase)
        #expect(MarkWords.slice(stored, mark.range) == "a fast auburn")
        #expect(mark.range == 1..<14)
        #expect(UncertainSpans.index([mark.range], in: stored))
        #expect(UncertainSpans.rebased([mark.range], from: stored, to: "a fast auburn fox") == [0..<13])
        #expect(UncertainSpans.rebased([mark.range], from: stored, to: "fox") == [], "a slice without the phrase keeps no span")
    }

    @Test("the unit is UTF-16: an emoji before the word counts two, and a slice is rebased by two")
    func utf16Units() throws {
        let stored = " 🎉 mira"
        let mapping = UncertaintyMarkMapper.map(source: spans([("party", 0.9), ("mira", 0.3)]), finalText: stored)
        let range = try #require(mapping.uncertainRanges.first)
        #expect(range == 4..<8 && MarkWords.slice(stored, range) == "mira")
        #expect(UncertainSpans.rebased([range], from: stored, to: "mira") == [0..<4])
        #expect(UncertainSpans.rebased([range], from: stored, to: "🎉 mira") == [3..<7])
    }

    @Test("a delivery row carrying the trimmed payload still clears the stored record's mark")
    func trimmedDeliveryRow() throws {
        let stored = " " + WordMarksCoordinatorTests.text
        let h = WordMarksCoordinatorTests.Harness(recordText: stored)
        h.preview()
        h.land()   // the row's text has no continuation space; the record's does
        #expect(h.store.recent(limit: 1).first?.record.uncertainSpans == [utf16(stored, of: "Mira")])
        h.pill.now = { Date().addingTimeInterval(5) }   // the inserted row's dwell has passed
        h.pill.hide()
        h.coordinator.openDestination(0, box: .zero)
        h.pill.draftText = "Meera"
        #expect(h.pill.applyDraftEdits())
        #expect(h.store.recent(limit: 1).first?.record.uncertainSpans == [])
    }

    @Test("the remaining mark is written in the stored text's offsets, not the row's")
    func remainingMarkOffsets() throws {
        let text = WordMarksCoordinatorTests.text
        let stored = " " + text
        let h = WordMarksCoordinatorTests.Harness(recordText: stored)
        let twoMarks = spans([("can", 0.9), ("we", 0.9), ("meet", 0.3), ("with", 0.9), ("mira", 0.3), ("on", 0.9), ("friday", 0.9)])
        h.pill.setFinalSpans(twoMarks)
        h.pill.present(.finalPreview(FinalPreviewInfo(text: text, uncertainCount: 2, dwellRemaining: 1.8)))
        h.land()
        let session = try #require(h.box.trackers.first?.session)
        #expect(session.marks.map(\.text) == ["meet", "Mira"])
        h.pill.now = { Date().addingTimeInterval(5) }   // the inserted row's dwell has passed
        h.pill.hide()
        h.coordinator.openDestination(1, box: .zero)
        h.pill.draftText = "Meera"
        #expect(h.pill.applyDraftEdits())
        let ranges = try #require(h.store.recent(limit: 1).first?.record.uncertainSpans)
        #expect(ranges == [utf16(stored, of: "meet")] && ranges == [8..<12])
        #expect(UncertainSpans.index(ranges, in: stored))
        #expect(UncertainSpans.marked(stored, spans: ranges) == " Can we ⟦meet⟧ with Mira on Friday?")
    }
}
