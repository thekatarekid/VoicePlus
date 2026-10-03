import Foundation
import Testing
import Shared
import Engine
import Injection
import Pipeline
@testable import VoicePlusApp

@Suite("P2.3 — transform UX models")
struct TransformUXTests {
    let t0 = Date(timeIntervalSince1970: 10_000)

    @Test func morphTokensFollowDiffAndCollapseThenExpand() {
        let m = MorphAnimationModel(diff: WordDiff.compute(old: "churn was 4 percent", new: "churn was **4%**"))
        #expect(!m.isIdentity && m.changedCount > 0)
        #expect(m.tokens.first?.kind == .kept)
        let removed = m.tokens.first { $0.kind == .removed }!
        let added = m.tokens.first { $0.kind == .added }!
        #expect(m.phase(at: 0) == .collapse && m.phase(at: m.beat / 2) == .expand && m.phase(at: m.beat) == .settled)
        #expect(m.scale(of: removed, at: 0) == 1 && m.scale(of: removed, at: m.beat / 2) == 0)
        #expect(m.scale(of: added, at: 0) == 0 && m.scale(of: added, at: m.beat / 4) == 0 && m.scale(of: added, at: m.beat) == 1)
        #expect(m.scale(of: m.tokens[0], at: 0.1) == 1)
        #expect(m.visibleText(at: 0) == "churn was 4 percent")
        #expect(m.visibleText(at: m.beat) == "churn was **4%**")
        #expect(MorphAnimationModel(diff: WordDiff.compute(old: "a b", new: "a b")).isIdentity)
    }

    @Test func ghostLivesFiveSeconds() {
        let g = TransformGhost(instruction: "bold it", before: "a", after: "**a**", shownAt: t0)
        #expect(g.isAlive(at: t0 + 4.9) && !g.isAlive(at: t0 + 5))
        #expect(g.remaining(at: t0 + 2) == 3 && g.remaining(at: t0 + 9) == 0)
        #expect(g.undoLabel == "↩ undo" && g.tryAgainLabel == "try again")
    }

    @Test func pillInfoHeadlines() {
        #expect(TransformPillInfo(editingWords: 1, stage: .editing).headline == "editing 1 word")
        #expect(TransformPillInfo(editingWords: 12, stage: .editing).headline == "editing 12 words")
        #expect(TransformPillInfo(editingWords: 3, stage: .done(changed: 2)).headline == "changed 2 words")
        #expect(TransformPillInfo(editingWords: 3, stage: .done(changed: 0)).headline == "no change")
        #expect(TransformPillInfo(editingWords: 3, stage: .warm(remaining: 6)).headline == "say more… (6s)")
        #expect(TransformPillInfo(editingWords: 3, stage: .done(changed: 2)).showsGhost)
        #expect(!TransformPillInfo(editingWords: 3, stage: .warm(remaining: 6)).showsGhost)
        #expect(PillState.transform(.init(editingWords: 1, stage: .editing)).caseName == "transform")
        #expect(PillState.transform(.init(editingWords: 1, stage: .editing)).isVisible)
        #expect(NotchGeometry.size(for: .transform(.init(editingWords: 1, stage: .editing))) == NotchGeometry.activeSize)
    }

    @Test func reducerEditingDoneGhostWarmHidden() {
        var r = TransformPillReducer(warmWindow: 8, ghostLifetime: 5)
        #expect(r.reduce(.began(words: 12), now: t0) == .transform(.init(editingWords: 12, stage: .editing)))
        #expect(!r.isWarm)
        let diff = WordDiff.compute(old: "one two three", new: "one\ntwo three")
        let s = r.reduce(.applied(instruction: "make this two lines", before: "one two three", after: "one\ntwo three", diff: diff), now: t0)
        guard case .transform(let info) = s, case .done = info.stage else { Issue.record("expected done, got \(s)"); return }
        #expect(r.ghost?.instruction == "make this two lines" && r.morph != nil && r.isWarm)
        r.reduce(.tick, now: t0 + 4.9)
        #expect(r.ghost != nil)                                   // ghost still up
        r.reduce(.tick, now: t0 + 5.1)
        #expect(r.ghost == nil)                                   // ghost gone, pill warm
        #expect(r.state == .transform(.init(editingWords: 3, stage: .warm(remaining: 3))))
        r.reduce(.tick, now: t0 + 7.9)
        #expect(r.state == .transform(.init(editingWords: 3, stage: .warm(remaining: 1))))
        r.reduce(.tick, now: t0 + 8)
        #expect(r.state == .hidden && !r.isWarm)
    }

