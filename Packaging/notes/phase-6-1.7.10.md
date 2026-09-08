# VoicePlus 1.7.10 — the dictation key was also the "act" key, so your sentence became an agent goal

With the **Best** model fully downloaded and onboarding finished, pressing the dictation
hotkey (**Right ⌘**) produced **no transcription at all**. What appeared in the notch instead
was this:

> Agent: failed(reason: "planner: disabled(stage: act.planner)")

Two failures in one line: **the words never landed**, and **the app spoke to its owner in a
debug string**.

Ships in the same dmg as 1.7.11 and 1.7.12. Tag `release/phase-6/v1.7.10` · 2 commits
(`68e75d0`, `69638f5`) on top of 1.7.9 (`8e440fe`) · sha256 and dmg size recorded at the
release build.

## 1. What was actually happening

A chain, each link individually reasonable:

- **One physical key drove two hotkey services.** `AppDelegate` defaulted the **act (second)
  key to `.rightCommand`** — the **same key as dictation** — and nothing anywhere prevented
  the two from sharing it. A single press started **both**.
- **The act session raced dictation for the transcript.** It opened the act domain and raced
  `engine.stop()` for the text.
- **A plain dictated sentence became an agent goal.** No catalogue command matched *"the quick
  brown fox…"*, so the parse fell through to **`.agentic(goal:)`** — which is the correct
  fallback for a deliberate act press and completely wrong for a dictation press that should
  never have reached it.
- **The planner called a provider it did not have.** `ProviderPlanner.plan` called
  `providers.complete` **unconditionally**; with **no provider pinned for `act.planner`** the
  router threw `ProviderRoutingError.disabled`.
- **A configuration state was rendered as a failure, verbatim.** `NativeAgentBackend` turned
  that throw into `.failed(reason:)`, and `AppDelegate` rendered the status with
  `String(describing:)` — which is exactly the string the owner read.

## 2. What ships instead

- **`ActKeyBinding.isDistinct` — the act key is inert while it shares a key with dictation.**
  **Dictation wins the collision**, because that is the app's whole purpose; the check is
  re-evaluated **per event**, so **rebinding the act key in Settings takes effect immediately**
  with no relaunch.
- **`ProviderPlanner` asks whether the provider is enabled before calling it**, and maps every
  `ProviderRoutingError` to a new **`PlannerError.unavailable`** — **a state, not a failure**.
  "You have not configured this" and "this broke" are different facts and now have different
  types.
- **`AgentRunStatus` speaks plain language.** It gains `.unavailable` and a `userMessage` for
  **all seven** cases — *"Actions need a model set up in Settings"*, *"That didn't work"*, *"I
  couldn't work out how to do that"* — and the failure reason **no longer interpolates the
  underlying `Error`**, so no internal description can reach the pill by that route either.
- **`ContractEnforcingStage` degrades a throwing stage to pass-through.** A stage that throws
  previously **unwound the whole run and discarded every earlier stage's output**; it now
  passes its input through with **confidence, `audioRange` and provenance intact**, so one
  broken stage costs its own contribution and **not the user's sentence**. **`.strict` still
  rethrows** — the diagnostic mode keeps its teeth.

## 3. Why the fix is bigger than the one line

An audit of every provider caller found **`ProviderPlanner` was the only unguarded one** — so
the guard is applied where it was missing rather than everywhere as ceremony. The
contract-stage change is deliberately **generic**: it covers **all 11 pipeline stages**, so the
next stage that throws for its own reasons cannot take a dictation turn down with it.

## 4. Tests

- **13 new tests** across `Tests/ActionsTests/PlannerUnavailableTests.swift`,
  `Tests/AppTests/ActPlannerRegressionTests.swift` and
  `Tests/PipelineTests/StageFailurePassthroughTests.swift`.
- One of them is a **standing guarantee about the app's voice**: **no status message may
  contain `failed(`, `reason:`, `stage:` or `act.planner`.** The rest cover an unconfigured
  planner resolving to `.unavailable` rather than `.failed`, a genuinely broken planner whose
  reason carries no debug text, the two hotkeys being required to be two different keys, a
  disabled `act.planner` stage still landing the recognised text in the frontmost field, and a
  throwing stage passing its input through with the span invariants intact while strict mode
  rethrows.
- **`swift build` clean, 1347 tests passing** for the whole package.

## What you need to do

1. Quit VoicePlus, replace it in **/Applications** with the copy from this dmg, then run once:

       xattr -dr com.apple.quarantine /Applications/VoicePlus.app

2. **This dmg carries 1.7.10, 1.7.11 and 1.7.12.** Its two companions are the half-downloaded
   model that reported itself installed, and the black slab error notice plus the presence
   dot's left-click menu — read their notes for what to check.

3. **Hold Right ⌘ and say one sentence.** It should type. Nothing beginning `Agent:` should
   appear at all.

4. **If you want act commands**, bind the act key to a **different** key in Settings — while it
   shares Right ⌘ with dictation it stays deliberately inert.

## Known and remaining

- **Untested on hardware: that Right ⌘ push-to-talk now types text with the act key silently
  disabled**, and **that rebinding the act key restores act commands**. No agent here has a
  microphone or a window server; the binding rule, the planner state and the pill's wording are
  covered against protocols and mocks.
- **The appcast enclosure URL still 404s anonymously** — private repo, pre-existing since the
  first phase-6 release, unchanged here.
- Ad-hoc signed, **not notarized** — no Developer ID on this machine. Unchanged.
