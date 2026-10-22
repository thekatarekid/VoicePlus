# VoicePlus — the Context Writer plan (2026-10-07, revision 2)

One document. It merges and replaces `VoicePlus_ContextRewrite_Plan.md` and `VoicePlus_TwoModes_Addendum.md`. The findings they rested on stay in `VoicePlus_Investigation_2026-10-06.md` (with its 10-07 correction note).

**Owner direction (10-07):**
- Two modes: **transcribe** (what I said, correct and formatted) and **instruct** (what I meant: compose text or act).
- Best quality, not fastest to build. Claude Code writes the code.
- The Dictionary is a long shot; never rely on it.
- No Anthropic or Gemini models for the hot path (price). Assess the cheap tier: GLM-5.3 Flash, MiMo v2.6 Flash, Muse Spark 1.3, GPT-6 Luna, DeepSeek, Gemma 4.
- Richer context packet; a well-defined output spec per destination; no "type, then replace" deadline UX.
- Investigate, do not decide yet: sending audio to the cloud instead of (or after) local Parakeet.

**Status.** Design and measurements only. No app code changed. In the repo, uncommitted: `tools/correction-bakeoff/` (24 real cases, the candidate prompt, an OpenRouter runner).

---

## 0. Findings this plan rests on (short)

- After recognition nothing ever changed a word of your 84 dictations: the booster is off or harmful, cleanup is off, the refinement pass is off, the repair stage looks only inside the empty input box, and the guard forbids touching uncertain words. (Investigation doc §2.)
- The vocabulary booster **hurts**: 6 changed turns, 4 worse, 0 better. Contact names leak in on chat surfaces ("Code", "Adv", "\*dial").
- "Polish" runs SpeakoFlow Mini 0.8B, never the Qwen 4B you downloaded.
- Local Qwen3.5-4B, neutral prompt, your 24 cases: **4 of 16 fixed, 8 of 8 controls kept, p50 1.05 s**.
- `claude -p` for one sentence: 9.5–19.4 s, and once it mixed its own setup into the text.
- Key release → text today: p50 455 ms, p90 966 ms.
- 70 % of *instruct* is already built (second key, 200 AX actions, agent, consent, connectors) and has never run on your Mac.

---

## 1. Architecture: one Context Writer, two modes

```
key-down ──► packet builder (AX, thread, vocabulary, destination profile)   [parallel with speech]
speech  ──► Parakeet streaming (live preview) ──► sentences as they finish ─┐
                                                                            ▼
                                     Context Writer  mode = transcribe | instruct
                                     backend = cloud (BYOK) | local fine-tune | none
                                                                            ▼
                                     per-change guard (transcribe) / content guard (instruct)
                                                                            ▼
                                     one landing, animated; "then" steps → ActRouter (consent)
```

| | transcribe | instruct |
|---|---|---|
| Input | packet + HEARD (raw 1-best, confidences, alternates) | packet + HEARD as an instruction |
| Output | what you said, correct, in the destination's format | what the field needs: message, command, formula, paragraph; or `kind: act` |
| Guard | each changed region must **sound like** what was heard (G2P distance), or be formatting, or come from alternates / vocabulary / screen with a phonetic match; failing regions revert individually | no acoustic guard; every name, date, number must appear in the instruction or the packet; must address the field, never answer you; `then` steps need consent |
| Latency path | sentence-wise while speaking; one short call after release | one call after release; pill says "writing…" |

**Mode is declared, not guessed** (spec Bet 5): dictation key = transcribe; second key = instruct, and *inside* it the gatekeeper routes compose / act / both. Leading verbs on the dictation key ("reply to…", "write…", "tell him…") are a deterministic escape hatch (setting, default on). Inferred instruct comes later, previewed, with Lab numbers. The second key is unbound today; it becomes the **instruct key** and Settings › Computer use is renamed.

The three instruct examples (Rahul reply → lands unsent, "send" is a confirmed action; terminal → one command typed without Enter, chosen from the real folder listing, destructive patterns confirm; Sheets → formula into the cell, fill-down through a Sheets connector or ⌘D) are unchanged from the addendum and summarised in §3.

