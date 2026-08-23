# The Input Layer — Product Definition

Voice input + modern input + computer use, as one product.

> **v4.** Fact-checked, stress-tested, revised after a reverse-engineering account of Wispr Flow's architecture, then re-phased. Claims that were wrong or overstated are corrected in place and marked ⚠ so the reasoning is auditable.
>
> **Build assumption:** Claude Code builds this, not a human team. Effort and time are not planning inputs anywhere in this document. Phases are sequenced by **user value and quality risk only**. Every phase ships as a signed .dmg a human can install and test that day.

---

## Part 1 — What the research actually shows

### 1.1 The accuracy picture, stated accurately

⚠ *v1 of this doc claimed the whole category hides behind clean-audio benchmarks. That is too strong. Here is the corrected version.*

**Muesli's own evaluation** (issue #330):

| Test audio | Word Error Rate |
|---|---|
| LibriSpeech (clean, read-aloud audiobooks) | **2.3%** |
| Earnings-22 (real people, real calls) | **13.7%** |

Their conclusion, verbatim: *"Clean English is essentially solved; real-world audio is the product gap."*

**Caveats that matter:** n = 40 clips, roughly 800 words per set. The confidence interval is wide. It is one contributor's harness, and it says so.

**And the honest counterpoint:** Aqua's 6.24% is an *Open ASR Leaderboard average*, which already includes Earnings-22, AMI and SPGISpeech. Aqua is not hiding. Their **Avalon 1.5 shipped April 2026 at 5.55% WER, >2× faster.** Wispr publicly announced their noisy-condition numbers rather than concealing them.

**Wispr Flow**, on raising $280M at $2B (Aug 17, 2026), said their Canto model cuts WER *"from over 30% to roughly 5–10% **in difficult conditions such as background noise, wind, and strong accents**."* ⚠ v1 dropped that qualifier and claimed they ship 30% errors generally. That was wrong.

**What survives all of this:**

1. Real-world WER is meaningfully worse than marketed WER, for everyone.
2. The gap is largest exactly where users care most — noise, accents, named entities.
3. The open-source options (Muesli, FluidVoice) are furthest behind on it.
4. The frontier (Aqua, Wispr) is closing it with better models, not better products.

That last point is the opening. **The models are converging. The experience around them has barely been designed.**

### 1.2 Where the errors actually are

Two separate problems, routinely conflated:

**(a) Acoustic errors** — accents, background noise, far-field mics, phone compression, disfluency. This is *most* of the Earnings-22 gap. Muesli's own #1 recommendation was echo cancellation and far-field robustness, not smarter decoding. ⚠ v1 buried this.

**(b) Entity errors** — the words that carry the meaning.
- *"conference call of TeamViewer AG"* → *"team fuel h e"*
- *"GPT-4o"* → *"GPT-400"*, *"Ultrathink"* → *"Ultrathing"*, *"cloudflare"* → *"cloud floor"*

(b) is a smaller share of WER but a **much larger share of felt failure**. 97% of words right with every proper noun destroyed is a 0% useful transcript. Both need fixing. Neither alone is sufficient.

### 1.3 What each product actually is

| Product | Really is | Best idea | Real gap |
|---|---|---|---|
| **Wispr Flow** | Cloud dictation + personalization synced across Mac/Win/iOS/Android | One personalization layer everywhere; "Zero-Edit Rate" as the published metric | Trust damage from the 2025 screenshot incident; quality complaints through 2026 |
| **Aqua Voice** | Their own frontier ASR model (Avalon 1.5), sold as product *and* API | Best measured model; ~450ms; a benchmark built on how developers actually talk | ~3 people, cloud-only, no offline, no HIPAA, ~half of users in one country |
| **FluidVoice** (OSS) | Free local dictation + agentic command mode | Layered injection stack; per-app prompt routing | **No VAD at all**; no streaming injection; core model (Fluid-1) is closed; analytics on by default |
| **Muesli** (OSS) | Local dictation + meeting transcription in one | Honest self-evaluation; agent CLI; genuinely local | Clipboard-paste injection; bus factor of 1; ~2k downloads/release |
| **HeyClicky** | Screen-aware voice agent in the notch that *draws on your screen* | Bidirectional spatial channel — you draw at it, it draws back and verifies your clicks | Cloud; killed its own proactive mode after users got uneasy; "not good at controlling your computer yet" (their words) |
| **SupaMaus** | Local capture layer feeding gesture+speech+screen-text to coding agents over MCP | **Time-aligned gesture-to-speech binding** — solves what "this" and "there" mean | Trapped inside a dev tool; never acts, only feeds |
| **Infina** | On-device dictation + a closed, enumerated voice-command set | The `"type"` / `"send"` / `"Infina"` wake-verb grammar — hands-free with no listening mode | Deliberately refuses open-ended agency |
| **Kivi** (Sarvam) | Dictation + in-place transform, Indic code-switching | Hindi+English in one breath; per-app personas in plain English; **pre-installed on HP India laptops** | Mac only, alpha, no computer control |

### 1.4 The four things nobody has solved

1. **Acoustic robustness.** Noise, accents, far-field, bad mics. The largest real share of error.
2. **Repair.** When it gets a word wrong you reach for the keyboard — and the entire value proposition dies in that instant. **No product in this list lets you fix an error by voice, in flow.**
3. **Endpointing without modes.** Infina names it precisely: *"knowing when you are talking to your Mac, and when you are just talking."* Everyone else dodges it with a hotkey.
4. **Grounding.** Only SupaMaus can resolve "this" and "there" — and only for coding agents.

### 1.5 The tax nobody notices: modes

- Kivi: `fn` = dictate, `fn+⌃` = transform
- Infina: `⌥` = type, `fn` = command, plus a hands-free mode
- HeyClicky: hold / double-tap / triple-tap / `Fn+Ctrl`
- Muesli: hold = dictate, double-tap = hands-free

Each makes **you** classify your own intent before you speak. Some of that classification the machine can do for free. Some of it it cannot. Getting that line right is a design problem, and everyone has drawn it lazily. (See Bet 5.)

### 1.6 How Wispr is actually built — and what it proves

A reverse-engineering account of Wispr Flow's internals reports three things. I checked each against public sources.

