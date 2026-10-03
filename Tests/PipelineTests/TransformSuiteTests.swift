import Foundation
import Testing
import Shared
@testable import Pipeline

/// 60 scripted transform cases: (category, instruction, selection, expected rewrite).
/// The provider mock is scripted; the suite verifies the engine around it — prompt assembly,
/// kind inference, cleanup of model output, diff, provenance/confidence contract, replace request.
private let suite: [(String, String, String, String)] = [
    // tone (15)
    ("tone", "make it more formal", "hey can u send the report asap", "Hello, could you please send the report at your earliest convenience?"),
    ("tone", "make it casual", "I would be grateful if you could review the attached document.", "Mind taking a look at the attached doc?"),
    ("tone", "make it sound friendlier", "Your request is denied.", "Unfortunately we aren't able to approve this one — sorry about that!"),
    ("tone", "make it less aggressive", "You broke the build again. Fix it now.", "Looks like the build broke again — could you take a look when you get a chance?"),
    ("tone", "make it more assertive", "I was wondering if maybe we could possibly move the deadline?", "Let's move the deadline."),
    ("tone", "make it apologetic", "The shipment is late.", "I'm sorry — the shipment is running late."),
    ("tone", "make it professional", "yo the numbers look kinda off", "The figures appear to be inconsistent."),
    ("tone", "warmer please", "Thanks for your message.", "Thank you so much for reaching out!"),
    ("tone", "make it neutral", "This is an absolutely terrible idea.", "This approach has significant drawbacks."),
    ("tone", "make it enthusiastic", "We launched the feature.", "We just launched the feature — so excited for you to try it!"),
    ("tone", "make it polite", "Send me the file.", "Could you please send me the file?"),
    ("tone", "make it firmer", "It might be nice to get this done by Friday if possible.", "This needs to be done by Friday."),
    ("tone", "softer tone", "No. That won't work.", "I don't think that will work, unfortunately."),
    ("tone", "make it sound like a manager wrote it", "fix the tests", "Please prioritise getting the tests green today."),
    ("tone", "make it more confident", "I think this might be the right approach, maybe.", "This is the right approach."),
    // shorten (15)
    ("shorten", "make this shorter", "I just wanted to reach out and let you know that the meeting has been moved to Thursday at 3pm.", "The meeting moved to Thursday at 3pm."),
    ("shorten", "shorten this paragraph", "Due to the fact that the server was under heavy load, response times increased significantly during the peak period.", "Heavy server load slowed responses at peak."),
    ("shorten", "tighten this up", "At this point in time we are not in a position to make a commitment.", "We can't commit yet."),
    ("shorten", "condense this", "Please be advised that the office will be closed on Monday in observance of the public holiday.", "Office closed Monday (public holiday)."),
    ("shorten", "summarize this", "The Q3 report shows revenue up 12%, churn down to 4%, and two new enterprise customers signed in September.", "Q3: revenue +12%, churn 4%, two new enterprise customers."),
    ("shorten", "make it one sentence", "We tested the new flow. Users liked it. Conversion went up.", "Users liked the new flow and conversion went up."),
    ("shorten", "cut it in half", "I am writing to inform you that your application has been received and is currently under review by our team.", "Your application was received and is under review."),
    ("shorten", "be more concise", "In order to be able to proceed we need to first of all get approval.", "We need approval to proceed."),
    ("shorten", "trim the fluff", "So basically what I'm trying to say is that the deploy failed.", "The deploy failed."),
    ("shorten", "make this brief", "Hi everyone, hope you're all doing well. Just a quick reminder that standup is at 9.", "Reminder: standup at 9."),
    ("shorten", "fewer words", "The reason for the delay is that the vendor has not yet shipped the parts.", "Delayed: vendor hasn't shipped the parts."),
    ("shorten", "summarise in five words", "Our migration to the new database finished ahead of schedule with no downtime.", "Database migration done early, zero downtime."),
    ("shorten", "make it a headline", "We are announcing today that VoicePlus now supports Hindi dictation.", "VoicePlus Adds Hindi Dictation"),
    ("shorten", "shorten to a tweet", "After months of work the team has finally released version two of the app, which includes dark mode and offline sync.", "v2 is out: dark mode + offline sync."),
    ("shorten", "make it punchier", "We believe this could potentially lead to improvements.", "This will drive improvements."),
    // restructure (15)
    ("restructure", "turn this into a list", "Bring your laptop, charger, and badge.", "- Laptop\n- Charger\n- Badge"),
    ("restructure", "make this two lines", "Revenue is up 12% and churn dropped to 4% this quarter.", "Revenue is up 12%.\nChurn dropped to 4% this quarter."),
    ("restructure", "convert this to bullet points", "First we gather requirements. Then we prototype. Finally we test with users.", "- Gather requirements\n- Prototype\n- Test with users"),
    ("restructure", "make it a numbered list", "Install the package, run the migration, restart the server.", "1. Install the package\n2. Run the migration\n3. Restart the server"),
    ("restructure", "call out the churn number", "Revenue is up 12%.\nChurn dropped to 4% this quarter.", "Revenue is up 12%.\nChurn: 4% this quarter (down)."),
    ("restructure", "split into paragraphs", "We shipped on time. The launch went well. Next we focus on retention.", "We shipped on time.\n\nThe launch went well.\n\nNext we focus on retention."),
    ("restructure", "put the conclusion first", "We ran the test on Monday. It passed. So we can ship.", "We can ship. We ran the test on Monday and it passed."),
    ("restructure", "add headings", "Overview: a new pill. Details: it tints on transform.", "## Overview\nA new pill.\n\n## Details\nIt tints on transform."),
    ("restructure", "make it steps", "Open settings then enable the hotkey then press it.", "1. Open Settings.\n2. Enable the hotkey.\n3. Press it."),
    ("restructure", "merge into one paragraph", "- Laptop\n- Charger\n- Badge", "Bring your laptop, charger and badge."),
    ("restructure", "reorder by priority", "Fix the typo. Patch the security hole. Update the docs.", "Patch the security hole. Fix the typo. Update the docs."),
    ("restructure", "make it a checklist", "test, review, deploy", "- [ ] Test\n- [ ] Review\n- [ ] Deploy"),
    ("restructure", "turn it into a question", "The meeting is at three.", "Is the meeting at three?"),
    ("restructure", "break it into short sentences", "We met the client and they agreed to the terms but asked for a discount which we declined.", "We met the client. They agreed to the terms. They asked for a discount. We declined."),
    ("restructure", "bold it", "churn dropped to 4%", "**churn dropped to 4%**"),
    // translate / format (15)
    ("translateFormat", "translate this to Hindi", "Good morning, how are you?", "सुप्रभात, आप कैसे हैं?"),
    ("translateFormat", "translate to Spanish", "The meeting is tomorrow.", "La reunión es mañana."),
    ("translateFormat", "translate to French", "Thank you for your help.", "Merci pour votre aide."),
    ("translateFormat", "translate to German", "See you next week.", "Bis nächste Woche."),
    ("translateFormat", "convert to markdown table", "Name: Priya, Role: PM; Name: Sundar, Role: Eng", "| Name | Role |\n|---|---|\n| Priya | PM |\n| Sundar | Eng |"),
    ("translateFormat", "format as json", "name Priya age 31", "{\"name\": \"Priya\", \"age\": 31}"),
    ("translateFormat", "make it csv", "Priya PM\nSundar Eng", "Priya,PM\nSundar,Eng"),
    ("translateFormat", "format as yaml", "host localhost port 8080", "host: localhost\nport: 8080"),
    ("translateFormat", "convert to html", "Hello world", "<p>Hello world</p>"),
    ("translateFormat", "make it a markdown link", "docs at example.com", "[docs](https://example.com)"),
    ("translateFormat", "format as a date", "third of march twenty twenty six", "2026-03-03"),
    ("translateFormat", "write it in title case", "the pipeline is the product", "The Pipeline Is the Product"),
    ("translateFormat", "convert to uppercase", "ship it", "SHIP IT"),
    ("translateFormat", "format as a shell command", "list files in the home folder", "ls ~"),
    ("translateFormat", "translate to Japanese", "Welcome.", "ようこそ。"),
]