**What the booster becomes:** no Contacts, no screen terms. Its detections are passed as `ALT` evidence; they never overwrite the 1-best. H19 repair likewise becomes an evidence pre-pass.

---

## 2. The context packet, v2

Built at key-down from the turn snapshot the app already takes (one AX walk, ~250 ms budget, ≤1,100 nodes, 300 near the caret). Nothing here waits for key-up.

### 2.1 Destination record — richer, AX-sourced (owner Q1)

Today the surface resolver produces a *kind* (`chatComposer`, `emailBody`, `terminal`, `spreadsheetCell`, …) plus field label, window title and document title. That is a label, not a situation. The packet gets a **destination record** per surface, read from the same AX tree, URL and process the app already touches:

| Surface | Fields in the record | Source (exists?) |
|---|---|---|
| Email body / subject | reply or new; **to / cc names**; subject; the quoted message's sender, date and first lines; your signature if visible | AX: recipient tokens, subject field, quoted block (new); Gmail/Outlook web via URL + AX (new) |
| Chat composer | app; channel or DM name; **participants**; last N messages with author and time; whether a thread reply is open | `participants()` exists (contacts-based); message blocks with authors: new |
| AI assistant chat (Claude, ChatGPT, Perplexity) | the last assistant answer (tail), your last prompt, attached file names, the model picker | AX tail exists (`documentTail`); authorship split: new |
| AI agent in a terminal (Claude Code, Codex) | the agent name (foreground process of the tty), its last output tail, the repo path | `ShellContext` has pid/tty/cwd; foreground process name: new |
| Shell prompt | shell, cwd, folder entries, known commands, last command and its output tail | exists (`ShellContext`), output tail: new |
| Code editor | language, file path, symbol under caret, whether caret is in a comment, string or code; nearby identifiers | file path and symbols partly (`codeSymbols`); caret region class: new |
| Document (Docs, Word, Pages, Notion) | title, heading above the caret, paragraph before/after, list depth, style of surrounding text | title + before/after exist; heading/list depth: new |
| Presentation | slide number, which box (title / body / notes), the other boxes' text | new (AX roles differ per app) |
| Spreadsheet | app; active cell address; header row; neighbouring cells' content/formulas; selection range | surface kind exists; cell address/headers: new (Numbers/Excel via AX; Google Sheets limited; connector later) |
| Browser URL bar / search | the site, whether it is a URL or search field | URL host exists |
| Form field | label, placeholder, input type (phone, date, address), neighbouring labels | hints exist |
| Secure field | nothing is read | exists |

Each record is a compact text block (≤ 300 chars) plus the thread/document text (§2.2). Reading rules stay the ones in place: AX only, no screenshots, nothing from secure fields, per-app "contextual reading off" honoured.

### 2.2 Thread and document text

Not only terms (§2.3): the packet carries **text blocks** — the last ~1,500 characters of the thread or document around the caret, with authors where the AX tree gives them. This is what lets the model resolve "him", "the deck", and the subject you are replying to. `documentTail` already reads a bounded tail; the change is to keep it as text in the packet instead of mining it for terms only.

### 2.3 Screen terms: what they are, how they are ranked (owner Q2)

- **What a term is.** From the AX walk, strings are split into tokens; a token is a candidate when it looks like an entity: capitalised, CamelCase or snake_case, contains digits/dots/slashes (paths, versions, URLs), a formula name, or a multi-word capitalised phrase. Common English words are flagged by `CollisionLexicon` (SCOWL on disk). No model: it is a tokenizer plus rules (`CandidateType.infer`, `EntityExtractor`).
- **How they are ranked.** `ContextRubric`, no model either:
  `score = source weight × surface fit × closeness × freshness × evidence − collision penalty`
  - *source weight*: correction 1.0, dictionary 0.9, near-caret 0.8, window 0.5, recent dictation 0.6 (learned per surface by `SourceWeightLearner`);
  - *surface fit*: e.g. shell commands count on a terminal, contacts only on chat/email/name fields;
  - *closeness*: AX distance from the caret — same text node > sibling > elsewhere in the window;
  - *freshness*: decay with age for time-bound sources;
  - *collision penalty*: 0.5 if the term is also a common word, unless evidence is strong.
