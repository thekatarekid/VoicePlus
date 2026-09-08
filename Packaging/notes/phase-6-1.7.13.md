# VoicePlus 1.7.13 — every speech model was downloaded twice

After choosing a model, the owner watched **"Warming up…"** for **well over a minute** — and
then found **two byte-identical 468 MB copies of Parakeet TDT v3** sitting on disk.

The wait was real work. It was just work that had already been done once.

Ships in the same dmg as 1.7.14 and 1.7.15 — **1.7.15 is the dmg**. Tag
`release/phase-6/v1.7.13` · 2 commits (`6e45b4e`,
`dfdad8a`) on top of 1.7.12 (`823fda0`) · sha256 and dmg size recorded at the release build.

## 1. What was actually happening

**VoicePlus stored the model in a folder FluidAudio would never look in, and then asked
FluidAudio to load from it.**

- **`AsrModels.load(from:)` ignores the directory it is handed.** It takes the **parent** as a
  models root and asks `ModelHub` to resolve the repo name itself — descending back into
  `<parent>/<Repo.folderName>`.
- **`Repo.folderName` strips `-coreml`.** We named our folder from **`ModelID.rawValue`** —
  `parakeet-tdt-0.6b-v3-coreml` — so the round trip landed on **`parakeet-tdt-0.6b-v3`**, found
  it **empty**, and **re-downloaded the entire 468 MB model from HuggingFace**.
- **Only `parakeet_vocab.json` was ever read from our own copy.** Everything else in the tree we
  had carefully fetched, verified and published was **never opened**.
- **Measured from the owner's log:** the duplicate download cost roughly **81 seconds** of the
  wait, on top of a genuinely one-time **~19 second Neural Engine compile**. The compile is
  expected; the 81 seconds were not.
- **All tiers were affected** — one naming rule, one loader. Fast duplicated its 110 MB the same
  way.

## 2. What ships instead

- **The on-disk folder name now comes from `ModelDescriptor.folderName`**, decoupled from
  **`ModelID.rawValue`** — which stays the model's **stable identity**, since it is `Codable` and
  is already written into every `voiceplus-manifest.json` on disk. The name we write and the
  name FluidAudio resolves are now **the same name**.
- **`ModelCatalog.fluidAudioFolderName(for:)` reads `Repo.folderName` out of the dependency**
  rather than repeating the string, and **a test pins our folder name to FluidAudio's**. An
  upstream rename now **fails the build here** instead of quietly costing every user another
  468 MB.
- **The EOU model keeps its own name.** `StreamingEouAsrManager.loadModels(from:)` opens the
  files **in the directory it is given** and never re-downloads, so it was never affected and is
  not renamed for symmetry.
- **New `Engine/ASRRuntime/ModelLayoutMigration.swift` runs from `ModelManager.init`** and leaves
  **exactly one folder per model, re-downloading nothing**: a **lone legacy folder is renamed**;
  where **both** exist, the **complete one is kept** (ours first, since it carries the manifest)
  and the **orphan deleted**. Publishing is a **swap**, so a failure leaves a working model under
  *some* name rather than none.
- **`BiasVocabulary.discoverParakeet` builds its candidates from the descriptor**, legacy name
  included. The vocab lookup was the one thing that ever read from our own copy, so a hard-coded
  name there would have **stopped finding it the moment the migration ran**.

**Nobody re-downloads, and an affected user reclaims 461 MB on first launch.**

**Verified against the real 461 MB model on disk**, with **`ModelHub.offlineMode = true`** so
nothing *could* be fetched: loading from the **new** path logs *"Found parakeet-tdt-0.6b-v3
locally, no download needed"* and completes; loading from the **old** path reports the model
**missing** — which, online, is **exactly where it used to re-fetch**.

## 3. Also fixed: the weakest model went first

**`BundledModel.firstLaunchOrder` was a constant headed by the 110M TDT-CTC tiny model.** A user
who **already had the far better 0.6B v3 on disk** still queued 110 MB of a worse model and got
v3 **last**, behind the 400 MB preview download — and could end up **using the tiny one**.

It is now **a function of what is already installed**. **Cold start is unchanged** — tiny first,
because 110 MB is what makes dictation work in seconds. And **`chooseFinal` and
`bestFinalModelOnDisk` now read one shared ranking**, `BundledModel.finalModelsByQuality`,
rather than duplicating the same quality order in three places where it could drift.

## 4. Tests

- New `Tests/EngineTests/ModelLayoutTests.swift` — **14 tests**. One **pins our folder name to
  FluidAudio's own `Repo.folderName`**, read out of the library. The rest cover the round trip
  landing where we wrote, a lone legacy folder being renamed, both folders collapsing to the
  complete one, the migration fetching nothing, and `firstLaunchOrder` preferring an installed
  better model while cold start stays tiny-first.
- `Tests/EngineTests/ASRModelManagerTests.swift`, `Tests/EngineTests/ModelIntegrityTests.swift`
  and `Tests/AppTests/OnboardingDictationTests.swift` updated — two of them had the old folder
  name **spelled out**.
- **`swift build` clean**; the full-package test total is recorded at the release build.

## What you need to do

1. Quit VoicePlus, replace it in **/Applications** with the copy from this dmg, then run once:

       xattr -dr com.apple.quarantine /Applications/VoicePlus.app

2. **This dmg carries 1.7.13, 1.7.14 and 1.7.15.** Its companions are the Actions key that could
   not be rebound or turned off and the microphone VoicePlus would have quietly picked — read their
   notes for what to check.

3. **Launch it once and do nothing.** The migration runs at startup. If you were affected you
   should get **461 MB back** without being asked anything.

4. **Then choose a model and time the warm-up.** The first load still pays a **one-time Neural
   Engine compile** of roughly **20 seconds**. A minute or more means something is still
   fetching.

## Known and remaining

- **The reclaim is untested against a real duplicate pair on a user's disk.** The migration is
  covered against **synthesised trees**, and the load-path fix is confirmed against the **real
  461 MB model** offline — but nobody here has the owner's actual two-copy layout.
- **The real HuggingFace download remains unverified** — pre-existing since 1.7.2, unchanged
  here. Nobody on this machine fetches the bytes.
- **No agent on this machine has a microphone or hardware**, so the warm-up timing above is read
  from the owner's log rather than reproduced.
- **The appcast enclosure URL still 404s anonymously** — private repo, pre-existing since the
  first phase-6 release, unchanged here.
- Ad-hoc signed, **not notarized** — no Developer ID on this machine. Unchanged.