@Suite("P2.2 transform suite — 60 scripted cases")
struct TransformSuiteTests {
    static func makeProvider() -> ScriptedTransformProvider {
        let p = ScriptedTransformProvider()
        for (_, instr, sel, out) in suite { p.script["\(instr)|\(sel)"] = out }
        return p
    }

    @Test("all 60 cases: output, kind, diff, provenance, replace request", arguments: suite.indices)
    func runCase(i: Int) async throws {
        let (category, instr, sel, expected) = suite[i]
        let provider = Self.makeProvider()
        let exec = TransformExecutor(providers: provider)
        let selection = SelectionSnapshot(text: sel, range: 10..<(10 + sel.utf16.count), before: "Hi team, ", after: " Thanks.", bundleID: "com.apple.mail", elementToken: "el-1")
        let ctx = StageContext(register: .email, extra: [TransformPreference.contextKey: "bestAvailable", "persona": "short and warm"])
        let request = TransformRequest(instruction: spans(instr), selection: selection, context: ctx)
        let result = try await exec.execute(request, context: ctx)
        // H7 — a deterministic catalogue command runs instantly with no model; the scripted
        // provider is never asked.
        if EditCommandCatalog.match(instr, selection: sel) != nil {
            #expect(result.source == .catalog && provider.calls.isEmpty, "\(instr)")
            return
        }

        #expect(result.output == expected, "\(category): \(instr)")
        #expect(result.source == .provider)
        #expect(request.kind == TransformKind(rawValue: category) ?? .general, "\(instr) inferred \(request.kind)")
        // Prompt carried selection, context and instruction; preference flag was forwarded.
        let call = try #require(provider.calls.first)
        #expect(call.input == sel && call.prompt.contains("<context position=\"before\">\nHi team, ") && call.prompt.hasSuffix("INSTRUCTION: \(instr)"))
        #expect(call.preference == "bestAvailable")
        #expect(request.systemPrompt.contains("short and warm") && request.systemPrompt.contains("email"))
        // Diff reconstructs both sides (morph animation has everything it needs).
        let oldSide = result.diff.ops.compactMap { op -> String? in if case .equal(let w) = op { return w }; if case .delete(let w) = op { return w }; return nil }
        let newSide = result.diff.ops.compactMap { op -> String? in if case .equal(let w) = op { return w }; if case .insert(let w) = op { return w }; return nil }
        #expect(oldSide == WordDiff.tokens(sel) && newSide == WordDiff.tokens(expected))
        #expect(!result.diff.isIdentity)
        // Bet 9: instruction spans keep confidence/audioRange and gain provenance.
        #expect(ConfidenceContract.verify(input: request.instruction, output: result.instructionSpans).isEmpty)
        #expect(result.instructionSpans.allSatisfy { $0.provenance.last == .transform })
        // Replace-range request targets exactly the selection.
        #expect(result.replace == TransformReplaceRequest(range: selection.range, expected: sel, replacement: expected, elementToken: "el-1"))
        #expect(result.replace.resultingRange == 10..<(10 + expected.utf16.count))
    }