- **What changes.** Terms stay in the packet only as a **spelling aid**, capped at 40 and ranked as above, because §2.2 now carries the text itself. The LLM does the understanding; the rubric only decides what fits in the budget.

### 2.4 Personal vocabulary matching (owner Q3)

- **Source.** The user's Dictionary (typed terms with spoken forms), confirmed corrections, the learned lexicon from re-dictations (C1), and the mined vocabulary of §8 (screen memory, repos, documents, calendar, full contact names). Contacts: full names only, and only people you actually interact with.
- **Index.** Each term stores its written form, spoken forms (typed, or generated once by the enrichment pass), and phonetic keys: Double Metaphone today (`Engine/Repair/DoubleMetaphone`), G2P phoneme strings proposed (FluidAudio ships G2P).
- **Matching, per dictation, no model.** For each uncertain span (and each 1–4 word window containing one), compute phoneme edit distance to every term's spoken forms. Keep matches under a distance threshold; score = phonetic closeness × term frequency × recency × source weight. Top 30 go into the packet as `VOCAB` lines, and the top match per span as an `ALT`.
- **Why no LLM here.** The match is a lookup over a few thousand keys and must run in a few milliseconds; the LLM then decides whether a candidate fits the sentence.

### 2.5 Recogniser output (owner Q4)

Agreed. The packet sends the **raw Parakeet 1-best, pre-boost**, with per-word confidence (as `[[ ]]` marks at the 0.5 threshold, after the offset-drift bug is fixed) and per-word top-K alternates from the TDT decoder (`asr_alternatives` already computed). The booster's and H19's outputs are **evidence only** (`ALT: word -> candidate (boost)`), never the base text. Nothing processed is sent *instead of* the original.

### 2.6 Audio to the cloud: cost, latency, pros and cons (owner Q5 — investigation, not a decision)

Two different things are being compared:

**(a) Audio + context to an audio-capable LLM** (one pass does recognition and correction):

| Model (OpenRouter) | Audio price | Est. cost per 10 s dictation | Notes |
|---|---|---|---|
| xiaomi/mimo-v2.6-flash | not priced separately (assume text rate 0.14/M) | ~$0.0002 with packet | observed p50 1.5–3.9 s on text today |
| qwen/qwen3.8-omni-flash | not priced separately (0.15/M) | ~$0.0003 | no latency stats scraped yet |
| google/gemini-3.5-flash-lite | $0.30/M audio tokens (~32 tokens/s) | ~$0.0001 + packet | excluded by price policy for the hot path; useful as a reference |
| mistralai/voxtral-small-24b | $0.0001 per audio unit (per second, per the listing) | ~$0.001 | audio-first model, 24B |

Latency: 10 s of speech as Opus is ~30 KB, so upload is negligible; ~300–500 audio tokens prefill like text. Expect **0.6–1.2 s** after release for the whole answer on a fast endpoint (unmeasured; the bake-off can send the real clips).

**(b) Dedicated cloud STT** (then the text Context Writer as now): AssemblyAI Universal ~$0.0025/min, OpenAI gpt-4o-mini-transcribe ~$0.003/min, Deepgram Nova-3 ~$0.0077/min; streaming variants cost more. At 300 dictations × 10 s a day: **$0.13–0.40/day** for STT alone, versus about **$0.03/day** for (a). Streaming STT gives live partials; batch STT does not.

