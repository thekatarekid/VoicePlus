import Foundation
import Testing
import Shared
@testable import Pipeline

/// H7 — one case per deterministic catalogue entry (phrase → result), unknown phrase → LLM route.
/// (id, spoken instruction, selection, expected action)
private let dCases: [(String, String, String, EditCommandAction)] = [
    ("replace.with", "replace this with see you soon", "see you tomorrow", .replaceSelection),
    ("replace.ask", "replace this text", "see you tomorrow", .replaceSelection),
    ("find.replace", "replace Tuesday with Wednesday", "See you Tuesday, not tuesday night.", .rewrite("See you Wednesday, not Wednesday night.")),
    ("find.swap", "swap apples and pears", "apples then pears", .rewrite("pears then apples")),
    ("delete", "delete this", "some text", .delete),
    ("cut", "cut this", "some text", .cut),
    ("copy", "copy this", "some text", .copy),
    ("insert.before", "add Hi Sam before this", "thanks for the notes", .rewrite("Hi Sam thanks for the notes")),
    ("insert.after", "append see you then", "Meeting at 3.", .rewrite("Meeting at 3. see you then")),
    ("wrap.quotes", "put this in quotes", "hello", .rewrite("\"hello\"")),
    ("wrap.singleQuotes", "put it in single quotes", "hello", .rewrite("'hello'")),
    ("wrap.brackets", "put this in brackets", "note", .rewrite("[note]")),
    ("wrap.parentheses", "put this in parentheses", "aside ", .rewrite("(aside) ")),
    ("wrap.braces", "wrap it in curly braces", "x", .rewrite("{x}")),
    ("wrap.backticks", "wrap in backticks", "npm test", .rewrite("`npm test`")),
    ("case.upper", "make this all caps", "ship it", .rewrite("SHIP IT")),
    ("case.lower", "lowercase", "HELLO There", .rewrite("hello there")),
    ("case.title", "title case", "the pipeline is the product", .rewrite("The Pipeline Is the Product")),
    ("case.sentence", "sentence case", "HELLO THERE. how ARE you? i am fine", .rewrite("Hello there. How are you? I am fine")),
    ("case.firstLetter", "capitalize the first letter", "hello world", .rewrite("Hello world")),
    ("list.bullets", "make this a bulleted list", "Gather requirements. Prototype. Test with users.",
     .rewrite("- Gather requirements.\n- Prototype.\n- Test with users.")),
    ("list.numbered", "make it a numbered list", "- Open settings\n- Enable it", .rewrite("1. Open settings\n2. Enable it")),
    ("lines.join", "make this one paragraph", "First line.\nSecond line.", .rewrite("First line. Second line.")),
    ("lines.split", "one per line", "Revenue is up. Churn is down.", .rewrite("Revenue is up.\nChurn is down.")),
    ("lines.removeBreaks", "remove line breaks", "a\nb\n\nc", .rewrite("a b c")),
    ("tidy.fillers", "remove filler words", "Um, so the deploy, uh, failed", .rewrite("So the deploy, failed")),
    ("tidy.spacing", "fix spacing", "hello  world ,ok", .rewrite("hello world, ok")),
    ("tidy.trim", "trim", "  hi there \n", .rewrite("hi there")),
    ("tidy.emojis", "remove emojis", "great job 🎉👍🏽 team", .rewrite("great job team")),
    ("tidy.punctuation", "remove punctuation", "Hello, world! Don't stop.", .rewrite("Hello world Don't stop")),
    ("tidy.fullStop", "add a full stop", "See you then", .rewrite("See you then.")),
    ("md.bold", "make this bold", "churn", .rewrite("**churn**")),
    ("md.italic", "make it italic", "churn", .rewrite("*churn*")),
    ("md.heading", "make this a heading", "Overview", .rewrite("# Overview")),
    ("md.strike", "strikethrough", "old", .rewrite("~~old~~")),
    ("md.link", "make this a link", "https://example.com", .rewrite("<https://example.com>")),
    ("md.codeBlock", "make this a code block", "ls ~", .rewrite("```\nls ~\n```")),
    ("undo", "undo that", "some text", .undo),
]

@Suite("H7 — edit-command catalogue")
struct EditCommandCatalogTests {
    @Test("every D entry: phrase → result", arguments: dCases.indices)
    func deterministicEntry(i: Int) throws {
        let (id, phrase, selection, expected) = dCases[i]
        let m = try #require(EditCommandCatalog.match(phrase, selection: selection, surface: .markdownEditor), "\(phrase) did not match")
        #expect(m.entry.id == id, "\(phrase) → \(m.entry.id)")
        #expect(m.entry.kind == .deterministic)
        #expect(m.action == expected, "\(phrase)")
    }

    @Test("the cases cover every deterministic entry exactly")
    func coverage() {
        #expect(Set(dCases.map(\.0)) == Set(EditCommandCatalog.deterministic.map(\.id)))
        #expect(Set(EditCommandCatalog.entries.map(\.id)).count == EditCommandCatalog.entries.count)
        // A phrase belongs to one entry only.
        let phrases = EditCommandCatalog.deterministic.flatMap(\.phrases)
        #expect(Set(phrases).count == phrases.count)
        // Every group is represented; every entry has examples.
        #expect(Set(EditCommandCatalog.entries.map(\.group)) == Set(EditCommandGroup.allCases))
        #expect(EditCommandCatalog.entries.allSatisfy { !$0.examples.isEmpty })
    }