    @Test func reducerChainedTurnRestartsWarmWindow() {
        var r = TransformPillReducer()
        let diff = WordDiff.compute(old: "a", new: "b")
        r.reduce(.applied(instruction: "x", before: "a", after: "b", diff: diff), now: t0)
        r.reduce(.tick, now: t0 + 7)
        r.reduce(.began(words: 1), now: t0 + 7)
        #expect(r.state == .transform(.init(editingWords: 1, stage: .editing)) && !r.isWarm && r.ghost == nil)
        r.reduce(.applied(instruction: "y", before: "b", after: "c", diff: diff), now: t0 + 7.5)
        r.reduce(.tick, now: t0 + 14)
        #expect(r.state != .hidden && r.isWarm)
        r.reduce(.tick, now: t0 + 15.5)
        #expect(r.state == .hidden)
    }

    @Test func reducerNoChangeFailedUndoneAndEnded() {
        var r = TransformPillReducer()
        r.reduce(.began(words: 2), now: t0)
        #expect(r.reduce(.noChange, now: t0) == .transform(.init(editingWords: 2, stage: .notice("no change"))))
        r.reduce(.tick, now: t0 + 0.5)
        #expect(r.state == .transform(.init(editingWords: 2, stage: .notice("no change")))) // notice holds ~1 s
        r.reduce(.tick, now: t0 + 2)
        #expect(r.state == .hidden && !r.isWarm, "H9: no 'say more' after no change — the notice just closes")
        #expect(r.reduce(.failed("can't edit here"), now: t0) == .transform(.init(editingWords: 2, stage: .notice("can't edit here"))))
        let diff = WordDiff.compute(old: "a", new: "b")
        r.reduce(.applied(instruction: "x", before: "a", after: "b", diff: diff), now: t0)
        #expect(r.reduce(.undone, now: t0) == .transform(.init(editingWords: 1, stage: .notice("put back"))) && r.ghost == nil)
        #expect(r.reduce(.ended, now: t0) == .hidden && !r.isWarm)
    }

    @Test @MainActor func pillDriverPushesStateGhostAndActions() {
        let pill = PillViewModel()
        let driver = TransformPillDriver(pill: pill)
        var now = t0
        driver.clock = { now }
        var actions: [TransformGhost.Action] = []
        driver.onAction = { actions.append($0) }
        driver.handle(.began(words: 4))
        #expect(pill.state == .transform(.init(editingWords: 4, stage: .editing)))
        driver.handle(.applied(instruction: "bold it", before: "a b", after: "**a b**", diff: WordDiff.compute(old: "a b", new: "**a b**")))
        #expect(pill.ghost?.instruction == "bold it" && pill.morph != nil)
        pill.onGhostAction?(.undo); pill.onGhostAction?(.tryAgain)
        #expect(actions == [.undo, .tryAgain])
        now = t0 + 9
        driver.tick()
        #expect(pill.state == .hidden && pill.ghost == nil)
    }

    @Test func pillViewModelPresentAndEngineOverride() {
        let pill = PillViewModel()
        pill.present(.transform(.init(editingWords: 1, stage: .editing)))
        #expect(pill.state.caseName == "transform")
        pill.apply(.listening(level: 0.3))
        #expect(pill.state == .listening(level: 0.3))
        pill.ghost = TransformGhost(instruction: "x", before: "a", after: "b", shownAt: t0)
        pill.hide()
        #expect(pill.ghost == nil && pill.state == .hidden)
    }

    @Test func transformReplaceSinkMapsInjectionOutcomes() {
        let system = MockSystemAccess()
        system.field = .init(value: "alpha beta gamma", selection: 6..<10)
        let sink = InjectionTransformReplaceSink(system: system)
        #expect(sink.replace(.init(range: 6..<10, expected: "beta", replacement: "BETA")) == .replaced(verified: true))
        #expect(system.field.value == "alpha BETA gamma")
        #expect(sink.replace(.init(range: 6..<10, expected: "beta", replacement: "x")) == .mismatch(actual: "BETA"))
        system.axReadable = false
        #expect(sink.replace(.init(range: 6..<10, expected: "BETA", replacement: "x")) == .unavailable(reason: "AX value unreadable"))
    }

    @Test func selectionDetectorReadsMockField() {
        let system = MockSystemAccess()
        system.field = .init(value: "alpha beta gamma", selection: 6..<10)
        let sel = SystemAccessSelectionDetector(system: system).currentSelection()
        #expect(sel?.text == "beta" && sel?.before == "alpha " && sel?.bundleID == "com.apple.TextEdit")
        system.field.selection = 3..<3
        #expect(SystemAccessSelectionDetector(system: system).currentSelection() == nil)
    }

