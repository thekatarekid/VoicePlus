# VoicePlus 1.7.11 — a model that reported "installed" but was half-downloaded

Choosing the **Fast** model, the download reported **success** and onboarding said

> Using Parakeet TDT-CTC 110M (tiny)

Then **"Dictate now"** showed *"Warming up…"* and failed with

> The file "weight.bin.partial" doesn't exist.

`weight.bin.partial` is **not ours**. It is **FluidAudio's download scratch file** — streamed
from HuggingFace and then moved into place — and the user should never have seen its name at
all.

Ships in the same dmg as 1.7.10 and 1.7.12. Tag `release/phase-6/v1.7.11` · 2 commits
(`c5fe8ae`, `a2f2887`) on top of 1.7.10 (`69638f5`) · sha256 and dmg size recorded at the
release build.

## 1. What was actually happening

**Two defects, and it took both.**

- **Two loads ran over one folder.** `ModelManager.load` is **actor-isolated but suspends
  across `AsrModels.load`**, and **an actor releases itself across a suspension** — so the
  **launch preload** and the user's **"Dictate now"** both saw nothing loaded and both went and
  loaded. `AsrModels.load` is **not a pure read**: it **re-downloads whatever the cache
  lacks**, so two of them over the same folder **raced on the same `.partial` file**. One won
  the move; the loser reported it missing — the exact Cocoa error the user read.
  (**The eager preload added in 1.7.7 did not cause this.** It supplied the *second caller*
  that made an already-present race reachable.)
- **"Is it installed?" could not tell a finished download from a started one.** The check was
  `FileManager.fileExists` over paths that are, every one of them, **`.mlmodelc`
  directories** — which **exist from the very first byte written into them**. A download that
  had barely begun already read as **complete**. FluidAudio documents this exact trap upstream.

**All three tiers were equally at risk.** They share **one fetcher, one presence check and one
loader**. **Best** succeeding earlier was **luck of timing, not a safer path** — worth saying
plainly, because "it only happens on Fast" would have been the comfortable and wrong
conclusion.

## 2. What ships instead

- **New `Engine/ASRRuntime/ModelIntegrity.swift` defines complete-and-loadable**, rather than
  present: **no `.partial` / `.part` / `.etag` debris anywhere in the tree**, **every required
  path present**, **every `.mlmodelc` bundle carrying its `coremldata.bin`**, and **no
  truncation** against the manifest's byte counts. It is a **cheap `stat` walk, no hashing** —
  it runs on **every hotkey press**, so it has to be. It walks the tree **by hand** rather than
  subtracting path strings: `/var` and `/private/var` are the same file spelled two ways, and
  the arithmetic silently turned *"delete the debris"* into a no-op.
- **`load` dedupes in-flight tasks and gates on integrity.** Concurrent callers **share one
  load task**; a model that is not complete-and-loadable is **not loaded and not reported
  installed**.
- **The fetcher verifies a staged tree _before_ publishing it, and swaps rather than
  delete-then-move** — so a **failed move can no longer destroy a working install**, and
  **`.partial` files stay in staging** where nothing can read them as installed.
- **Recovery is automatic.** A broken model now reports **not-installed**, so the picker simply
  **offers a re-download**; and `repair(_:)` deletes **the `.mlmodelc` bundle each `.partial`
  sits in** — not just the scratch file, because a bundle caught mid-download is missing an
  interior weight file no `requiredPaths` list names, and clearing only the `.partial` leaves
  something that **passes every check and still cannot load**. **Intact siblings stay**, so a
  retry costs **one bundle, not the whole model**.
- **The user reads a sentence, not a scratch filename.** *"The Parakeet TDT-CTC 110M (tiny)
  speech model didn't finish downloading — 1 file is missing or incomplete…"* — the errors
  **count** the incomplete files rather than naming them, since `weight.bin.partial` is an
  internal staging file and told the user nothing.

## 3. Tests

- New `Tests/EngineTests/ModelIntegrityTests.swift`. A `.partial` inside a bundle does **not**
  report installed on **any tier**; an interrupted or cancelled download leaves **nothing that
  does**; a download that lands incomplete **throws instead of publishing**; **concurrent loads
  share one load task**; and the **verbatim Cocoa error from the report is rewritten** into the
  plain-language sentence.
- `ModelManager`'s loader was made **injectable** so the dedupe contract is testable **without
  CoreML models**.
- **`swift build` clean**; the full-package test total is recorded at the release build.

## What you need to do

1. Quit VoicePlus, replace it in **/Applications** with the copy from this dmg, then run once:

       xattr -dr com.apple.quarantine /Applications/VoicePlus.app

2. **This dmg carries 1.7.10, 1.7.11 and 1.7.12.** Its two companions are the dictation key
   that was also the act key, and the black slab error notice plus the presence dot's
   left-click menu — read their notes for what to check.

3. **If a model is already half-downloaded on your machine, do nothing special.** It will now
   report as **not installed**, and the picker will offer to fetch it again. Only the affected
   bundle is re-fetched.

## Known and remaining

- **The end-to-end recovery path is untested: download Fast, interrupt it, relaunch, dictate.**
  No agent here fetches the real bytes from HuggingFace. The integrity rules, the dedupe, the
  staged-then-swapped publish and the rewritten error are covered against a synthesised model
  tree on disk; **a real interrupted download is not.**
- **The real HuggingFace download remains unverified** — pre-existing since 1.7.2, unchanged
  here.
- **No agent on this machine has a microphone or a window server**, so the warm-up path itself
  is covered against protocols and mocks.
- **The appcast enclosure URL still 404s anonymously** — private repo, pre-existing since the
  first phase-6 release, unchanged here.
- Ad-hoc signed, **not notarized** — no Developer ID on this machine. Unchanged.
