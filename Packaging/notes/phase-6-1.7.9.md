# VoicePlus 1.7.9 — dictation no longer types a paragraph of your document instead of your words

The most alarming thing the owner reported. Dictating

> The quick brown fox jumps over the lazy dog

through the **hotkey** landed **completely wrong text**, while the **same sentence** through
**onboarding** was accurate. Same model, same microphone, same session.

It was never audio and never recognition. **The app's own learned-corrections system was
poisoning itself**, and the poison was only applied on one of the two paths.

Ships in the same dmg as 1.7.4, 1.7.5, 1.7.6, 1.7.7 and 1.7.8 — **this is the dmg**. Tag
`release/phase-6/v1.7.9` · 1 commit (`8e440fe`) on top of 1.7.8 (`3842440`) · sha256 and dmg
size recorded at the release build.

## 1. What was actually happening

- **A whole document was being stored as a "correction".** `ZeroEditTracker` finalised an edit
  with `finalText` set to the **entire focused field's accessibility value** — the whole
  document the user was typing into — while `originalText` was just the one utterance
  (`Lab/Counter/ZeroEditTracker.swift:126`).
- **The adaptation loop believed it.** `AdaptationService.ingestEdit` word-diffed a single
  utterance against a whole document, and `BiasListLearner` dutifully stored the result as
  corrections — variants mapping an ordinary word like **"the"** to **two paragraphs of the
  user's own document** (`Engine/Adapt/AdapterTrainer.swift:84-90`).
- **A later utterance got the blob back.** `RegressionGuard.apply` substituted the stored value
  for the real word (`Engine/Adapt/LearnedLexicon.swift:114`), and its **phonetic fallback
  matched on a single occurrence**, so one poisoned pair spread to **any similar-sounding
  word**.
- **That is exactly why one path was right and the other was garbage.**
  `RegressionGuardStage` is installed **only in the hotkey pipeline**
  (`AppContainer.swift:157-158`); the onboarding path displays **raw recognised spans**. The
  asymmetry was never in the recogniser — it was in what ran after it.

## 2. What ships instead

- **`LexiconSanity` states the rule a correction has to satisfy: a respelling, never a
  document.** It is enforced at **three** points — when a pair is **stored**, when an edit
  readback is **ingested**, and, critically, **when a variant is used**. That last one matters:
  a `lexicon.json` **already poisoned on a user's machine** degrades to **pass-through**
  instead of continuing to corrupt text. **No manual reset is required** — though a user who
  wants a clean slate can still clear learned data.
- **A "landing diff" diagnostic.** `UtteranceLander` now logs **one line per utterance** — the
  **raw recognised text** versus the **landed text**, their **Levenshtein distance**, and
  **which stages touched the spans** — so a **single real utterance** definitively separates
  *"the recogniser misheard"* from *"post-processing mangled it"*. Local `os_log` only, nothing
  leaves the machine, consistent with the project's no-telemetry stance; **verbatim text stays
  off** unless the app is launched with `VOICEPLUS_LOG_TEXT=1`.

## 3. What the investigation cleared, with evidence

Worth recording, because it is the rest of the post-processing chain and it is **not** at
fault:

- **`ContractEnforcingStage` / `ConfidenceContract.verify`** enforce the
  confidence/audioRange/provenance invariant on **every** stage — a violation falls back to the
  stage's input.
- **`CodeSwitchService.finalize`** returns `nil` unless **two scripts are genuinely present**.
- **Every provider stage falls back to a deterministic local path** when no API key is
  configured.

None of them silently degrade into inventing text.

## 4. Tests

- **5 new tests** in `Tests/EngineTests/AdaptTests.swift` covering the sanity rule at each of
  the three enforcement points, including an already-poisoned lexicon degrading to
  pass-through.
- **Full package: `swift build` clean.** The total test count is recorded at the release build
  (1313 at 1.7.8).

## What you need to do

1. Quit VoicePlus, replace it in **/Applications** with the copy from this dmg, then run once:

       xattr -dr com.apple.quarantine /Applications/VoicePlus.app

2. **This dmg carries 1.7.4 through 1.7.9.** Its five companions are the wedged-dictation fix,
   the clipped onboarding footer, the presence dot and error pill, the audio ownership /
   warm-up fix, and the model-tier containment wording — read their notes for what to check.

3. **Dictate one sentence with the hotkey and read the landing diff.**

       log show --last 30m --predicate 'subsystem == "in.adityakatare.voiceplus" AND category == "pipeline"' --info | grep "landing diff"

   **`distance 0`** means post-processing is innocent and the recogniser is at fault. Anything
   else points back into the pipeline, and the line names the stages that touched the spans.

## Known and remaining

- **It is not confirmed that this specific poisoning is what the owner hit.** No agent here has
  hardware, and their `lexicon.json` may or may not have been in that state. The mechanism is
  proven in test and it explains the hotkey/onboarding asymmetry exactly — but **the diagnosis
  on that machine is unconfirmed.** The new landing-diff line settles it in **a single key
  press**, and that is the recommended next check.
- **No agent on this machine has a microphone or a window server**, so everything here is
  covered against protocols and mocks rather than a real capture device.
- **The appcast enclosure URL still 404s anonymously** — private repo, pre-existing since the
  first phase-6 release, unchanged here.
- Ad-hoc signed, **not notarized** — no Developer ID on this machine. Unchanged.
