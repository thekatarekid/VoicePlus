# VoicePlus 1.6.5 — read-only files in the app bundle

Patch release on the Phase 6 line. One packaging fix; no app behaviour changes.

sha256 `6f4ded76ebe428b2bb56e73482d4b3d66b9f2a142db0a57509e6930f7b66dd03`

## Fixed

Running the documented `xattr -dr com.apple.quarantine /Applications/VoicePlus.app`
printed three permission-denied errors:

    xattr: [Errno 13] Permission denied: '.../GRDB_GRDB.bundle/PrivacyInfo.xcprivacy'
    xattr: [Errno 13] Permission denied: '.../FluidAudio_FluidAudio.bundle/luxtts_en_us_lexicon.tsv.zz'
    xattr: [Errno 13] Permission denied: '.../FluidAudio_FluidAudio.bundle/luxtts_en_us_g2p_aux.json'

`make_app.sh` copies SwiftPM resource bundles with `cp -R`, which preserves the
source mode. Those three files are `0444` in the build directory, so they shipped
read-only and `xattr` could not rewrite their attributes.

The errors were **cosmetic** — the bundle carried no quarantine attribute at all,
so nothing was actually blocked — but they look like a broken install, and any
tool that needs to write an xattr hits the same wall.

`make_app.sh` now normalises permissions across the assembled bundle before
codesigning (dirs 755, executables 755, everything else 644) and **fails the build**
if any file lacks `u+w`. `verify_install.sh` asserts the same against the shipped
DMG, and additionally checks that the installed copy has no quarantine attribute
and that `xattr -dr` exits cleanly. The new verifier fails on 1.6.4, naming exactly
the three files above.

Read-only files in the bundle: **3 → 0**. Signature unchanged and still valid
(`designated => identifier "in.adityakatare.voiceplus"`), so **TCC grants made on
1.6.4 carry over to this build** — that stable requirement is the fix from 1.6.4
that stops permissions resetting on every update.

## Installing

Quit VoicePlus, replace it in /Applications, then:

    xattr -dr com.apple.quarantine /Applications/VoicePlus.app

This should now be silent. Permissions granted to 1.6.4 should still be in place —
if Input Monitoring or Accessibility read as off, remove the VoicePlus row with "−"
and re-add it with "+", which rewrites the record against the current build.
