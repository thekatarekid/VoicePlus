# VoicePlus 1.7.2 — choosing a model is no longer the same act as downloading it

On onboarding's **"Pick a free local model."** step, the three options were radio buttons.
Clicking one **started a several-hundred-megabyte download**. Nothing on the screen said
that a selection was also a commitment.

And **Continue was enabled while that download sat at 3%**, so the user clicked straight
through to the dictation step with no model on disk — which is the exact route into the
dead app that 1.7.1 fixes. Two screens, one story: the picker let you leave before you had
what the next screen needed.

Ships in the same dmg as 1.7.1 and 1.7.3. Tag `release/phase-6/v1.7.2` · 1 commit
(`3b9c75e`) on top of 1.7.1 (`d4f804d`) · sha256 and dmg size recorded at the release
build.

## 1. What was actually happening

- **Selection was a side effect.** `.choose` both selected a tier and began fetching it. A
  control that looks like a pure choice spent up to **900 MB** of the user's bandwidth and
  disk with no confirmation and no warning.
- **Continue did not wait.** It was live from the moment a fetch *started*, not from the
  moment a model *landed*. "We began a download" was being treated as "the user has a
  model."
- **Download state was shared, not per option.** One row's progress or failure was painted
  under all three, so the screen could not say which model it was actually talking about.
- **Presence was tracked per tier, not per model.** "Best" is "Balanced" **plus** an extra
  120 MB model. With Balanced already on disk, choosing Best offered to download the whole
  900 MB again.

## 2. What ships instead

- **Every option has its own Download button.** Choosing and committing are separate acts:
  `.choose` now selects and nothing else, and a new `.download(tier)` event — raised only
  by that option's own button — is the only path to a fetch. **Selection alone never
  downloads.**
- **Each row shows its own state**, from `downloadStates` per option: **Download**, or that
  option's live progress — *"1 of 2 — 27 MB of 900 MB"* — with **Cancel**, or **Installed**
  with **"Use this"**.
- **Continue waits for the model to actually be on disk.** It is gated on `installedTiers`,
  read back from the model manager rather than inferred from having started a fetch, and
  `.next` is **refused by the state machine**, not merely greyed out in the view.
- **A disabled button that will not say why is its own dead end**, so it says why:
  *"Balanced is still downloading (3%). Continue turns on the moment it lands."*
- **Presence is per model, not per tier.** An already-downloaded model is never offered for
  re-download: with Balanced installed, Best reads **"Download 120 MB · Only the part you
  don't have yet."**
- **Skip still works — and now states its cost.** It is a legitimate choice, so it stays,
  but it records that it was taken without a model and warns on the **dictation step** and
  the **final screen** that dictation will not work until one is installed.

## 3. Tests

- New `Tests/AppTests/OnboardingModelPickerTests.swift` — **9 tests**: selection does not
  download, only `.download(tier)` fetches, `.next` is refused while the chosen model is
  absent, the blocked reason names the model and the percent, per-row state does not bleed
  across options, an installed model is not re-offered, and skip records its cost.
- `OnboardingStateMachineTests` and `OnboardingDictationTests` updated for the split
  between selecting and downloading.
- **Full package: `swift build` clean, 1259 tests passing.**

## What you need to do

1. Quit VoicePlus, replace it in **/Applications** with the copy from this dmg, then run
   once:

       xattr -dr com.apple.quarantine /Applications/VoicePlus.app

2. **If a model started downloading the instant you clicked an option, that was this bug.**
   Selecting now costs nothing; the Download button is the only thing that spends.

3. If you skipped the model step, the app will now tell you so on the way out, rather than
   letting you discover it at the first hotkey press.

## Known and remaining

- **The real HuggingFace download is unverified.** No agent on this machine has fetched a
  model, so the live byte counts, the *"1 of 2"* multi-file progress, and **mid-flight
  Cancel** against a real transfer have not been exercised end to end — they are covered
  against the model-manager protocol and mocks only.
- **Every state above the download boundary is tested**: gating, refusal, per-row state,
  per-model presence, the blocked reason text, and the skip warnings.
- **The appcast enclosure URL still 404s anonymously** — private repo, pre-existing since
  the first phase-6 release, unchanged here.
- Ad-hoc signed, **not notarized** — no Developer ID on this machine. Unchanged.