**Why keep local Parakeet at all?**
- *Live preview while speaking.* The pill and ribbon show text as you talk; only a local streaming model (or a streaming STT API at the higher price) can do that.
- *Sentence-wise early correction* (§4) needs sentence boundaries during speech: that is the local EOU model.
- *Privacy tier and offline.* T3 in the spec is local-first; voice leaving the Mac must be a separate explicit toggle. Many users will never turn it on; the local path must be good on its own.
- *Fallback.* Network hiccup → the local text still lands.
- *Cost of both is small*; the cloud audio tier is additive.

**Why (a) might win where it is allowed:** one model that hears the audio *and* reads the context avoids the error cascade (a text-only corrector can only guess at "sixtien"). On names, numbers and accents it should beat Parakeet-then-LLM. This is what Wispr does.

**Plan:** measure before deciding. The bake-off gains an audio arm: the same 24 cases, real clips, audio-capable models with the packet. Compare fixes, controls, p50/p90 and cost against Parakeet + text correction. Ship whichever wins as the "Cloud: audio" option, with Parakeet kept for preview, offline and the private tier.

---

## 3. Output spec per destination (owner: "needs to be a longer list, well defined")

The destination profile is data (`destinations.json`), rendered into the prompt as a block, and used by the teacher when generating training data. Detection uses the surface resolver, URL host, AX roles and, for terminals, the tty's foreground process.

| Destination | Detected by | Output rules (transcribe) | Instruct adds | Never |
|---|---|---|---|---|
| **Chat message** (Slack, Teams, WhatsApp, iMessage, Discord) | app id; chat composer role | Sentence case; light punctuation (no full stop on a one-liner); contractions kept; emoji only if dictated; line breaks only at "new line"; numerals for numbers ≥ 10, times and money | reply drafted in the channel's register, addressed by first name when a DM; no sign-off | greeting on a reply in an existing DM; markdown unless the app renders it |
| **AI assistant chat** (Claude, ChatGPT, Perplexity, Gemini, Claude desktop) | app id or host; composer label "prompt" | Full sentences, proper punctuation; keep every detail and constraint spoken; lists when enumerated ("first… second…") as "1." lines; code identifiers and file names verbatim in backticks when the app renders markdown | the instruction rewritten as a complete, specific prompt (goal, constraints, format wanted) | summarising; dropping qualifiers; answering the question yourself |
| **AI agent CLI in a terminal** (Claude Code, Codex, Aider) | tty foreground process name; prompt pattern | **Prose, not shell**: same rules as AI assistant chat, plain text (no markdown), no trailing period on a one-word reply ("yes") | the instruction as a complete task statement for the agent | shell-command formatting; `cd`-style rewriting |
| **Shell prompt** (zsh, bash, fish) | tty foreground = shell | The command exactly as spoken symbols map (`dash m` → `-m`, `tilde` → `~`); no capitalisation, no sentence punctuation; first word must be a known command; paths validated against the folder listing | one command line from the intent, chosen from real entries; no Enter | prose; trailing period; inventing a path |
| **Code editor** — code | editor app; caret in code | identifiers in the file's convention (camelCase/snake_case from nearby symbols); spoken operators and brackets; language keywords lowercase | a code snippet in the file's language and style | prose sentences; smart quotes |
| **Code editor** — comment or docstring | caret in comment/string | Sentence case, period at end, wrap width of the file | a comment explaining the intent | code outside the comment |
| **Commit message / PR description** | field label, app (GitHub, Xcode, Tower) | Imperative first line ≤ 72 chars, blank line, body paragraphs; no trailing period on the subject | subject + body from the intent and the visible diff summary | past tense subject |
| **Document** (Docs, Word, Pages, Notion page, Obsidian) | app/host; document body | Paragraphs; sentence case; Oxford comma per persona; numbers: words under 10, numerals above; headings only when dictated as such; lists as the app's list style; keep the surrounding paragraph's style (tense, person) | a paragraph/section in the document's register, matching the heading above | greetings; chat shorthand |
| **Markdown editor / README** | file type `.md` | Markdown: `#` headings, `-` bullets, backticks for code, blank lines between blocks | a section in the file's existing structure | HTML; rich-text artefacts |
| **Presentation** — title box | app; AX role | Title case, ≤ 8 words, no period | a slide title from the intent | sentences |
| **Presentation** — body box | app; AX role | Fragments, one per bullet, ≤ 12 words, parallel grammar, no periods | 3–5 bullets from the intent | paragraphs |
| **Presentation** — speaker notes | app; AX role | Full sentences, paragraphs | notes from the intent | bullets |
| **Spreadsheet cell** | app/host; cell role | A value or short label as spoken; numbers as numerals; `=` formula when dictated as a formula ("equals sum of…") | a formula (`=A2+B2`) from headers and the active cell; fill-down as a confirmed action | sentences; trailing period |
| **Email — subject** | field label | Title-ish case, ≤ 10 words, no period | a subject from the intent and thread | greeting |
| **Email — body (reply)** | reply state from AX/URL | Greeting only if dictated or if the persona says so; paragraphs; proper punctuation; numerals for dates/times; keep the sign-off the persona uses | a reply addressing the quoted mail's points, greeting by first name, persona sign-off | quoting the original; re-stating the subject |
| **Email — body (new)** | compose state | as reply, greeting by default | a full mail: greeting, body, sign-off | — |
| **Browser URL bar / omnibox** | AX role, app | a URL if it sounds like one (`dot com`, `slash`), else a search query: lowercase, no punctuation | the URL or query for the intent ("open the react docs" → `react.dev`) | sentence punctuation |
| **In-app search field** | AX role | query terms only, no punctuation, no filler ("search for" stripped) | query from the intent | sentences |
| **Form field** (name, phone, address, date, OTP) | label/placeholder/input type | the value in the field's format: phone digits grouped, date in the field's pattern, address lines | — | prose; corrections of a name you spelled |
| **Notes / quick capture** (Notes, Apple Reminders, Things) | app | Sentence case; checklists when enumerated; short | a note/task from the intent | greetings |
| **Social post** (X, LinkedIn, Threads) | host | Sentence case; line breaks for beats; within the platform limit; hashtags only if dictated | a post from the intent, in the persona's voice | emoji unless dictated |
| **Calendar event** — title / notes | app, field | Title: Title Case fragment; notes: sentences | event title from intent | — |
| **Secure field** | AX secure role | nothing changes, nothing is read | — | any model call |
| **Unknown** | fallback | sentence case, standard punctuation, paragraphs on long pauses | — | — |

