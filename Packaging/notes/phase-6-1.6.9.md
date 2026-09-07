# VoicePlus 1.6.9 — the app can no longer invent words you did not say

On a Mac with no speech model downloaded — **every fresh install, including the
minutes you spend in onboarding** — VoicePlus did not sit idle. It substituted a
mock recogniser preloaded with a test fixture and replayed that fixture on a timer,
with the microphone contributing nothing at all. The pill showed the words as though
you had spoken them:

> Hi Priya, thanks for the update. Let's sync with TeamViewer tomorrow.

And on a hotkey press, that sentence was **typed into whatever app was in front of
you**. A name you have never written, a meeting you never proposed, in your document,
your email, your chat. This release removes that path entirely: with no model, the
engine is honestly dead — it produces no text, and the injector is never reached.

Tag `release/phase-6/v1.6.9` · 1 commit (`329af01`) on top of 1.6.8 (`c07e58a`) ·
sha256 and dmg size recorded at the release build.

## 1. What was actually happening

`App/Services/EngineFactory.swift` treated "no recogniser available" as a reason to
fall back to `MockEngine`, loaded from `Fixtures/transcripts/email_reply.json`. Three
things followed from that, all confirmed:

- **Fabricated text in the real UI.** The mock emits its spans on a timer with no
  audio input. The pill HUD is not a debug surface — it is the user-facing preview of
  what was heard — so the fixture sentence appeared exactly where a real transcript
  would, with no marking of any kind.
- **Fabricated text injected into other apps.** On hotkey release,
  `DictationCoordinator` handed those spans to `UtteranceLander` like any transcript.
  Nothing in the path could tell the difference, because there was nothing in the
  spans to tell it by.
- **It was live in shipped builds, not just development.** `Packaging/make_app.sh`
  copied `Fixtures/` into the `.app`, so the released bundle carried the fixture the
  fallback needed. This was not a debug-only hazard.

The trigger condition is the *common* one, not an edge case: a fresh install has no
model on disk until the download in onboarding completes.

## 2. What ships instead

- **No implicit mock, ever.** `EngineFactory` no longer falls back. `MockEngine` is
  reachable only by explicit developer opt-in through `VOICEPLUS_ENGINE=mock` /
  `VOICEPLUS_FIXTURE` — an environment variable a user cannot set by accident.
- **A new engine that is honest about being dead.** `Shared/Engine/UnavailableEngine.swift`
  publishes `EngineState.unavailable(reason)` and nothing else. It never emits
  `.partial`, `.final` or `.previewing`, and its `stop()` returns no spans. There is no
  code path through it that produces a character of text.
- **The pill says so.** `PillState.unavailable(reason:)` is its own case, not a
  transcript string — so the notice can never be mistaken for, or substituted as,
  something you said. It reads **"No speech model installed."** The presence indicator
  reports `blocked(.modelMissing)` rather than "ready", which was the other lie: the
  app claimed to be listening when it could not hear.
- **The injector is unreachable.** `DictationCoordinator.finalize()` returns early
  when the engine is unavailable. Even a nonsensical span cannot reach `UtteranceLander`.
- **Fixtures are out of the bundle.** `make_app.sh` no longer copies `Fixtures/` at
  all. Nothing shipping read it: `transcripts/` was mock-only, `directed/` is
  test-only, `tools/` is a dev script. Verified against a built bundle — the fixture
  sentences do not appear anywhere in the `.app`.

## 3. Tests

- New `Tests/AppTests/UnavailableEngineTests.swift` — **6/6 passing**. It pins the
  properties that matter rather than the implementation: no span of any kind escapes
  the engine, `stop()` returns empty, and finalize does not reach the injector.
- **`AppTests` 392/392, `SharedTests` 37/37, 0 failed.** `swift build` clean for the
  whole package. The full-package total is recorded at the release build.

## What you need to do

1. Quit VoicePlus, replace it in **/Applications** with the copy from this dmg, then
   run once:

       xattr -dr com.apple.quarantine /Applications/VoicePlus.app

2. **If you saw that sentence appear, or land in a document, that was this bug.** It
   was not your microphone, not a mis-transcription, and nothing you said. Check any
   document you dictated into before downloading a model.

3. Until a speech model finishes downloading, the pill will now say **"No speech model
   installed"** and dictation will do nothing. That is the correct behaviour, and it is
   what the app should have done from the start.

## Known and remaining

- **The download path itself is unchanged.** This release makes the no-model state
  honest; it does not make models easier to get. Onboarding still has to complete a
  download before dictation works.
- **`VOICEPLUS_ENGINE=mock` still injects fixture text**, by design — it is the
  developer path, and it now requires deliberately setting an environment variable.
  Nothing in the shipped UI turns it on.
- **The bundle check is a string search**, run against one build of the current
  `make_app.sh`: it proves the fixture text is absent from the artifact, not that no
  future change could reintroduce it. There is no packaging assertion guarding this the
  way `verify_install.sh` guards file modes.
- **No human has watched the unavailable pill on a genuinely fresh machine.** The
  behaviour is covered by tests against the coordinator and engine; the visual on a
  clean install is unverified.
- **The appcast enclosure URL still 404s anonymously** — private repo, pre-existing
  since the first phase-6 release, unchanged here.
- Ad-hoc signed, **not notarized** — no Developer ID on this machine. Unchanged.