    @Test @MainActor func snippetsViewModelValidatesAndRoundTrips() {
        let vm = SnippetsViewModel(store: InMemorySnippetStore())
        #expect(vm.save(trigger: "my address", body: "1 Infinite Loop"))
        #expect(vm.snippets.count == 1 && vm.lastError == nil)
        #expect(!vm.save(trigger: "", body: "x") && vm.lastError != nil)
        let id = vm.snippets[0].id
        #expect(vm.save(id: id, trigger: "my address", body: "2 Loop"))
        #expect(vm.snippets.count == 1 && vm.snippets[0].body == "2 Loop")
        vm.delete(id: id)
        #expect(vm.snippets.isEmpty)
    }
}

/// Scripted provider for the transform stage: instruction → output, keyed by instruction substring.
final class ScriptedRewriter: PipelineProviderRouting, @unchecked Sendable {
    var script: [(instruction: String, output: String)] = []
    private(set) var calls = 0
    func isProviderEnabled(for stage: StageID, context: StageContext) -> Bool { stage == .transform }
    func complete(stage: StageID, prompt: String, input: String, context: StageContext) async throws -> String {
        calls += 1
        let instruction = (prompt.components(separatedBy: "INSTRUCTION: ").last ?? "").lowercased()
        guard let hit = script.first(where: { instruction.contains($0.instruction) }) else { throw ProviderRoutingError.unavailable }
        return hit.output
    }
}

@Suite("P2.3 — transform landing + Phase 2 no-keyboard E2E")
struct TransformLandingTests {
    static func spans(_ text: String) -> [TranscriptSpan] {
        text.split(separator: " ").enumerated().map { i, w in TranscriptSpan(text: String(w), confidence: 0.95, audioRange: Double(i)...Double(i + 1)) }
    }

    static func harness(value: String, selection: Range<Int>, script: [(String, String)]) -> (UtteranceLander, TransformLanding, MockSystemAccess, ScriptedRewriter) {
        let system = MockSystemAccess()
        system.field = .init(value: value, selection: selection)
        let provider = ScriptedRewriter(); provider.script = script.map { (instruction: $0.0, output: $0.1) }
        let injector = TextInjector(system: system)
        let session = TransformSession(executor: TransformExecutor(providers: provider), sink: InjectionTransformReplaceSink(system: system))
        let landing = TransformLanding(session: session, detector: SystemAccessSelectionDetector(system: system),
                                       qa: QuestionAnswerStage(answerer: HeuristicAnswerer()), system: system, injector: injector)
        let lander = UtteranceLander(pipeline: PipelineRunner.standard(), injector: injector, system: system, repair: nil, flags: .inMemory(), database: nil)
        lander.transform = landing
        return (lander, landing, system, provider)
    }