Cross-cutting rules in every profile:
- **Self-corrections** ("tomorrow, no, Sunday") → keep the last; **fillers** removed; **stutters** merged.
- **Spoken formatting** ("new line", "bullet", "quote … end quote", "all caps") applied; everything else literal.
- **Numbers**: the profile decides numerals vs words; units, currency, times, phone numbers, versions always numerals.
- **Names and terms**: written form from vocabulary/screen; otherwise as heard.
- **Language**: the dictated language; code-switched sentences keep both scripts (G3 rules).
- **Persona** (per app, plain English) overrides defaults: sign-off, contractions, Oxford comma, emoji policy.

**Prompt assembly.** `system = core rules (short) + destination profile block + persona block`; `user = DESTINATION record + THREAD/DOC text + VOCAB + HEARD (+ ALT)`, with mode as the first line. The candidate prompt in `tools/correction-bakeoff/system_prompt.txt` becomes the core; profiles are appended per run. The fine-tune (§7) is trained with the same blocks so local and cloud behave alike.

---

## 4. Latency and UX: no deadline, one landing (owner: "the UX will break")

The old "type the rules text at 1.2 s, replace it later" is withdrawn. Text that changes after it lands is the gaslighting the spec warns about. Replacement:

1. **The packet costs nothing at release.** It is built at key-down, in parallel with speech. Sending "audio only, context later" would save a prefill of ~1,500 tokens, which is ~50–100 ms on a cloud endpoint and 3–36 ms measured locally — not where the time goes. The time is the model's own decode and the round trip.
2. **Sentence-wise speculative correction while you speak.** The streaming EOU model marks sentence ends; each finished sentence is corrected immediately with the packet and the corrected earlier sentences. By release, only the last sentence is open. One short call remains.
3. **One landing, animated.** Nothing is typed until the corrected text is ready. The pill shows a "writing…" shimmer, the ribbon flies the finished text in: the animation *is* the wait. Target: text in the field 0.5–0.9 s after release (local 2–4B or a fast cloud endpoint) — comparable to today's 455 ms p50 plus one model call, and far less jarring than a replace.
4. **Audio-first option** (§2.6): where the cloud audio tier is on, the audio of the last open sentence goes up at release in the same call; nothing is faster than one call.
5. **Failure only, not deadline.** If no answer by ~2.5 s (network down, provider stall), the rules text lands with a small "unpolished" mark; a tap or "polish that" retries. Never a silent swap.
6. **Visible, undoable changes.** Words the writer changed shimmer for ~3 s; "undo correction" restores what was heard, and that undo is the strongest learning signal.