    @Test("objects and politeness variants all parse: this / it / the selection / the text")
    func objectVariants() {
        for p in ["uppercase", "uppercase this", "make it uppercase", "please convert the selection to uppercase",
                  "could you make the text all caps", "Make this uppercase.", "convert to uppercase please"] {
            #expect(EditCommandCatalog.match(p, selection: "ok")?.entry.id == "case.upper", Comment(rawValue: p))
        }
        for p in ["delete this", "remove it", "delete the selection", "get rid of it", "scratch that"] {
            #expect(EditCommandCatalog.match(p, selection: "x")?.action == .delete, Comment(rawValue: p))
        }
        #expect(EditCommandCatalog.match("put it back", selection: "x")?.action == .undo)
        #expect(EditCommandCatalog.match("capitalize this", selection: "hello world")?.action == .rewrite("Hello World"))
    }

    @Test("unknown or model phrases → no deterministic match (LLM route), classified for logs")
    func unknownGoesToLLM() {
        let cases: [(String, String)] = [
            ("make this formal", "tone"), ("make this shorter", "length"), ("translate to Hindi", "translate"),
            ("fix grammar", "quality"), ("simplify this", "explain"), ("turn this into an email", "reshape"),
            ("what does this mean?", "ask"), ("make it sound like a pirate", "freeform"),
            ("make this uppercase and then translate it", "translate"),
        ]
        for (p, id) in cases {
            #expect(EditCommandCatalog.match(p, selection: "Some text here.") == nil, Comment(rawValue: p))
            #expect(EditCommandCatalog.classify(p, selection: "Some text here.").id == id, Comment(rawValue: p))
            #expect(EditCommandCatalog.classify(p).kind == .llm)
        }
    }

    @Test("Markdown commands only on Markdown surfaces")
    func markdownGated() {
        #expect(EditCommandCatalog.match("make this bold", selection: "x", surface: .prose) == nil)
        #expect(EditCommandCatalog.match("make this bold", selection: "x", surface: nil) == nil)
        #expect(EditCommandCatalog.match("make this bold", selection: "x", surface: .markdownEditor)?.entry.id == "md.bold")
    }

    @Test("find-and-replace needs A in the selection; swap needs both; replace-this is H6's replace")
    func argumentGuards() {
        #expect(EditCommandCatalog.match("replace cat with dog", selection: "a bird") == nil)
        #expect(EditCommandCatalog.match("change cat to dog", selection: "Cat food, CAT toy, category")?.action
                == .rewrite("Dog food, DOG toy, category"))
        #expect(EditCommandCatalog.match("swap red and blue", selection: "red only") == nil)
        #expect(EditCommandCatalog.match("replace this with hello", selection: "cat")?.action == .replaceSelection)
        #expect(EditCommandCatalog.match("add thanks at the end", selection: "See you")?.action == .rewrite("See you thanks"))
        #expect(EditCommandCatalog.match("append , thanks", selection: "See you")?.action == .rewrite("See you, thanks"))
    }

    @Test("rules keep edge whitespace and report no change honestly")
    func edgesAndNoChange() {
        #expect(EditCommandRules.rewrite("tidy.fullStop", "Done.") == "Done.")
        #expect(EditCommandRules.rewrite("wrap.quotes", " hi ") == " \"hi\" ")
        #expect(EditCommandRules.rewrite("tidy.emojis", "plain") == "plain")
        #expect(EditCommandRules.rewrite("tidy.fullStop", "wait,") == "wait.")
        #expect(EditCommandRules.rewrite("md.link", "docs") == "[docs]()")
        #expect(EditCommandRules.rewrite("list.bullets", "3.5 percent is fine. Ok.") == "- 3.5 percent is fine.\n- Ok.")
    }

    @Test("the executor runs D commands with no model (source .catalog) and sends L ones to the provider")
    func executorOrder() async throws {
        let provider = ScriptedTransformProvider()
        provider.script["make it formal|hey there"] = "Good day."
        let exec = TransformExecutor(providers: provider)
        let ctx = StageContext()
        let sel = SelectionSnapshot(text: "hey there", range: 0..<9)

        let d = try await exec.execute(TransformRequest(instruction: spans("make this uppercase"), selection: sel, context: ctx), context: ctx)
        #expect(d.output == "HEY THERE" && d.source == .catalog && d.commandID == "case.upper")
        #expect(provider.calls.isEmpty)

        let del = try await exec.execute(TransformRequest(instruction: spans("delete this"), selection: sel, context: ctx), context: ctx)
        #expect(del.output == "" && del.action == .delete && del.replace.resultingRange == 0..<0)

        let l = try await exec.execute(TransformRequest(instruction: spans("make it formal"), selection: sel, context: ctx), context: ctx)
        #expect(l.output == "Good day." && l.source == .provider && l.commandID == "tone")

        var md = ctx
        md.extra[EditCommandCatalog.surfaceKey] = SurfaceKind.markdownEditor.id
        let b = try await exec.execute(TransformRequest(instruction: spans("bold it"), selection: sel, context: md), context: md)
        #expect(b.output == "**hey there**" && b.source == .catalog)
    }
}