    @Test("MockEngine paragraph → three chained voice turns, no keyboard, no re-selection")
    func noKeyboardChain() async throws {
        let engine = MockEngine(fixture: TranscriptFixture(name: "paragraph", spans: [
            .init(text: "Quick update on Q3:", confidence: 0.96, audioStart: 0, audioEnd: 1, delayMs: 0),
            .init(text: "revenue grew 12 percent but churn rose to 4 percent,", confidence: 0.94, audioStart: 1, audioEnd: 3, delayMs: 0),
            .init(text: "mostly from the SMB tier.", confidence: 0.95, audioStart: 3, audioEnd: 4, delayMs: 0),
        ]), delayScale: 0)
        try await engine.start(prewarm: true)
        let dictated = try await engine.stop()
        let paragraph = dictated.joinedText
        #expect(paragraph.contains("churn rose to 4 percent"))

        // The user selects the paragraph once (mock selection); every later turn reuses it.
        let (lander, landing, system, provider) = Self.harness(value: paragraph, selection: 0..<paragraph.utf16.count, script: [
            ("two lines", "Quick update on Q3:\nrevenue grew 12 percent but churn rose to 4 percent, mostly from the SMB tier."),
            ("churn", "Quick update on Q3:\nrevenue grew 12 percent but CHURN ROSE TO 4 PERCENT, mostly from the SMB tier."),
            ("bold", "Quick update on Q3:\nrevenue grew 12 percent but **CHURN ROSE TO 4 PERCENT**, mostly from the SMB tier."),
        ])
        var events: [TransformPillReducer.Event] = []
        landing.onEvent = { events.append($0) }
        let now = Date()
        var clock = now
        landing.clock = { clock }

        let r1 = await lander.land(Self.spans("make this two lines"), startedAt: now, focus: system.frontmost)
        guard case .transformed(.applied)? = r1.transform else { Issue.record("turn 1: \(String(describing: r1.transform))"); return }
        #expect(r1.route == .transform && r1.injection == nil)
        #expect(system.field.value.contains("Q3:\nrevenue"))
        #expect(landing.session.isWarm && landing.session.selection?.range == 0..<system.field.value.utf16.count)
        // H9: the new text stays selected, so the next command edits the result.
        #expect(system.field.selection == 0..<system.field.value.utf16.count)

        clock = now + 3
        let r2 = await lander.land(Self.spans("call out the churn number"), startedAt: clock, focus: system.frontmost)
        guard case .transformed(.applied)? = r2.transform else { Issue.record("turn 2: \(String(describing: r2.transform))"); return }
        #expect(system.field.value.contains("CHURN ROSE TO 4 PERCENT,"))

        clock = now + 6
        let r3 = await lander.land(Self.spans("bold it"), startedAt: clock, focus: system.frontmost)
        guard case .transformed(.applied)? = r3.transform else { Issue.record("turn 3: \(String(describing: r3.transform))"); return }
        #expect(system.field.value == "Quick update on Q3:\nrevenue grew 12 percent but **CHURN ROSE TO 4 PERCENT**, mostly from the SMB tier.")
        #expect(landing.session.turns.count == 3 && provider.calls == 3)
        #expect(system.journal.filter { $0.hasPrefix("key.") }.isEmpty)   // no keystrokes at all

        // Pill saw: editing → applied, three times, with the diff for the morph.
        let begins = events.filter { if case .began = $0 { return true }; return false }.count
        let applied = events.filter { if case .applied = $0 { return true }; return false }.count
        #expect(begins == 3 && applied == 3)
        if case .applied(_, _, _, let diff) = events.last! { #expect(!diff.isIdentity) }

        // Ghost "↩" puts the last turn back.
        #expect(landing.undo()?.succeeded == true)
        #expect(system.field.value.contains("but CHURN ROSE TO 4 PERCENT, mostly"))
        #expect(landing.session.turns.count == 2)

        // H9: undo leaves the restored text selected. Once the caret moves (no selection), speech
        // is plain dictation again.
        #expect(system.field.selection == landing.session.selection?.range)
        system.field.selection = system.field.value.utf16.count..<system.field.value.utf16.count
        clock = now + 20
        let r4 = await lander.land(Self.spans("thanks"), startedAt: clock, focus: system.frontmost)
        #expect(r4.transform == nil && r4.injection?.succeeded == true)
    }

    @Test func noSelectionMeansDictationEvenWithTransformPhrasing() async {
        let (lander, _, system, _) = Self.harness(value: "hello", selection: 5..<5, script: [])
        let r = await lander.land(Self.spans("make this shorter"), startedAt: Date(), focus: system.frontmost)
        #expect(r.transform == nil && r.injection?.succeeded == true)
        #expect(system.field.value.lowercased().contains("make this shorter"))
    }

    @Test func questionOnSelectionTypesAnswerBelowWithoutReplacing() async {
        let text = "Revenue grew 12 percent. Churn rose to 4 percent."
        let (lander, _, system, _) = Self.harness(value: text, selection: 0..<text.utf16.count, script: [])
        let r = await lander.land(Self.spans("how many sentences is this"), startedAt: Date(), focus: system.frontmost)
        guard case .answered(let answer, let outcome)? = r.transform else { Issue.record("expected answer, got \(String(describing: r.transform)) route=\(r.route)"); return }
        #expect(outcome.succeeded && !answer.isEmpty)
        #expect(system.field.value.hasPrefix(text + "\nanswer:"))
    }

    @Test func tryAgainUndoesAndReruns() async {
        let (lander, landing, system, provider) = Self.harness(value: "a b c", selection: 0..<5, script: [("shout", "A B C")])
        _ = await lander.land(Self.spans("shout this"), startedAt: Date(), focus: system.frontmost)
        #expect(system.field.value == "A B C")
        provider.script = [(instruction: "shout", output: "A-B-C")]
        let step = await landing.tryAgain()
        guard case .applied? = step else { Issue.record("expected re-applied, got \(String(describing: step))"); return }
        #expect(system.field.value == "A-B-C" && landing.session.turns.count == 1)
    }

    @Test func uncertainInstructionIsRefusedNotGuessed() async {
        let (lander, landing, system, _) = Self.harness(value: "a b c", selection: 0..<5, script: [("formal", "x")])
        var events: [TransformPillReducer.Event] = []
        landing.onEvent = { events.append($0) }
        var spans = Self.spans("make it formal")
        spans[2].confidence = 0.2
        let r = await lander.land(spans, startedAt: Date(), focus: system.frontmost)
        guard case .transformed(.failed)? = r.transform else { Issue.record("expected failed, got \(String(describing: r.transform))"); return }
        #expect(system.field.value == "a b c")
        // S11: the refusal is the catalogue's T05 ("Review this phrase"); the unheard word goes to the log.
        #expect(events.contains { if case .failed(let why) = $0 { return why == RecoveryCatalog.entry(.T05).headline }; return false })
    }
}
