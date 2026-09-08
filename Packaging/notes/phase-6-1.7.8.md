# VoicePlus 1.7.8 — "it downloaded the Balanced model by itself"

Reported, after choosing **Best** and watching **900 MB** download:

> I only downloaded the best 900 MB model. It downloaded the Balanced itself.

It did not. **Best** is Parakeet TDT 0.6B v3 **plus** the EOU model; **Balanced** is that
same TDT v3 — so completing Best completes Balanced with **not one extra byte fetched**.
Per-model presence (1.7.2, `3b9c75e`) is right and stays. What was missing was **the
sentence**. Both rows read a bare **"Installed"**, and a green check beside an option nobody
asked for reads as **500 MB the app decided to spend on its own**. Technically correct is
not good enough on a several-hundred-megabyte download; presented bare, it destroys trust.

Ships in the same dmg as 1.7.4, 1.7.5, 1.7.6 and 1.7.7 — **this is the dmg**. Tag
`release/phase-6/v1.7.8` · 1 commit (`3842440`) on top of 1.7.7 (`54888e6`) · sha256 and
dmg size recorded at the release build.

## 1. What was actually happening

- **The overlap was never stated.** Nothing before the download said Best contains Balanced,
  and nothing after it explained why a second row had turned green.
- **"Installed" could not tell two different facts apart.** A tier the user **explicitly
  downloaded** and a tier their choice **brought along** rendered identically, so the app
  had no way to say which had happened.
- **Three code comments called the EOU model "120 MB"**, misreading the **"120M"** in its
  name as megabytes when it is **parameters**. The model is **400 MB**. The advertised
  **900 MB** total was right all along — **500 + 400** — but the comments had been wrong
  since the tier was introduced.

## 2. What ships instead

- **The containment is stated *before* anything is downloaded.** The Best row reads
  **"Includes Balanced's 500 MB model, plus 400 MB more."** — new
  `App/Onboarding/ModelTierComposition.swift`, **computed from `ModelCatalog`**, so the
  figures cannot drift from what is actually fetched.
- **Afterwards the Balanced row reads "Included with Best"**, not a bare "Installed" — a
  visible **consequence of the user's own choice**, rather than a mystery download.
- **A non-selected installed row says "Switching downloads nothing."** and fetches nothing,
  which is now a test rather than a claim.
- **The state machine tracks `explicitlyDownloadedTiers`** — the buttons the user actually
  pressed — because "installed" alone cannot distinguish a tier the user fetched from one
  their choice carried in. **A tier downloaded on its own keeps the plain "Installed"**;
  crediting it to Best would be its own small lie. With nobody's presses remembered — after
  a relaunch — the shared row **still explains itself**.
- **The "120 MB" comments are corrected to 400 MB.**

## 3. Tests

- New `Tests/AppTests/OnboardingTierCompositionTests.swift` — **7 tests**. One of them
  **pins each tier's label to the sum of its catalogue entries**, so the advertised figures
  cannot drift from the catalogue again. The rest cover: the containment line appearing
  before any download, "Included with Best" only for a tier the user did not press,
  "Installed" surviving for one they did, "Switching downloads nothing." fetching nothing,
  and the shared row explaining itself with no press history.
- **Full package: `swift build` clean, 1313 tests passing.**

## What you need to do

1. Quit VoicePlus, replace it in **/Applications** with the copy from this dmg, then run
   once:

       xattr -dr com.apple.quarantine /Applications/VoicePlus.app

2. **This dmg carries 1.7.4 through 1.7.8.** Its four companions are the wedged-dictation
   fix, the clipped onboarding footer, the presence dot and error pill, and the audio
   ownership / warm-up fix — read their notes for what to check.

3. **Look at the model rows.** Best should tell you what it contains **before** you press
   Download, and Balanced should say **"Included with Best"** afterwards.

## Known and remaining

- **Whether "Included with Best" reads correctly in its column is unverified** — an agent
  has no window server, so the wording is tested and its appearance is not.
- **The real HuggingFace download remains unverified** — pre-existing since 1.7.2,
  unchanged here. The composition arithmetic is computed from the catalogue and pinned by
  test; the bytes are not fetched by anyone here.
- **The badly-wrong hotkey transcription is still unconfirmed on hardware** — see 1.7.7.
- **The appcast enclosure URL still 404s anonymously** — private repo, pre-existing since
  the first phase-6 release, unchanged here.
- Ad-hoc signed, **not notarized** — no Developer ID on this machine. Unchanged.