| Claim | Verdict |
|---|---|
| **A tiny gatekeeper model runs first** and classifies what you said — message, command, edit — so most speech never touches an expensive model | **Plausible, uncorroborated.** No public confirmation. Consistent with their <700ms end-to-end budget, which does not permit routing every utterance through a large model. |
| **One problem, many models.** Different models for formatting, commands, rewrites, meeting notes | **Corroborated.** Their Baseten case study confirms Llama-based transcript enhancement, and public reporting confirms routing through OpenAI, Anthropic, Cerebras and Fireworks *depending on the feature*. |
| **Dictation is a pipeline, not a model call:** raw transcription → formatting → context rules → your writing style | **Corroborated, and it's the strongest point.** Multiple independent reviews conclude Wispr's accuracy edge "comes from cloud post-processing for context and formatting, not from a fundamentally better transcription model." |

⚠ **But the tweet's fourth claim — "they run their custom ASR, not off-the-shelf Whisper or Parakeet" — is wrong, or at best became true three weeks ago.** Canto, announced Aug 17 2026, is described in Wispr's own materials as their **first** proprietary speech model. Before that, reporting points to a server-side Whisper implementation. They built the pipeline first and the model last.

**And that sequence is the whole lesson.**

Wispr spent years building the most sophisticated post-processing pipeline in the category — gatekeeper routing, per-job models, style matching, 60 billion words of usage data, deployment in nearly every Fortune 500 — and **still had >30% WER in noisy, accented, real-world conditions.** No amount of pipeline fixed it. The fix was Canto: a 2B-parameter model trained specifically for *"loud rooms, windy streets, children in the background, mixed languages."*

So the tweet's conclusion — *"ASR is the easy 90%; routing and personalisation is where the real depth is"* — is **accurate as a description of engineering effort and backwards as a strategy.**

- The pipeline is where most of the *work* is. True.
- The acoustic model is where the *ceiling* is. Also true, and Wispr just paid a fortune to prove it.

⚠ *This vindicates Bet 1 (acoustic robustness) more strongly than v2 argued. It also means v2 badly under-weighted the pipeline. Both layers are load-bearing. New Bets 8 and 9 fix the omission.*

**Useful new benchmark:** Wispr expects Canto to reduce *"the number of dictations needing editing by 30–35%."* That is a zero-edit-rate target stated in the same units as our own counter. It is the number to beat.

---

## Part 2 — The insight

> Every product in this category treats voice as a **faster keyboard**.
> The right product treats voice as **one channel in a fused input system**.

The unit of input is not words. It is **intent, grounded in context**.

- **Voice** supplies the verb — what you want.
- **Pointer / selection** supplies the object — what you mean by "this".
- **Screen state** supplies the referents — who "her" is, what "the deck" is.
- **The system** decides whether the output is text, an edit, or an action.

Call the primitive **the Ask**. You press one key and talk.

### And there are two layers, not one

⚠ *Added in v3. v2 was an ASR-layer document with post-processing as an afterthought. That was a mistake.*

| Layer | What it determines | Who's winning |
|---|---|---|
| **The acoustic layer** — hearing the sounds correctly | The **ceiling**. If this is wrong, nothing downstream recovers. | Aqua (Avalon 1.5), now Wispr (Canto) |
| **The pipeline layer** — turning correct sounds into the right output | The **experience**. Formatting, routing, style, context. Most of the felt quality. | Wispr, by a distance |

The open-source projects are weak at both. Aqua is strong at one. Wispr is strong at one and just bought the other.

**Nobody is strong at both, and nobody has connected them.** That connection — confidence from the acoustic layer flowing *through* the pipeline instead of being discarded at the first step — is Bet 9, and it is the most original idea in this document.

---

## Part 3 — Glossary (plain words)

| Term | Meaning |
|---|---|
| **WER** | Word Error Rate. Percent of words the recogniser gets wrong. |
| **Endpointing** | Deciding the moment you have finished speaking. |
| **VAD** | Voice Activity Detection. Deciding whether a sound is speech. |
| **AEC** | Acoustic Echo Cancellation. Removing the sound your own speakers made. |
| **Far-field** | Speech picked up from across a room rather than a close mic. |
| **Context biasing** | Telling the recogniser, *while it is listening*, which words are likely right now. |
| **Shallow fusion** | The technique for doing that — nudging word scores mid-decode. |
| **Greedy vs beam decoding** | Greedy takes the single best guess each step and is fast. Beam keeps several candidates alive and is slower but produces alternatives. |
| **Transducer / TDT / RNN-T** | A model architecture (Parakeet, Nemotron) where the decoding loop is ours to modify. |
| **Encoder-decoder** | A different architecture (Whisper) where it mostly isn't. |
| **Confusion network** | A word-by-word list of what else the recogniser nearly said. |
| **Deixis** | Pointing words: "this", "that", "there". Meaningless without context. |
| **Accessibility tree** | The structured map of buttons, fields and text every app already exposes to screen readers. Free, reliable, machine-readable. |
| **Injection** | Getting text from our app into the app you're actually using. |
| **Gatekeeper** | A tiny, fast model that runs first and decides which expensive model (if any) should handle this utterance. |
| **Model mesh** | Using many small specialised models instead of one big general one. |
| **Post-processing** | Everything that happens after the words are recognised — cleanup, formatting, style. |
| **Confidence** | How sure the recogniser was about each word. Normally discarded immediately. |
| **Confabulation** | When a language model smooths a garbled input into fluent, confident nonsense. |

---

## Part 4 — The bets

⚠ *v1 listed eight "hard bets" and treated them as equally novel. Two were table stakes and one was premised on a technical falsehood. Corrected.*

### Table stakes — necessary, not differentiating

These must be excellent. They are not a moat — they are the floor.

- **T1. Injection.** Accessibility API → synthesised Unicode key events → per-app adapters for the hostile set (terminals, Electron, Slack, Cursor, Figma, Excel) → clipboard paste only as last resort. Measure success per app and per version; route automatically. Everyone has a version of this. Ours must simply not break. *(Reference design: FluidVoice's layered stack — clean-room only, it's GPLv3; see Part 4.5.)*
- **T2. VAD and endpointing.** FluidVoice literally ships with none. Table stakes.
- **T3. Local-first, provably.** Speech never leaves the device unless enabled. Screen read via accessibility tree, never screenshots, unless explicitly enabled. Ship a live panel showing what left the machine in the last hour, with a kill switch. ⚠ v1 called Wispr's screenshot incident a "permanent trust wound"; in fact their CTO apologized, called the ban wrong, and shipped enforced Privacy Mode. It is a real scar, not a permanent one. Verifiable cleanliness is still worth a lot — just not infinite.

---

### Bet 1 — Acoustic robustness first. It is the biggest real share of error.

⚠ *This is the bet v1 omitted and it is probably the most important one.*