    @Test("suite has 60 cases across the four required categories")
    func coverage() {
        #expect(suite.count == 60)
        for c in ["tone", "shorten", "restructure", "translateFormat"] { #expect(suite.filter { $0.0 == c }.count == 15) }
    }

    @Test("model wrapper noise is stripped: quotes, fences, preambles")
    func cleanup() {
        #expect(TransformExecutor.clean("\"Hello there\"") == "Hello there")
        #expect(TransformExecutor.clean("```text\nHello\n```") == "Hello")
        #expect(TransformExecutor.clean("Rewritten: Hello") == "Hello")
        #expect(TransformExecutor.clean("  Here's the rewritten text: Hi  ") == "Hi")
        #expect(TransformExecutor.clean("She said \"hi\" and \"bye\"") == "She said \"hi\" and \"bye\"")
    }

    @Test("low-confidence instruction word → refuse to guess (Bet 9), never rewrite")
    func uncertainInstruction() async {
        let exec = TransformExecutor(providers: Self.makeProvider())
        let selection = SelectionSnapshot(text: "hey can u send the report asap", range: 0..<30)
        let ctx = StageContext()
        let req = TransformRequest(instruction: spans("make it more formal", lowWords: ["formal"]), selection: selection, context: ctx)
        await #expect(throws: TransformError.uncertainInstruction(["formal"])) { try await exec.execute(req, context: ctx) }
    }

    @Test("provider failure or local preference falls back to on-device rules")
    func localFallback() async throws {
        let provider = Self.makeProvider()
        provider.failNext = true
        let exec = TransformExecutor(providers: provider)
        let selection = SelectionSnapshot(text: "So basically I just wanted to say the deploy failed.", range: 0..<52)
        let ctx = StageContext()
        let r = try await exec.execute(TransformRequest(instruction: spans("make this shorter"), selection: selection, context: ctx), context: ctx)
        #expect(r.source == .local && r.output == "So I wanted to say the deploy failed.")

        provider.enabled = false
        let r2 = try await exec.execute(TransformRequest(instruction: spans("turn this into a list"), selection: SelectionSnapshot(text: "Gather requirements. Prototype. Test with users.", range: 0..<48), context: ctx), context: ctx)
        #expect(r2.output == "- Gather requirements.\n- Prototype.\n- Test with users.")
        #expect(provider.calls.count == 1)
    }

    @Test("local rules: numbered, lines, fix casing, uppercase, unknown = unchanged")
    func localRules() {
        let rules = LocalTransformRules()
        func run(_ instr: String, _ text: String) -> String {
            rules.transform(TransformRequest(instruction: spans(instr), selection: SelectionSnapshot(text: text, range: 0..<text.utf16.count), context: StageContext()))
        }
        #expect(run("make it numbered steps", "Open settings. Enable it. Press it.") == "1. Open settings.\n2. Enable it.\n3. Press it.")
        #expect(run("make this two lines", "Revenue is up. Churn is down.") == "Revenue is up.\nChurn is down.")
        #expect(run("fix the grammar", "i think  it works. yes ,it does") == "I think it works. Yes,it does")
        #expect(run("convert to uppercase", "ship it") == "SHIP IT")
        #expect(run("translate this to Hindi", "hello") == "hello")
    }

    @Test("empty selection / empty output are errors, not silent no-ops")
    func emptyCases() async {
        let exec = TransformExecutor(providers: Self.makeProvider())
        let ctx = StageContext()
        await #expect(throws: TransformError.emptySelection) {
            try await exec.execute(TransformRequest(instruction: spans("make it formal"), selection: SelectionSnapshot(text: " ", range: 0..<1), context: ctx), context: ctx)
        }
        struct Blank: LocalTransforming { func transform(_ r: TransformRequest) -> String { "" } }
        let blank = TransformExecutor(providers: LocalOnlyProviderRouting(), local: Blank())
        await #expect(throws: TransformError.emptyOutput) {
            try await blank.execute(TransformRequest(instruction: spans("make it formal"), selection: SelectionSnapshot(text: "x", range: 0..<1), context: ctx), context: ctx)
        }
    }
}

@Suite("P2.2 word diff")
struct WordDiffTests {
    @Test func identity() {
        let d = WordDiff.compute(old: "a b c", new: "a  b\tc")
        #expect(d.isIdentity && d.unchanged == 3 && d.changeRatio == 0)
        let nl = WordDiff.compute(old: "a b", new: "a\nb")
        #expect(!nl.isIdentity && nl.inserted == 1)
    }
    @Test func insertDelete() {
        let d = WordDiff.compute(old: "the quick brown fox", new: "the slow brown fox jumps")
        #expect(d.ops == [.equal("the"), .delete("quick"), .insert("slow"), .equal("brown"), .equal("fox"), .insert("jumps")])
        #expect(d.deleted == 1 && d.inserted == 2 && d.unchanged == 3)
    }
    @Test func fullSwap() {
        let d = WordDiff.compute(old: "x y", new: "p q r")
        #expect(d.changeRatio == 1 && d.unchanged == 0)
        #expect(WordDiff.compute(old: "", new: "a").ops == [.insert("a")])
        #expect(WordDiff.compute(old: "a", new: "").ops == [.delete("a")])
    }
}
