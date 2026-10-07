import Foundation

// Context Writer (plan §3) — the table, row by row, as data. Ids match the list in
// `ContextPacket.Destination.profileID`. The text is what the model reads; the `formatting`
// switches are what the guard reads. Change both together.

extension DestinationProfiles {

    /// Rules that every profile carries (plan §3, "cross-cutting"). Rendered after the profile block.
    public static let crossCuttingRules = """
    In every destination:
    - Self-corrections ("tomorrow, no, Sunday") keep only the last; fillers (um, uh) removed; stutters merged.
    - Spoken formatting ("new line", "bullet", "quote … end quote", "all caps") is applied; everything else is literal.
    - Numbers: the destination decides numerals or words; units, currency, times, phone numbers and versions are always numerals.
    - Names and terms: the written form from VOCAB or TERMS when it sounds like what was heard; otherwise as heard.
    - Language: the dictated language; a code-switched sentence keeps both scripts.
    - PERSONA (the user's own preferences) overrides these defaults: sign-off, contractions, Oxford comma, emoji.
    """

    static let catalog: [DestinationProfile] = [
        DestinationProfile(
            id: "chat.message", title: "Chat message (Slack, Teams, WhatsApp, iMessage, Discord)",
            detection: "app id; chat composer role",
            transcribe: "Sentence case; light punctuation (no full stop on a one-liner); contractions kept; emoji only if dictated; line breaks only at \"new line\"; numerals for numbers from 10, times and money.",
            instruct: "A reply in the channel's register, addressed by first name in a DM; no sign-off.",
            never: "A greeting on a reply in an existing DM; markdown unless the app renders it.",
            formatting: .init(casing: .sentence, terminalPunctuation: .light, lineBreaks: .onlyWhenDictated,
                              numerals: .tenAndAbove, greeting: .never)),
        DestinationProfile(
            id: "ai.chat", title: "AI assistant chat (Claude, ChatGPT, Perplexity, Gemini)",
            detection: "app id or host; composer labelled \"prompt\"",
            transcribe: "Full sentences, proper punctuation; keep every detail and constraint spoken; enumerations (\"first… second…\") as \"1.\" lines; code identifiers and file names verbatim, in backticks when the app renders markdown.",
            instruct: "The instruction rewritten as a complete, specific prompt: goal, constraints, format wanted.",
            never: "Summarising; dropping qualifiers; answering the question yourself.",
            formatting: .init(casing: .sentence, terminalPunctuation: .always, lineBreaks: .paragraphs,
                              numerals: .asSpoken, lists: .numbered, greeting: .never, markdownAllowed: true)),
        DestinationProfile(
            id: "ai.agentCLI", title: "AI agent CLI in a terminal (Claude Code, Codex, Aider)",
            detection: "tty foreground process name; prompt pattern",
            transcribe: "Prose, not shell: full sentences, proper punctuation, every detail kept; plain text, no markdown; no trailing period on a one-word reply (\"yes\").",
            instruct: "The instruction as a complete task statement for the agent.",
            never: "Shell-command formatting; rewriting into cd-style commands.",
            formatting: .init(casing: .sentence, terminalPunctuation: .light, lineBreaks: .onlyWhenDictated,
                              numerals: .asSpoken, greeting: .never)),
        DestinationProfile(
            id: "shell", title: "Shell prompt (zsh, bash, fish)",
            detection: "tty foreground process is the shell",
            transcribe: "The command exactly, with spoken symbols mapped (\"dash m\" → -m, \"tilde\" → ~); no capitalisation, no sentence punctuation; the first word must be a known command; paths validated against the folder listing.",
            instruct: "One command line for the intent, built from real entries; never press Enter.",
            never: "Prose; a trailing period; inventing a path.",
            formatting: .init(casing: .lower, terminalPunctuation: .never, lineBreaks: .none,
                              numerals: .always, greeting: .never)),
        DestinationProfile(
            id: "code.body", title: "Code editor, caret in code",
            detection: "editor app; caret region is code",
            transcribe: "Identifiers in the file's convention (camelCase or snake_case, from nearby symbols); spoken operators and brackets as symbols; language keywords lowercase.",
            instruct: "A code snippet in the file's language and style.",
            never: "Prose sentences; smart quotes.",
            formatting: .init(casing: .fileConvention, terminalPunctuation: .never, lineBreaks: .onlyWhenDictated,
                              numerals: .always, greeting: .never)),
        DestinationProfile(
            id: "code.comment", title: "Code editor, caret in a comment or docstring",
            detection: "caret region is comment or string",
            transcribe: "Sentence case, period at the end, wrapped at the file's width.",
            instruct: "A comment explaining the intent.",
            never: "Code outside the comment.",
            formatting: .init(casing: .sentence, terminalPunctuation: .always, lineBreaks: .onlyWhenDictated,
                              numerals: .tenAndAbove, greeting: .never)),
        DestinationProfile(
            id: "commit", title: "Commit message / PR description",
            detection: "field label; app (GitHub, Xcode, Tower)",
            transcribe: "Imperative first line of at most 72 characters, a blank line, then body paragraphs; no trailing period on the subject.",
            instruct: "Subject and body from the intent and the visible diff summary.",
            never: "A past-tense subject.",
            formatting: .init(casing: .sentence, terminalPunctuation: .never, lineBreaks: .paragraphs,
                              numerals: .always, lists: .bullets, lengthLimit: .characters(72), greeting: .never, markdownAllowed: true)),
        DestinationProfile(
            id: "document", title: "Document (Docs, Word, Pages, Notion page, Obsidian)",
            detection: "app or host; document body",
            transcribe: "Paragraphs; sentence case; Oxford comma per persona; words under ten, numerals from ten; headings only when dictated as such; lists in the app's list style; keep the surrounding paragraph's tense and person.",
            instruct: "A paragraph or section in the document's register, matching the heading above.",
            never: "Greetings; chat shorthand.",
            formatting: .init(casing: .sentence, terminalPunctuation: .always, lineBreaks: .paragraphs,
                              numerals: .tenAndAbove, lists: .appStyle, greeting: .never)),
        DestinationProfile(
            id: "markdown", title: "Markdown editor / README",
            detection: "file type .md",
            transcribe: "Markdown: # headings, - bullets, backticks for code, blank lines between blocks.",
            instruct: "A section in the file's existing structure.",
            never: "HTML; rich-text artefacts.",
            formatting: .init(casing: .sentence, terminalPunctuation: .always, lineBreaks: .paragraphs,
                              numerals: .tenAndAbove, lists: .bullets, greeting: .never, markdownAllowed: true)),
        DestinationProfile(
            id: "slides.title", title: "Presentation, title box",
            detection: "app; AX role of the box",
            transcribe: "Title Case, at most 8 words, no period.",
            instruct: "A slide title from the intent.",
            never: "Sentences.",
            formatting: .init(casing: .title, terminalPunctuation: .never, lineBreaks: .none,
                              numerals: .always, lengthLimit: .words(8), greeting: .never)),
        DestinationProfile(
            id: "slides.body", title: "Presentation, body box",
            detection: "app; AX role of the box",
            transcribe: "Fragments, one per bullet, at most 12 words each, parallel grammar, no periods.",
            instruct: "Three to five bullets from the intent.",
            never: "Paragraphs.",
            formatting: .init(casing: .sentence, terminalPunctuation: .never, lineBreaks: .onlyWhenDictated,
                              numerals: .always, lists: .fragments, lengthLimit: .words(12), greeting: .never)),
        DestinationProfile(
            id: "slides.notes", title: "Presentation, speaker notes",
            detection: "app; AX role of the notes pane",
            transcribe: "Full sentences in paragraphs.",
            instruct: "Speaker notes from the intent.",
            never: "Bullets.",
            formatting: .init(casing: .sentence, terminalPunctuation: .always, lineBreaks: .paragraphs,
                              numerals: .tenAndAbove, greeting: .never)),
        DestinationProfile(
            id: "spreadsheet.cell", title: "Spreadsheet cell",
            detection: "app or host; cell role",
            transcribe: "A value or short label as spoken; numbers as numerals; an = formula when dictated as one (\"equals sum of…\").",
            instruct: "A formula (=A2+B2) from the headers and the active cell; fill-down only as a confirmed action.",
            never: "Sentences; a trailing period.",
            formatting: .init(casing: .asSpoken, terminalPunctuation: .never, lineBreaks: .none,
                              numerals: .always, greeting: .never)),
        DestinationProfile(
            id: "email.subject", title: "Email, subject",
            detection: "field label",
            transcribe: "Title-ish case, at most 10 words, no period.",
            instruct: "A subject from the intent and the thread.",
            never: "A greeting.",
            formatting: .init(casing: .title, terminalPunctuation: .never, lineBreaks: .none,
                              numerals: .always, lengthLimit: .words(10), greeting: .never)),
        DestinationProfile(
            id: "email.body.reply", title: "Email, body of a reply",
            detection: "reply state from AX or URL",
            transcribe: "Greeting only if dictated or if the persona says so; paragraphs; proper punctuation; numerals for dates and times; the sign-off the persona uses.",
            instruct: "A reply addressing the quoted mail's points, greeting by first name, the persona's sign-off.",
            never: "Quoting the original; restating the subject.",
            formatting: .init(casing: .sentence, terminalPunctuation: .always, lineBreaks: .paragraphs,
                              numerals: .tenAndAbove, greeting: .whenDictated)),
        DestinationProfile(
            id: "email.body.new", title: "Email, body of a new message",
            detection: "compose state",
            transcribe: "As a reply, with a greeting by default; paragraphs; proper punctuation; numerals for dates and times; the sign-off the persona uses.",
            instruct: "A full mail: greeting, body, sign-off.",
            never: nil,
            formatting: .init(casing: .sentence, terminalPunctuation: .always, lineBreaks: .paragraphs,
                              numerals: .tenAndAbove, greeting: .byDefault)),
        DestinationProfile(
            id: "browser.urlBar", title: "Browser URL bar / omnibox",
            detection: "AX role; browser app",
            transcribe: "A URL when it sounds like one (\"dot com\", \"slash\"), otherwise a search query: lowercase, no punctuation.",
            instruct: "The URL or query for the intent (\"open the react docs\" → react.dev).",
            never: "Sentence punctuation.",
            formatting: .init(casing: .lower, terminalPunctuation: .never, lineBreaks: .none,
                              numerals: .always, greeting: .never)),
        DestinationProfile(
            id: "search", title: "In-app search field",
            detection: "AX search role",
            transcribe: "Query terms only; no punctuation; filler such as \"search for\" stripped.",
            instruct: "A query from the intent.",
            never: "Sentences.",
            formatting: .init(casing: .lower, terminalPunctuation: .never, lineBreaks: .none,
                              numerals: .always, greeting: .never)),
        DestinationProfile(
            id: "form", title: "Form field (name, phone, address, date, OTP)",
            detection: "label, placeholder, input type",
            transcribe: "The value in the field's format: phone digits grouped, dates in the field's pattern, address lines.",
            instruct: nil,
            never: "Prose; correcting a name the user spelled.",
            formatting: .init(casing: .asSpoken, terminalPunctuation: .never, lineBreaks: .none,
                              numerals: .asSpoken, greeting: .never)),
        DestinationProfile(
            id: "notes", title: "Notes / quick capture (Notes, Reminders, Things)",
            detection: "app",
            transcribe: "Sentence case; checklists when enumerated; short.",
            instruct: "A note or task from the intent.",
            never: "Greetings.",
            formatting: .init(casing: .sentence, terminalPunctuation: .light, lineBreaks: .onlyWhenDictated,
                              numerals: .tenAndAbove, lists: .checklist, greeting: .never)),
        DestinationProfile(
            id: "social", title: "Social post (X, LinkedIn, Threads)",
            detection: "host",
            transcribe: "Sentence case; line breaks for beats; within the platform limit; hashtags only if dictated.",
            instruct: "A post from the intent, in the persona's voice.",
            never: "Emoji unless dictated.",
            formatting: .init(casing: .sentence, terminalPunctuation: .light, lineBreaks: .beats,
                              numerals: .always, lengthLimit: .platform, greeting: .never)),
        DestinationProfile(
            id: "calendar.title", title: "Calendar event, title",
            detection: "app; title field",
            transcribe: "A Title Case fragment, no period.",
            instruct: "An event title from the intent.",
            never: nil,
            formatting: .init(casing: .title, terminalPunctuation: .never, lineBreaks: .none,
                              numerals: .always, greeting: .never)),
        DestinationProfile(
            id: "calendar.notes", title: "Calendar event, notes",
            detection: "app; notes field",
            transcribe: "Sentences.",
            instruct: "Event notes from the intent.",
            never: nil,
            formatting: .init(casing: .sentence, terminalPunctuation: .always, lineBreaks: .paragraphs,
                              numerals: .always, greeting: .never)),
        DestinationProfile(
            id: "secure", title: "Secure field",
            detection: "AX secure role or macOS secure input",
            transcribe: "Nothing changes and nothing is read.",
            instruct: nil,
            never: "Any model call.",
            formatting: .init(casing: .asSpoken, terminalPunctuation: .never, lineBreaks: .none,
                              numerals: .asSpoken, greeting: .never),
            isSecure: true),
        DestinationProfile(
            id: "unknown", title: "Unknown destination",
            detection: "fallback",
            transcribe: "Sentence case, standard punctuation, paragraphs on long pauses.",
            instruct: nil,
            never: nil,
            formatting: .init(casing: .sentence, terminalPunctuation: .always, lineBreaks: .paragraphs,
                              numerals: .tenAndAbove, greeting: .whenDictated)),
    ]
}