Targets: added p50 ≤ 400 ms (cloud) / ≤ 600 ms (local, prefix-cached) over the current 455 ms; p95 under 2.5 s; zero in-place replacements.

---

## 5. Providers: one contract, three backends

| Backend | Status | Use |
|---|---|---|
| **Cloud, bring-your-own-key via OpenRouter** | `OpenAICompatibleClient` exists; defaults stale (`RoutingTable.swift:124`) | the "best" tier; model from §6; provider pinning + fallback list |
| **Local fine-tune** | `LlamaCppProvider` exists | the "private" tier (§7) |
| **Subscriptions** | OAuth/PKCE + CLI adapters exist | see below |

**Subscriptions, honestly.** You asked for both ChatGPT and Claude subscription sign-in regardless. I'll plan what can be planned, and say where it stops:
- **ChatGPT:** "Sign in with ChatGPT" for third-party apps is OpenAI's official programme (DevDay 2026-09-29, limited preview with 16 partners). That is sanctioned: apply, and build behind a flag using the published auth docs (`learn.chatgpt.com/docs/auth`). Using Codex CLI's own tokens from another app is not covered by it.
- **Claude:** Anthropic's Legal & Compliance page states consumer-plan OAuth tokens may only be used in Claude Code and claude.ai; enforcement began January 2026 and completed 2026-04-04, with third-party tools cut off and accounts affected ([The Register](https://www.theregister.com/software/2026/02/20/anthropic-clarifies-ban-on-third-party-tool-access-to-claude/5014546)). That is a ban in all but name, and the open-source tools that did this are the ones that got cut off. I won't design the app around it. The supported paths are an Anthropic API key (usage-billed) or the official Claude Code CLI for slow, explicit jobs — and you have excluded Anthropic models from the hot path anyway.
- Either way, subscriptions remain a poor fit for the per-dictation call (measured 9.5–19.4 s via CLI) and a good fit for explicit "rewrite this", meeting notes, and instruct-mode composing where a second is fine.

Settings shows one control: *Correction: Off · On this Mac (model, measured accuracy, latency) · Cloud (model, provider, data sent in the last hour)* plus a per-app override and a separate "send audio" toggle.

---

## 6. Cloud model shortlist (no Anthropic, no Gemini)

OpenRouter live catalogue, fetched 2026-10-07. Latency = OpenRouter p50 over the last 30 min for the best providers, everyone's traffic (ours is smaller: ~1.5k in, ~80 out). Cost = per dictation at that size; month = 300 dictations/day.