1. Best-in-class echo cancellation and noise suppression, on-device, always on.
2. Explicit handling for the mics people actually use — AirPods and Bluetooth (which every competitor's own FAQ apologises for), laptop far-field, cheap headsets.
3. Accent-robust training and evaluation, treated as a first-class metric rather than an afterthought.
4. Automatic mic selection and quality warning — tell the user their input is bad *before* they've spoken 200 words into a dead mic.

Muesli's own eval concluded robustness work *"will move user-perceived quality far more"* than swapping models. They were right and nobody acted on it.

---

### Bet 2 — Decode-time context biasing. Bounded, and only where it's possible.

Build a live **vocabulary of the moment** from:
- Proper nouns visible on screen right now (accessibility tree — cheap, no screenshots)
- Current thread participants, calendar attendees, contacts
- Open code symbols, file names, branch names, package names
- Words used in the last 10 minutes; words you have ever corrected

Feed it to the recogniser **during decoding**, not as find-and-replace afterwards.

**The honest constraints** ⚠ *(v1 called this "the whole product" and was wrong to):*

1. **Architecture-limited.** Works on transducers (Parakeet TDT, Nemotron) where we control the decode loop. Does **not** transfer to Whisper (weak prompt biasing only) or Apple's closed SpeechAnalyzer. This constrains our model choice permanently.
2. **Wants beam search**, which multiplies compute per frame and eats the latency advantage. Real engineering tension, not a free win.
3. **Must be bounded.** The literature tunes lists of ~100–1000 entries. "Every proper noun on screen" is the over-biasing regime and will hallucinate entities into your text. Ranking and capping the list is the actual hard part.
4. **Fixes (b) not (a).** This moves entity recall a lot and total WER modestly. It is not a substitute for Bet 1.

Reference: NVIDIA's NGPU-LM (arXiv 2505.22857) does context biasing inside greedy transducer decode. Live research, not settled plumbing.

*Build path: implemented inside our FluidAudio fork — the decode loop is plain Swift, which is the entire reason this bet is feasible (Part 4.5). FluidVoice's biasing thresholds are the tuning head start, clean-roomed.*

---

### Bet 3 — Repair by voice. We must *build* the alternates, not salvage them.

⚠ *v1 claimed "the recogniser already produced ranked alternatives and threw them away." **That is false.** Greedy TDT decoding never generates them. CoreML Whisper surfaces none. Apple's SpeechAnalyzer exposes none. This is a build, not a salvage — and it is the riskiest thing in the document.*

What we build:
1. A beam decoder over the transducer, kept alive only for the words where confidence is low.
2. A **word-level confusion network** — for each uncertain word, the semantically distinct alternatives. (Raw TDT beam candidates differ mostly in blank/duration tokens, which are useless to a human. Collapsing them into meaningful alternates is the real work.)
3. Where beam alternates are too weak, generate candidates from the bias vocabulary and phonetic neighbours instead.

What the user gets:
- **"No, Kothari"** → the word snaps. No keyboard.
- **"Not that one"** → cycles the alternatives.
- **"Scratch that"** → drops the last phrase.
- Hold the key over a word → alternates appear inline, pickable by voice.

**Why it's worth the risk:** the failure mode of every competitor is "reach for the keyboard." That single moment is where they lose the user. Nobody has attacked it. If we solve it, the accuracy bar we need to clear drops — because *recoverable errors are cheap and unrecoverable ones are fatal.*

*Build path: the beam decoder and confusion network live in the FluidAudio fork, alongside Bet 2 (Part 4.5).*

---

### Bet 4 — Dual-path ASR, with a hard safety rule on the splice.

1. Tiny streaming model puts words on screen in **under 100ms**.
2. Large model runs in parallel on the same audio.
3. On disagreement, text **self-corrects behind your cursor**.

Compute is fine — 35–40× real-time on Apple Silicon leaves headroom. **The danger is the splice**, not the throughput.

**Non-negotiable rule:** never rewrite text the user has already touched, moved past, or that another process has modified. If we cannot verify the region is still exactly what we wrote, **we do not correct it** — we surface the correction as a suggestion instead. Corrupting a user's document once is unrecoverable, reputationally.

Secondary risks to design against: ANE contention between two models plus a local LLM; thermals on fanless hardware; and the possibility that text changing behind your cursor simply feels like gaslighting. Needs a "show me what changed" affordance and probably a per-user off switch.

---

### Bet 5 — Two keys. The gatekeeper routes inside them, not across them.

⚠ *v1 claimed fully mode-free routing; v2 killed it. v3 refines it again: the Wispr gatekeeper evidence shows routing is more tractable than v2 allowed — but not across the boundary that matters.*

The base rate is ~90% dictation. Even 97% routing accuracy means an unwanted **action** every ~30 utterances. And "just do the reversible thing" doesn't save you — the reversible failure for a misrouted question is typing an essay into your document.

But note what Wispr's gatekeeper actually routes *between*: message, command, edit — and their Command Mode still requires you to select text first. **Even the most sophisticated router in the category keeps a human-declared boundary.** That is evidence, not coincidence.

| Signal | Inference | Verdict |
|---|---|---|
| Selection exists? | Dictate vs Transform | **Deterministic and free — infer it** |
| Phrasing, context, screen state | Which *pipeline* to run — email, chat, code, prose | **Gatekeeper's job — infer it** |
| Text vs irreversible action | Type it vs do it | **Asymmetric harm — keep the key** |

**The design:** one key for *text*, where the gatekeeper routes freely between dictate, transform, and format-specific pipelines. A second key for *act*. Two keys, with heavy inference inside each.

Elegance that types a command into your email is not elegance.

---

### Bet 6 — Point and speak. Time-aligned.

SupaMaus's best idea, generalised out of the developer niche:

- While you speak, your cursor path, any drawn stroke, and your selection are recorded on the **same timeline** as your words.
- *"Move **this** over **there**"* binds each word to the exact screen position your pointer was at when you said it.
- Works across windows and displays.

This is what makes voice feel like talking to a person instead of typing with your mouth.

---

### Bet 7 — Tiered consent, based on reversibility.

HeyClicky killed its own proactive mode and Infina refuses open-ended agency because both got consent wrong.

| Action class | Behaviour |
|---|---|
| Reversible (type, format, navigate, scroll, open) | Just do it |
| Semi-reversible (send message, create file, commit) | Do it, show a **5-second undo** |
| Irreversible (delete, pay, send external email, destructive shell) | Confirm first, always |

Never a blanket "allow all." Never a confirmation on something you can undo.

---

### Bet 8 — The pipeline is the product. Gatekeeper first, model mesh behind it.

⚠ *Added in v3. This was the single biggest omission in v2, which treated cleanup as bullet six of Phase 1.*

Voice does not go mic → text. It goes:

```
audio → acoustic model → confidence-annotated raw text
      → gatekeeper (tiny, local, ~1ms)
      → repair pass    (fix low-confidence entities)
      → format pass    (structure for this destination)
      → context pass   (resolve names, threads, references)
      → style pass     (make it sound like you)
      → injection
```

**Design rules:**

1. **Gatekeeper runs first, always, and is tiny and local.** It decides destination, register, and how much machinery this utterance deserves. Most speech should exit the pipeline after two cheap stages.
2. **Many small specialised models, not one large general one.** A model tuned for email formatting beats a frontier model prompted to format email — cheaper, faster, more consistent. Same for chat, code, lists, commands, meeting notes.
3. **Every stage is skippable and independently measurable.** If the format pass makes things worse for terminals, we turn it off for terminals. Pipelines rot invisibly unless each stage is instrumented.
4. **Latency budget is per-stage and enforced.** Wispr does the whole thing in under 700ms *over a network*. On-device, with no round trip, our budget should be tighter, not looser.
5. **Local-first still holds.** The mesh runs on-device: small task-tuned models, not API calls. This is harder than Wispr's approach and it is the reason to do it.

**Why this matters more than it sounds:** independent reviews conclude Wispr's accuracy advantage comes from post-processing, not from a better transcription model. For most of the company's life, the pipeline *was* the product. That is a directly transferable finding.

---

### Bet 9 — Confidence must survive the pipeline.

⚠ *Added in v3. This is the original idea in this document, and it exists because of the pipeline reframe.*

**The failure nobody has named:** a language model rewriting a transcript cannot tell a correctly-heard word from a mangled one. So it smooths both. *"conference call of team fuel h e"* does not get repaired into *"TeamViewer AG"* — it gets polished into something fluent, confident, and wrong.

**The post-processing layer amplifies exactly the errors the acoustic layer couldn't catch.** Every product in this category discards word-level confidence at the first pipeline stage. That is why they all produce beautifully formatted nonsense on hard audio.

**What we build instead:** confidence is a first-class value that travels the whole way.

1. The acoustic model emits per-word confidence and audio time-spans, not just a string.
2. Every pipeline stage receives it, must preserve it, and is **forbidden from silently rewriting a low-confidence span** — it flags instead of smoothing.
3. Low-confidence entities are routed to the repair pass and the bias vocabulary *before* any formatting or style model sees them.
4. The final text keeps a map back to the original audio span, **through every stage**. This is what makes Bet 3 work at all: when you say *"no, Kothari,"* we must know which audio moment produced the word you're objecting to, even after four rewrites.
5. Uncertainty is shown, subtly, in the text itself — so you know where to look.

Bets 3, 4, 8 and 9 are one system. Repair without confidence propagation is guesswork. A pipeline without confidence propagation is a confabulation machine. Nobody has built either half.

---

## Part 4.5 — What we fork, port, or copy

Claude Code builds this — but it should not build from scratch what the ecosystem already solved. The license boundaries matter as much as the code.

### Fork / depend on directly

1. **FluidAudio** (`FluidInference/FluidAudio`) — **the single most valuable repo in the landscape, and our engine layer.** It is the shared engine under *both* Muesli and FluidVoice: Parakeet TDT CoreML runtime, Silero VAD streaming, pyannote diarization on ANE. Critically, its **decode loop is plain Swift** (`GreedyTDTDecoder.swift`), with encoder/decoder/joint as separate CoreML modules — the exact interception point Bets 2, 3 and 9 need. Everyone consumes it as-is; nobody has modified the decode loop. **Our fork — biasing, beam search, confidence emission — *is* the differentiated engine.** Everything above it is product.
2. **Muesli** (MIT — safe to copy verbatim) — cherry-pick, don't fork wholesale:
   - The **CoreAudio process-tap system audio recorder** with heartbeat/watchdog and ScreenCaptureKit fallback — the hardest-won plumbing in the repo. Feeds Phase 5's meeting capture.
   - The **AEC integration pattern** (LocalVQE default, DTLN fallback) for Bet 1. ⚠ Verify the model weights' license separately from the MIT code.
   - The **agent CLI design** (JSON envelope, `schemaVersion`, built for coding agents) — as a spec to imitate, for our own automation surface.
3. **Standard permissive dependencies:** Silero VAD (via FluidAudio), WhisperKit (Intel/long-form fallback only — we are transducer-committed), Sparkle (updates), KeyboardShortcuts, DynamicNotchKit (overlay UI).

### Port the ideas — never the code

4. **FluidVoice is GPLv3, deliberately relicensed from Apache as a defensive move.** Copying one file makes our whole app GPLv3. Three things are worth clean-room reimplementation from a reading of the architecture:
   - The **layered injection stack** (`TypingService.swift`): CGEvent unicode → AX direct insertion → HID → clipboard → menu-paste, with per-app special-casing (Ghostty, tmux). This is the reference design for T1.
   - The **contextual-biasing vocabulary config** (alpha / similarity / confidence thresholds) — the only shipped example of decode-time biasing in the category, and a head start on tuning Bet 2.
   - The **direct Core Audio HAL capture path** (replacing AVAudioEngine) — device routing, prewarm, ring buffer.

### Reference, not dependency

5. **NVIDIA NGPU-LM** (arXiv 2505.22857) — the published method for context biasing inside greedy transducer decode. Implement against the paper, inside our FluidAudio fork.
6. **Parakeet / Nemotron weights** — CC-BY-4.0; commercial use fine with attribution.
7. **Cua** (the computer-use framework HeyClicky builds on) — candidate for Phase 4's agentic fallback only; our deterministic accessibility-tree layer comes first and is ours. ⚠ License unverified — check before depending.
8. **Paperclip** (`paperclipai/paperclip`, MIT, 78k stars) — not a dependency; the **CLI adapter pattern** is what we take. Its adapter shim drives Claude Code / Codex / Cursor as local subprocesses, which is how users' existing AI subscriptions power our pipeline stages with no API key (Part 4.6). Read `adapter-plugin.md` and `tools/agent-shim` for the interface design; reimplement natively in Swift.

### Nothing to take

SupaMaus, Wispr, Aqua, Kivi — all closed. Their ideas are already absorbed into the bets; their code is unavailable.

**Pre-code checklist:** verify Cua's license and LocalVQE's model license before writing a line against either.

---

## Part 4.6 — Model access: free, paid, and the subscriptions you already have

The user chooses their models. The app must be excellent with zero spend and better with whatever the user already pays for.

### Two layers, two different choices

| Layer | Free option | Paid option | The honest truth |
|---|---|---|---|
| **ASR** (speech → text) | Local models, downloaded free | Cloud ASR APIs (e.g. Aqua Avalon, $0.39/hr) | **Local is the premium experience here.** Bets 2, 3 and 9 — biasing, repair, confidence — only work on our local transducer fork. Cloud ASR returns a bare string; the lattice is gone. Cloud ASR is a coverage/convenience option and the UI must say so. |
| **Pipeline** (formatting, rewrites, summaries) | Local task-tuned models (the Bet 8 mesh), or user's own Ollama / LM Studio | Frontier models via key, subscription, or CLI | **Paid genuinely helps here.** Bigger models produce better rewrites, summaries, and Phase 2 transformations. This is where the choice has real upside. |

**Subscriptions and ASR — checked:** existing AI subscriptions do **not** help ASR. ChatGPT subscriptions don't expose transcription APIs (Whisper / gpt-4o-transcribe are API-billing only); Claude has no ASR endpoint at all. Subscriptions help the **pipeline layer only**. The onboarding UI must not imply otherwise.

### Four ways to bring a paid model — all proven in the wild

1. **BYO API key.** OpenRouter is the highest-leverage single integration — one key, every model. Keys live in Keychain, never on our servers. (FluidVoice ships this today for 9+ providers.)
2. **OAuth to a subscription.** "Sign in with ChatGPT" via OAuth PKCE — no key handling, the user's existing Plus/Pro subscription pays for pipeline calls. **Muesli ships exactly this today**; it is a solved pattern.
3. **Local CLI adapters — the Paperclip pattern.** [Paperclip](https://github.com/paperclipai/paperclip) (MIT, 78k stars) drives Claude Code, Codex and Cursor as local CLI subprocesses through a thin adapter shim — *"if it can receive a heartbeat, it's hired."* We adopt the same pattern: if the user has the `claude` or `codex` CLI installed, an adapter routes pipeline stages through it, and their **existing Claude/ChatGPT subscription** pays — no API key, no new account, no data path we control. Adapter interface is pluggable, so any future CLI agent works the day it exists.
4. **Our managed subscription.** We proxy and meter. Simplest path for non-technical users; the obvious monetization.

### Routing rules

1. **The gatekeeper is always local.** It sits on the latency-critical path; no exceptions.
2. Default is **Auto**: local first; a paid model is used only where the user enabled it *and* the stage benefits.
3. **Per-stage override, not one global switch** — local ASR with cloud rewrites is a sensible mix, and the common one.
4. Every cloud call — key, OAuth, or CLI — appears in the **T3 data panel**. The free/paid choice doubles as the privacy choice, visibly.
5. **The Lab settles the "is paid worth it?" question** with the user's own audio: run the same benchmark against both configurations, show the delta. Evidence, not marketing.

### Where the user makes the choice

**During onboarding, in Phase 1** (see Phase 1 UI/UX). One screen, plain language: pick a free local model (downloads in the background while onboarding continues), and optionally connect something you already pay for. Changeable any time; never blocking; the app works before the choice is even finished.

---

## Part 5 — The phases

⚠ *v4 re-phases the plan. v3 had a UI-less "Phase 0" proof harness — wrong frame twice over: it reasoned from effort ("weeks, not quarters"), and it shipped nothing a human could use. Effort is not a planning input here. The validation gates survive, but they move **inside** Phase 1 as product features and instrumentation. Kill criteria still apply — they now gate which features stay enabled in the shipped app, not whether an app ships.*

Every phase is a signed, installable .dmg. Install it, use it for a day, and its value should be self-evident. The "Done when" line under each phase is the quality bar for calling it complete.

---

### Phase 1 — "You never touch the keyboard to fix it"

**The .dmg:** a menu-bar dictation app. Hold one key, talk, release — polished text lands in whatever app you're in. Fully on-device, no account, usable within 60 seconds of install.

**The promise:** dictation where errors are rare, and the rare ones are repaired by voice.

⚠ *v3 restructured this so post-processing is half the phase, and pulled style matching forward from Phase 2. v4 folds the old Phase 0 in as the Lab (see below).*

**Ships — the acoustic half:**
1. One key. Hold to talk, double-tap for hands-free.
2. Best-in-class acoustic robustness (Bet 1) — the accuracy ceiling. *(AEC pattern from Muesli, MIT; Part 4.5.)*
3. Bounded decode-time context biasing (Bet 2) — the entity fix.
4. Voice repair with visible alternates (Bet 3) — shipped behind a default-on flag; the Lab decides whether it stays.
5. Confidence emitted per word, with audio spans (Bet 9).

**Ships — the pipeline half:**
6. Gatekeeper: tiny, local, runs first, routes everything (Bet 8).
7. Specialised on-device formatters for the destinations that matter on day one: **email, chat, code, prose, terminal.** Not one prompt with five branches — separate tuned models.
8. Context pass: fillers, self-corrections ("Friday — no, Thursday"), punctuation, list detection.
9. Code-aware formatting: `camelCase`, `snake_case`, shell, paths, math.
10. **Style matching from v1.** It learns how you write in each destination and matches it. Not a Phase 2 feature — it is what makes dictation feel finished rather than transcribed.
11. Confidence preserved end-to-end; no stage may silently smooth a low-confidence span (Bet 9).

**Plus:** solid injection (T1), real VAD (T2), fully on-device, no account to start, and a visible **Zero-Edit counter** — "4,102 words spoken today, 11 edited."

**Ships — the Lab (the old Phase 0, now a user-facing feature):**

12. A built-in **Lab panel**: the real-world evaluation harness ships *inside the app*. A tester — or any user — can run the full benchmark (calls, meetings, accents, noise, technical speech) on their own machine, on their own audio, and see WER, entity recall, and zero-edit rate per pipeline configuration. Publish the harness and the results.
13. Every risky bet is a **flag the Lab measures**: context biasing on/off (Bet 2), voice repair on/off (Bet 3), confidence-aware post-processing on/off (Bet 9), and per-stage latency/thermal readouts for the on-device mesh (Risk 10) on whatever hardware it's running on.
14. This makes the app **self-verifying**: a human tester doesn't take our accuracy claims on faith — the evidence panel is in the product. It doubles as the trust surface (T3): the same panel shows that nothing left the machine.

**Kill criteria, unchanged in substance:** if the Lab shows biasing doesn't move entity recall materially, Bet 2's flag goes default-off and Bet 1 is the accuracy story. If repair alternates aren't human-meaningful, Bet 3's flag goes off and repair falls back to "scratch that" + re-dictate. If the mesh blows the thermal budget on supported hardware, we decide *then* which stages may go to the cloud — visibly, in the data panel — rather than quietly compromising T3.

**Ships — onboarding and model choice (Part 4.6):**

15. A 60-second onboarding: permissions → mic check → **model choice** → first dictation. Model choice is one screen: a free local model (Fast / Balanced / Best, with sizes and plain-language tradeoffs) downloads in the background while onboarding continues — the tiny bundled model makes the app usable immediately. Optionally, connect what you already pay for: OpenRouter/any API key, "Sign in with ChatGPT" (OAuth PKCE), or a detected `claude` / `codex` CLI (the Paperclip adapter pattern — your existing subscription pays, no key needed).
16. Per-stage model routing with an Auto default; every cloud call visible in the data panel; the Lab measures free-vs-paid on your own audio.

**UI/UX:**

- **Two surfaces only: a menu-bar item and a notch-aware pill overlay** (DynamicNotchKit; the FluidVoice/HeyClicky precedent). No window, no dock icon. Hold the key → the pill slides out with a live waveform and streaming preview; release → it retracts as text lands.
- **Repair is inline, in the destination app** — hold the key over a word and its alternates fan out beneath it, numbered, pickable by voice. No panel, no popup.
- **The menu-bar dropdown is the whole dashboard**: zero-edit counter, today's words, current model, mic quality indicator, one-click Lab.
- **Onboarding teaches by doing**: the last step is dictating one real sentence into a real app — not a video, not a tour. (Infina and Muesli both get this right; HeyClicky's changelog shows tours get skipped.)
- **Bad-mic warning appears in the pill before you speak** (Bet 1), not in a settings pane after you've lost 200 words.
- Model downloads show in the pill as quiet progress; switching models never requires a restart.

**Source material (Part 4.5):** this is the most reuse-heavy phase — most of its foundation exists in the open.
- **FluidAudio fork** carries the entire acoustic half: Parakeet TDT runtime, Silero VAD (T2), plus our additions — biasing (Bet 2), beam/confusion network (Bet 3), confidence emission (Bet 9).
- **Muesli (MIT):** AEC pattern for Bet 1; model download/management patterns.
- **FluidVoice (GPLv3, clean-room only):** injection stack design for T1; biasing threshold values as Bet 2's tuning starting point; HAL capture path for mic robustness.
- **Permissive deps:** Sparkle (updates), KeyboardShortcuts (hotkey), DynamicNotchKit (overlay), WhisperKit (Intel fallback).
- **Original work with no donor:** the gatekeeper, the specialised formatters, confidence propagation through the pipeline, the Lab. The pipeline half is ours alone — nobody open-source has one.

**Deliberately deferred to Phase 1.5:** dual-path silent correction (Bet 4). Highest risk of being hated; Phase 1 is excellent without it. Phase 1.5 is itself a .dmg update whose value is "the text quietly gets better after it lands." *Source material: both streaming models (Parakeet Realtime EOU, Nemotron streaming) already run under FluidAudio — both Muesli and FluidVoice ship them. The dual-path reconciliation and safe-splice logic are original.*

*Phase 1.5 UI/UX: a corrected word gets a brief shimmer and a 2-second underline — noticeable if you're looking, invisible if you're not. Hovering any corrected word shows "was: …" with one-tap revert. "Show me what changed" lives in the menu-bar dropdown; silent correction has a per-app off switch. The gaslighting risk is managed with visibility, not modality.*

**Done when:** on the published in-app harness, we beat every competitor on WER *and* zero-edit rate — with the explicit target of beating Wispr's stated Canto goal of a **30–35% reduction in dictations needing editing.**

---

### Phase 2 — "Talk to your text"

**The promise:** voice stops being a typewriter and becomes an editor.

**The .dmg:** same app, updated. New testable behaviour on day one: select any text in any app, hold the key, say what you want done with it.

⚠ *Basic style matching moved to Phase 1. What remains here is transformation — a genuinely different capability.*

1. Select anything, anywhere, speak an instruction → rewritten in place.
2. **Chained turns** on the same selection: *"make this two lines"* → *"call out the churn number"* → *"and bold it."* No re-selecting.
3. Ask a question about a selection, get the **answer** typed in — not a chat window.
4. **Personas deepen** past Phase 1's automatic style matching — overridable in plain English, per app, per recipient.
5. Spoken snippets.
6. Works in spreadsheets (per-cell), editors, mail, docs.
7. New pipeline stages ship as drop-in models, not new code paths. Bet 8's architecture is what makes this phase cheap.

**UI/UX:**

- **The pill changes state, not the world**: with text selected, holding the key tints the pill to "transform" and echoes the selection length ("editing 42 words") — you always know which mode fired, without having chosen one.
- **Rewrites land as a fast inline morph** — old text collapses, new text expands, one beat — never a flash-replace you can't follow. Immediately after, a small "↩ / try again" ghost floats by the selection for 5 seconds.
- **Chained turns**: after an edit, the pill stays warm for ~8 seconds ("still on it — keep talking"), so *"actually, bold the number"* needs no re-selection. (Kivi's chained-command flow is the reference.)
- **Answers type in below the selection**, visibly attributed ("answer:"), so generated content is never mistaken for your own words.
- **Personas are a single plain-English text box per app** (Kivi's pattern) — auto-filled by what Phase 1 learned, editable in one sentence, never a form.

**Source material: essentially none — and that is the point.** The transform loop rides entirely on Phase 1's pipeline architecture (Bet 8) and injection stack (T1). The nearest open prior art is FluidVoice's Write Mode and Kivi's chained commands — both are *interaction* precedents to study, not code to take (GPLv3 and closed respectively). This phase is original work by design; it is where the product pulls ahead of what can be forked.

**Done when:** a rough paragraph reaches final without one keystroke.

---

### Phase 3 — "It knows what 'this' means"

**The .dmg:** same app, updated. Testable in one sentence: point at something on screen, say *"move this over there,"* and watch it resolve both words correctly.

1. Time-aligned pointer + speech binding (Bet 6).
2. Draw-to-point — sketch on screen while talking; the stroke is input.
3. Multi-window, multi-display, one utterance.
4. Full accessibility-tree reading — the entire terminal scrollback, not the visible three lines.
5. Conversational referents: *"tell her the deck is ready"* resolves "her" and "the deck" from what's visible.
6. Reverse elicitation — when genuinely ambiguous, it asks you to point rather than guessing.

**UI/UX:**

- **Draw-to-point renders as a hand-drawn stroke** — Excalidraw-style, slightly imperfect, fading after a beat (SupaMaus and HeyClicky both converged on this; the sketchiness signals "annotation, not UI").
- **Resolution is confirmed visually**: when "this" binds to a region, that region pulses once. You see what it understood the moment it understands it — mistakes are caught before they become actions.
- **Cross-display capture**: strokes work on any screen; the pill shows a small bundle count ("3 regions") when an utterance spans windows.
- **Reverse elicitation draws back at you** — a ring and "which one?" rendered on screen (HeyClicky's teaching overlay, inverted). You answer by pointing or by voice.
- No new surfaces: everything is the same pill plus transient on-screen ink.

**Source material: ideas only, no code.** The entire interaction model is SupaMaus's — time-aligned gesture-speech binding, session bundling, reverse elicitation — and SupaMaus is closed. This is a from-scratch reimplementation of a documented behaviour. The accessibility-tree reading builds on the AX plumbing already written for T1 in Phase 1; Muesli (MIT) has modest AX reading code worth checking first.

**Done when:** deictic phrases resolve correctly >95% of the time in normal use.

---

### Phase 4 — "It does it, not just types it"

**The .dmg:** same app, updated; the second key becomes live. Testable in one sentence: say *"open the PR tab and scroll to the failing check"* and watch it happen.

1. **Deterministic actions first** — driven by the accessibility tree, not an agent guessing at pixels. Click a control by name, switch app/tab/window/desktop, scroll, fire shortcuts, fill fields. Fast, reliable, offline, no model call.
2. **Agentic fallback second**, for the long tail, with a visible plan. *(Candidate base: Cua, the framework HeyClicky uses — license unverified, see Part 4.5.)*
3. **Its own overlay cursor.** Never moves your real pointer. (HeyClicky's rule; it's correct.)
4. Tiered consent (Bet 7).
5. Native connectors where they beat UI automation — Slack, Linear, Gmail, Calendar, Notion, GitHub. Sending a Slack message should be an API call, not a robot clicking.
6. Cancel mid-flight with a word.

**UI/UX:**

- **The agent's cursor is visibly not yours**: a tinted, softly-glowing pointer with a trailing wisp (HeyClicky's overlay-cursor rule). Your real pointer never moves; you can keep working.
- **The plan is chips, not a log**: current step glows, done steps shrink, upcoming steps are ghosted — glanceable from the notch, expandable on hover.
- **Consent by reversibility, visually distinct**: reversible actions just happen; semi-reversible show a 5-second undo toast with a draining ring; irreversible slide out a card that requires a spoken "confirm" or a click — never a buried dialog.
- **"Stop" is sacred**: saying "stop" or tapping the pill kills the action mid-flight, always, with a visible halt animation.
- **Deterministic vs agentic is legible**: instant actions happen with no ceremony; when the agent takes over, the pill says "thinking…" — so the user learns what's fast and what's a fallback.

**Source material:** the deterministic layer is original — nobody open-source has built an AX-tree action vocabulary (Infina's is the closest precedent, and it's closed; their *published command list* is a free spec of which 200 actions matter). The agentic fallback is where reuse lives: **Cua** for computer-use primitives (license check first), and **Muesli's agent CLI design (MIT)** as the pattern for exposing our own actions to external coding agents. Overlay-cursor and consent mechanics are behavioural ideas from HeyClicky — closed, reimplement.

**Done when:** the deterministic path covers the 200 most common desktop actions at >99% reliability.

---

### Phase 5 — "No hotkey at all"

**The .dmg:** same app, updated. Testable in one sentence: with hands-free mode on, talk to a colleague, then say *"type reply saying I'll review it tonight"* — only the second sentence does anything.

⚠ *v1 put record-and-replay here. Demoted — see Part 7.*

1. **On-device intent detection** — is this speech aimed at the machine, at a person, or at nobody? Small local model, continuous, nothing stored unless directed at us.
2. **Wake-verb grammar** as the reliable fallback (Infina's insight: short leading verbs beat wake words because they're already how you'd phrase it).
3. **Speaker identification** — responds to you, not the podcast, the TV, or your colleague. (Aqua's documented failure: it transcribes nearby televisions.)
4. Whisper-level input for open offices.
5. A hard, physical-feeling mute. Always visible. One gesture.
6. **Meeting capture falls out for free** — mic + system audio, diarization, no bot joining the call, notes generated locally. *(System-audio plumbing copied from Muesli, MIT — process tap + watchdog + SCK fallback; Part 4.5.)*

**UI/UX:**

- **Ambient state is always visible and always honest**: a small glyph (menu bar + notch) with exactly three states — listening, muted, processing. No hidden hot mic, ever.
- **The mute feels physical**: one gesture (click the glyph or a dedicated key), a hard visual state change, and a persistent badge while muted. Unmuting is never automatic.
- **Directed speech gets a subtle acknowledgment** — the glyph warms for a beat when it decides you meant it. False triggers become visible, correctable events ("not you" dismisses and teaches), not silent errors.
- **Meetings self-announce**: camera/calendar detection raises a notch notification with Join & Record / Record / Ignore (Muesli's split-button pattern). During capture, a discreet live bar shows speakers being separated; notes arrive as a notification when the call ends.
- Hands-free dictation shows the same pill, just untriggered by a key — the grammar ("type… / send") is printed inside the pill the first ten times, then fades.

**Source material:** meeting capture is the reuse-heavy half — Muesli (MIT) contributes the process-tap recorder, AEC, VAD chunking and diarization pipeline nearly whole, and diarization/speaker-embedding models already run in our FluidAudio fork (they power speaker ID here too). The hard half — directed-speech intent detection — has **no open prior art anywhere**; it is the phase's original research bet, with Infina's wake-verb grammar (closed, but fully documented publicly) as the fallback spec.

**Done when:** under one false trigger per day in an open office. (One per week is what people actually tolerate; one per day is the ship bar.)

---

### Phase 6 — "It sounds like you"

**The .dmg:** same app, updated (plus keyboard installs on mobile). Testable over 30 days: the Lab's personal-WER graph visibly declines, and a word you corrected once is never mis-heard again.

1. **Personal speech adapter** trained on-device from your corrections. Your accent, your mumbles, your vocabulary.
2. Every correction is training data. Nothing mis-heard twice.
3. Personal lexicon with learned pronunciations — including how *you* say them.
4. Native code-switching — Hindi+English, Spanish+English, Mandarin+English in one sentence. (Kivi proves demand; Sarvam's work proves tractability.)
5. Personalization layer syncs across Mac, Windows, iPhone, Android — encrypted, portable, exportable.
6. Mobile keyboard with the same repair loop.

**UI/UX:**

- **Learning is celebrated, quietly**: the first time a correction sticks, a one-line toast — "I'll remember *Kothari*." Never again for the same word. The moment of personalization is made visible exactly once.
- **The Lab grows a "you" tab**: personal WER over time, words learned, languages detected — the day-30-vs-day-1 proof, in the product.
- **Code-switching needs no toggle**: speak Hindi and English in one breath and it just lands; a small script indicator in the pill shows what it heard. Language pickers are a failure state (Kivi and Aqua both got this right).
- **Sync is pairing, not accounts**: QR-code pairing to phone, end-to-end encrypted, with an explicit "export everything" file — your voice profile is a possession, not a hostage.
- **The mobile keyboard is the pill, shrunk**: same hold-to-talk, same repair fan-out, same personas — and it returns you to your previous keyboard instantly (the exact friction Aqua's iOS reviews complain about).

**Source material:** code-switching has a real open donor — **AI4Bharat's Indic ASR models (RNNT, 7 Indian languages)** already run under FluidAudio; Muesli ships them today. Verify their exact license terms before commercial use. The personal adapter, correction-to-training loop, and encrypted sync layer have no open precedent — original work, and deliberately so: this phase *is* the moat, and a moat assembled from forks isn't one.

**Done when:** a user's personal WER at day 30 is measurably below day 1, provable in-app.

**Why this matters most commercially:** after 90 days, leaving means starting over as a stranger.

---

## Part 6 — What we deliberately do NOT build

1. **A chat window.** Open a chat panel and you've built a worse ChatGPT. Output goes into the app you're already in.
2. **A meeting bot that joins calls.** Capture locally.
3. **A general assistant.** Infina's discipline is correct. Scope is credibility.
4. **Screenshot-based screen reading by default.** Accessibility tree first — faster, better, and not the thing that burned Wispr.
5. **A separate mobile app.** A keyboard, not an app.
6. **Electron.** Native on every platform.
7. **Configuration surfaces for things we can infer.** Personas learn; they aren't filled in. (Consent tiers and the data panel are *not* configuration — they are the safety and trust surface, and they stay.)

---

## Part 7 — The honest risks

1. **The Lab may kill Bet 2 or Bet 3.** That's what it's for. But Bet 3 in particular is a research project dressed as a feature, and it is the most novel thing here. Losing it costs the most differentiation.
2. **Bet 2 locks our architecture.** Committing to decode-time biasing means committing to transducer models forever. If the frontier moves to something else, we're stranded.
3. **Silent correction (Bet 4) may feel like gaslighting**, and the splice can corrupt documents. Deferred to 1.5 for exactly this reason.
4. **Two-key design is a compromise**, and users will still occasionally hit the wrong one. Better than four modes, worse than magic.
5. **Accessibility APIs are hostile and undocumented.** Injection, screen reading and control all depend on them, and they shift under us with every OS and app update. The per-app success telemetry in T1 is the defence: breakage must be detected by the product, not by angry users.
6. **Phase 5 may be unsolvable to the bar.** It also carries the meeting product. If intent detection fails, meetings should be pulled forward and shipped on a plain hotkey instead.
7. **Record-and-replay is a graveyard.** ⚠ v1 had a "record once, runs forever" phase. UiPath, Automator, Shortcuts and Adept have all crashed on self-healing cross-app replay. Cut from the roadmap. Revisit only if Phase 4's deterministic action layer turns out to be reliable enough to compose — which would be the honest precondition.
8. **Wispr has $361M, four platforms, 60 billion words written, and deployment in nearly every Fortune 500.** Capital doesn't fix acoustic robustness — they proved that themselves, the hard way — but it buys distribution while we're still in Phase 2.
9. ⚠ **The pipeline architecture is inferred, partly from one person's reverse engineering.** The multi-model routing and post-processing-as-differentiator claims are independently corroborated. The tiny-gatekeeper claim is not. We should build it because the latency budget demands it, not because a tweet said so.
10. ⚠ **A model mesh on-device is much harder than a model mesh in the cloud.** Wispr routes to Baseten, Cerebras, Fireworks and frontier APIs. We are proposing several task-tuned models resident on a laptop, alongside two ASR models, within a thermal budget. This may force some stages to the cloud, which collides with T3. **Unresolved — and it is the most likely place this plan breaks.**
11. **Confidence propagation (Bet 9) has no prior art to copy.** It is the best idea here and the least de-risked. Its flag in the Lab is the single most important measurement in Phase 1.

*Out of scope by instruction: GTM, pricing, ICP, differentiation strategy. Flagging only that the doc currently has none, and that "on-device for regulated industries" — the obvious wedge — is the slowest-procuring, least-viral buyer there is.*

---

## Part 8 — One line per phase

| Phase | One line | The .dmg test |
|---|---|---|
| **1** | Dictation you never have to proofread. | Dictate an email; edit nothing; check the Lab's numbers. |
| **1.5** | The text quietly gets better after it lands. | Watch a wrong word fix itself — and never in text you've touched. |
| **2** | Select anything, talk, it's rewritten. | Select a rough paragraph, say "tighten this," done. |
| **3** | It understands "this" and "there". | Point and say "move this over there." |
| **4** | It does the thing instead of typing about it. | "Open the PR tab and scroll to the failing check." |
| **5** | Stop pressing a key. | Talk to a colleague; it stays silent. Address it; it acts. |
| **6** | It learns your voice and follows you everywhere. | Correct a word once; it's never wrong again, on any device. |

---

**Sources:** [Muesli #330](https://github.com/Muesli-HQ/muesli/issues/330) · [Muesli repo](https://github.com/Muesli-HQ/muesli) (MIT) · [FluidVoice repo](https://github.com/altic-dev/FluidVoice) (GPLv3) · [FluidAudio](https://github.com/FluidInference/FluidAudio) · [TechCrunch — Wispr $280M](https://techcrunch.com/2026/08/17/wispr-raises-280m-at-2b-valuation-as-it-looks-beyond-dictation/) · [Aqua — Avalon on OpenASR](https://aquavoice.com/blog/avalon-openasr-leaderboard) · [NVIDIA NGPU-LM](https://arxiv.org/pdf/2505.22857) · [Paperclip](https://github.com/paperclipai/paperclip) (MIT) · [heyclicky.com](https://www.heyclicky.com/) · [supamaus.com](https://www.supamaus.com/) · [infina.so](https://www.infina.so/) · [heykivi.ai](https://heykivi.ai/)