| Model | $/M in → out | per dictation | /month | p50 observed | tok/s | audio | notes |
|---|---|---|---|---|---|---|---|
| **deepseek/deepseek-v4.1-flash** | 0.037 → 1.20 | $0.00015 | ~$1.4 | **0.36–0.52 s** (Together, BaseTen, CoreWeave) | 150–220 | no | huge provider spread (0.36–7 s): pin 2–3 providers |
| **google/gemma-4-26b-a4b-it** (open weights) | 0.076 → 0.255 | $0.00013 | ~$1.2 | **0.20–0.38 s** (Makora, NextBit, CoreWeave) | 53–184 | no | strong per-cost; same family as a possible local E4B |
| **openai/gpt-6-luna** | 0.10 → 0.50 (0.05 → 0.25 flex) | $0.00019 | ~$1.7 | 2.0–2.8 s *as observed* | 66–126 | no | observed traffic is reasoning-heavy; test with `reasoning: none` — likely well under 1 s |
| mistralai/mistral-small-2603 | 0.15 → 0.60 | $0.00027 | ~$2.5 | **0.19–0.41 s** | 87–146 | no | fastest observed; knowledge to verify |
| nvidia/nemotron-3.5-lightning | 0.06 → 0.16 | $0.00010 | ~$0.9 | 0.23 s (CoreWeave), 0.6 s elsewhere | 205 | no | cheap and quick; restraint unknown |
| qwen/qwen3.7-flash | 0.03 → 0.13 | $0.00006 | ~$0.5 | 0.63 s | 93 | no | cheapest; single provider |
| z-ai/glm-5.3-flash | 0.15 → 0.50 | $0.00027 | ~$2.5 | 1.0–3.4 s | 16–47 | no | slow on every provider today |
| xiaomi/mimo-v2.6-flash | 0.14 → 0.28 | $0.00023 | ~$2.1 | 1.5–3.9 s | 18–78 | **yes** | slow today; the cheap audio candidate for §2.6 |
| qwen/qwen3.8-omni-flash | 0.15 → 0.47 | $0.00025 | ~$2.3 | not scraped | — | **yes** | second audio candidate |
| meta/muse-spark-1.3-contributor | 0.10 → 0.20 | $0.00013 | ~$1.2 | 5.7 s | 64 | no | too slow for the hot path |

**Recommendation, pending the bake-off:** default **DeepSeek V4.1 Flash** pinned to its fast providers, with **Gemma 4 26B-A4B** and **GPT-6 Luna (reasoning off)** as the fallback list; Mistral Small and Nemotron Lightning in the run as speed challengers; MiMo and Qwen-Omni for the audio arm. Month cost ~$1–3. `tools/correction-bakeoff/bakeoff.py` now defaults to this set; it picks the model with the most fixes at 8/8 controls, then lowest p90. Run with your key:

```bash
export OPENROUTER_API_KEY=sk-or-...
python3 tools/correction-bakeoff/bakeoff.py --repeat 3 --reasoning none
```

---

## 7. Local tier: purpose-trained model

- **Base:** Qwen3.5-4B (Apache-2.0; runs in the app today; 8/8 restraint; ~1.0 s). **Speed tier:** distil to MiniCPM5-2B or Qwen3.5-2B. **Audio experiment:** Gemma 4 E4B (native audio, ~5 GB at 4-bit) for on-device "re-listen with context".
- **Why fine-tune:** small models are prompt-fragile (4/16 measured); the literature's fix for rare-word correction is synthetic rare-word data + N-best + phonetic context ([arXiv 2505.17410](https://arxiv.org/pdf/2505.17410)); we can generate errors with the app's own recogniser.
- **Data (~200k):** entity-dense dictations per destination (§3 profiles), synthetic screens (entity visible 50 % / sound-alike distractors 30 % / nothing 20 %), verbalised and TTS'd in many accents (Indian English emphasised), mic/noise augmentation, recognised by the shipped Parakeet for HEARD; 55 % with errors, 40 % clean (restraint), 5 % adversarial. **Instruct pairs:** instruction + thread → message; instruction + folder listing → command; instruction + headers → formula; 30 % `kind: act` refusals. Labels by a frontier teacher applying the §3 profiles. Your 250+ recordings are **eval only**.
- **Training:** SFT (LoRA r 64–128, 1–2 epochs; one H100, 4–8 h, $15–40) → DPO/ORPO on over-correction vs correct pairs → Q4_K_M GGUF (and MLX to compare) → ship via llama.cpp with a resident system-prompt KV cache → distil to 2B. Budget ~$100–300 all-in over 3–5 runs.
- **Gates:** fixes ≥ cloud default − 10 pts; clean unchanged ≥ 98 %; answering rate 0; p50 ≤ 600 ms on the M2 Pro.

---

## 8. Vocabulary: for the private long tail

Public names come from the model and the screen; the vocabulary is for what no model knows: colleagues, codenames ("Spool"), repo identifiers, your spellings.

- **Extraction, local, no model:** screen memory (the ~270 terms/turn already read, counted over days; seen 3+ days and not common English → vocabulary), what you write, repos (package/module names, identifiers, README headings, branches, contributors), documents via Spotlight (titles, headings, acronyms, alphanumerics), calendar attendees, Contacts full names you interact with. First scan ~1–3 min for ~20k files, then incremental; 2–5k terms kept, < 5 MB.
- **Enrichment, one batched model call per new term** (cloud flash model, cents; or local overnight): junk filter, type, spoken forms, canonical casing; G2P phonemes for the matcher (§2.4).
- **Internet, background only:** a web-grounded lookup for recurring public-looking terms the model does not know (OpenRouter `:online`, 1–2¢ each).

---

## 9. This Mac

16 GB RAM: budget ~4 GB for VoicePlus models (Parakeet ~1 GB + a 4B Q4 ~3.3 GB resident); a 2B (~1.6 GB) is the comfortable choice; no 8–9B. Free ≥ 20 GB disk (training pilot ~15 GB; delete SpeakoFlow Mini once replaced). Full training on a rented GPU. The cloud tier needs neither.

## 10. Order of work

1. **Context Writer, transcribe mode**: packet v2 (§2), destination profiles (§3), per-change guard, one-landing UX with sentence-wise correction (§4), booster scoped down, A1/A3/A6/C1 from the investigation, cloud backend with the bake-off winner, Lab `context-magic` suite. Fix the uncertain-span offset bug first.
2. **Instruct mode**: instruct key bound and renamed; compose for chat/email and terminal; `then` steps through the existing ActRouter and consent; instruct cases in the Lab suite.
3. **Vocabulary pipeline** (§8).
4. **Local tier** (§7), both modes from the start; gate against the cloud default.
5. **Audio arm** of the bake-off (§2.6); ship "Cloud: audio" if it wins; Sheets connector + fill-down; Gemma 4 E4B local audio experiment.
6. **Speech model housekeeping:** v2 vs v3 replay for English-only; background-speech gating.

## 11. Decisions for the owner

1. **OpenRouter key** for the bake-off (text now; audio arm after).
2. **Instruct key binding:** right ⌘ hold, ⌥ double-tap-and-hold, or other.
3. **Compose on the dictation key** via leading verbs: default on, or instruct key only?
4. **Sheets:** Google Sheets connector (reliable) or AX-only first?
5. **Training budget** ~$100–300 and teacher-generated data; your recordings eval-only.
6. **Vocabulary sources** allowed: screen memory, your dictations, repos, documents, calendar, contacts.
7. **ChatGPT sign-in:** apply to the third-party preview? (Claude subscription sign-in: not planned, see §5.)

---

Sources: OpenRouter model pages and `/api/v1/models` (2026-10-07); [Anthropic third-party OAuth restriction — The Register](https://www.theregister.com/software/2026/02/20/anthropic-clarifies-ban-on-third-party-tool-access-to-claude/5014546); [Sign in with ChatGPT for third-party apps — The New Stack](https://thenewstack.io/sign-in-with-chatgpt/); [STT pricing 2026 — AssemblyAI](https://assemblyai.com/blog/speech-to-text-api-pricing), [Soniox comparison](https://soniox.com/compare/stt/pricing), [convertaudiototext](https://convertaudiototext.com/blog/speech-to-text-api-pricing-2026); [rare-word GER — arXiv 2505.17410](https://arxiv.org/pdf/2505.17410).
